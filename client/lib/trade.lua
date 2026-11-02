-- Cable Club invitation state machine. No emulator/socket globals; the relay
-- broadcasts trade messages, so every addressed message is filtered here.
local protocol = require("protocol")

local M = {
	TIMEOUT_MS = 30000,
	MAX_QUEUED = 16,
	COMMAND = { OPEN = 1, INVITE = 2, ACCEPT = 3, DECLINE = 4, CANCEL = 5 },
	STATE = { CLOSED = 0, WAITING = 1, INVITING = 2, INVITED = 3, READY = 4 },
	NOTICE = { NONE = 0, DECLINED = 1, TIMEOUT = 2, BUSY = 3, CANCELED = 4, DISCONNECTED = 5 },
}

-- env.send(message) returns true only after accepting the message for sending;
-- false means backpressure (retry). env.disconnect() fails closed on overflow.
-- env.publish(bytes) similarly retries the latest ROM snapshot, coalescing it.
function M.new(playerId, env)
	assert(not protocol.checkPlayerId(playerId))
	local self = {}
	local connected, peers, queue = false, {}, {}
	local retiring = {}
	local token, state, notice = 0, M.STATE.CLOSED, M.NOTICE.NONE
	local partner, deadline, initiator, dirty, fault = nil, nil, false, false, false
	local now = 0

	local function changed(nextState, nextNotice, nextPartner)
		state, notice, partner = nextState, nextNotice or M.NOTICE.NONE, nextPartner
		dirty = true
	end

	local function emit(message)
		if fault then return end
		-- Bounded even if the socket stops reading while peers keep inviting.
		if #queue == M.MAX_QUEUED then fault = true; return end
		queue[#queue + 1] = message
	end

	local function advertise()
		emit(protocol.tradeAvailable(playerId, state == M.STATE.WAITING))
	end

	local function waiting(why)
		deadline, initiator = nil, false
		changed(M.STATE.WAITING, why)
		advertise()
	end

	local function reset()
		connected, peers, queue, fault = false, {}, {}, false
		retiring = {}
		deadline, initiator = nil, false
		changed(M.STATE.CLOSED, M.NOTICE.DISCONNECTED)
		-- The ROM closes via lua_connected on a socket drop/reset. Do not send
		-- unsolicited UI snapshots on welcome, or reuse a pre-reset visit token.
		token, dirty = 0, false
	end

	function self.reset() reset() end

	-- ID strings are ASCII from the protocol, padded to 16 bytes on the mailbox.
	local function idBytes(id) return string.pack("c16", id or "") end
	function self.snapshot()
		local ids = {}
		if state == M.STATE.WAITING then
			for id, available in pairs(peers) do
				if available and not retiring[id] then ids[#ids + 1] = id end
			end
			table.sort(ids)
		end
		local bytes = string.pack("<I2BBB", token, state, notice, #ids) .. idBytes(partner)
		for _, id in ipairs(ids) do bytes = bytes .. idBytes(id) end
		return bytes
	end

	local function expire()
		if not deadline or now < deadline then return end
		retiring[partner], peers[partner] = true, false
		if state == M.STATE.INVITED then
			emit(protocol.tradeDecline(playerId, partner, "timeout"))
		elseif state == M.STATE.INVITING then
			emit(protocol.tradeCancel(playerId, partner, "timeout"))
		end
		waiting(M.NOTICE.TIMEOUT)
	end

	function self.command(bytes, nowMs)
		now = nowMs
		expire()
		if type(bytes) ~= "string" or #bytes < 3 then return end
		local command, commandToken = string.unpack("<BI2", bytes)
		if command == M.COMMAND.OPEN and #bytes == 3 then
			if not connected or commandToken == token then return end
			-- A second attendant entry must not inherit an old invitation.
			if partner then
				retiring[partner], peers[partner] = true, false
				emit(protocol.tradeCancel(playerId, partner, "canceled"))
			end
			token = commandToken
			waiting()
			return
		end
		if commandToken ~= token or state == M.STATE.CLOSED then return end
		if command == M.COMMAND.CANCEL and #bytes == 3 then
			if partner then
				retiring[partner], peers[partner] = true, false
				emit(protocol.tradeCancel(playerId, partner, "canceled"))
			end
			deadline = nil
			changed(M.STATE.CLOSED)
			advertise()
		elseif command == M.COMMAND.INVITE and state == M.STATE.WAITING then
			local id = bytes:sub(4)
			if protocol.checkPlayerId(id) or not peers[id] or retiring[id] then return end
			peers[id] = false
			deadline, initiator = now + M.TIMEOUT_MS, true
			changed(M.STATE.INVITING, nil, id)
			advertise()
			emit(protocol.tradeInvite(playerId, id))
		elseif command == M.COMMAND.ACCEPT and #bytes == 3 and state == M.STATE.INVITED then
			deadline = nil
			changed(M.STATE.READY, nil, partner)
			emit(protocol.tradeAccept(playerId, partner))
		elseif command == M.COMMAND.DECLINE and #bytes == 3 and state == M.STATE.INVITED then
			retiring[partner], peers[partner] = true, false
			emit(protocol.tradeDecline(playerId, partner, "declined"))
			waiting(M.NOTICE.DECLINED)
		end
	end

	function self.onEvent(kind, message, nowMs)
		now = nowMs
		if kind == "status" then
			if message ~= "Connected" then reset() end
			return
		end
		if kind ~= "message" then return end
		if message.type == "welcome" then
			reset()
			connected = true
			for _, peer in ipairs(message.players) do
				if peer.playerId ~= playerId then peers[peer.playerId] = false end
			end
			return
		end
		if not connected then return end
		expire()
		local id, kindName = message.playerId, message.type
		if id == playerId then return end
		if kindName == "join" then
			if peers[id] == nil then
				local count = 0
				for _ in pairs(peers) do count = count + 1 end
				if count >= protocol.MAX_REMOTE_PLAYERS then return end
			end
			peers[id], retiring[id], dirty = false, nil, true
			if partner == id then waiting(M.NOTICE.DISCONNECTED) end
			if state == M.STATE.WAITING then advertise() end
		elseif kindName == "leave" then
			peers[id], retiring[id], dirty = nil, nil, true
			if partner == id then waiting(M.NOTICE.DISCONNECTED) end
		elseif peers[id] == nil then
			return -- Only peers in this connection's welcome/join can trade.
		elseif kindName == "trade_available" then
			peers[id], dirty = message.available and partner ~= id and not retiring[id], true
		elseif message.targetId == playerId then
			if retiring[id] then
				-- v2 has no invitation nonce. Before allowing another invitation
				-- to this peer, drain the old conversation with a terminal reply.
				-- A cancel acknowledges a decline/cancel once; FIFO on the peer's
				-- socket puts any old accept before that reply, never into a retry.
				if kindName == "trade_cancel" or kindName == "trade_decline" then
					retiring[id], dirty = nil, true
				end
				if kindName ~= "trade_cancel" then emit(protocol.tradeCancel(playerId, id, "canceled")) end
			elseif kindName == "trade_invite" then
				if state == M.STATE.WAITING then
					deadline, initiator = now + M.TIMEOUT_MS, false
					changed(M.STATE.INVITED, nil, id)
					advertise()
				elseif state == M.STATE.INVITING and partner == id and playerId > id then
					-- Crossing invites: the lexicographically smaller ID invites.
					-- The other peer switches to the accept prompt, without a
					-- decline that could cancel the winning invitation.
					deadline, initiator = now + M.TIMEOUT_MS, false
					changed(M.STATE.INVITED, nil, id)
				elseif partner ~= id then
					emit(protocol.tradeDecline(playerId, id, "busy"))
				end
			elseif id == partner then
				if kindName == "trade_accept" and state == M.STATE.INVITING then
					deadline = nil
					changed(M.STATE.READY, nil, id)
				elseif kindName == "trade_decline" and state == M.STATE.INVITING then
					emit(protocol.tradeCancel(playerId, id, "canceled"))
					local why = ({ declined = M.NOTICE.DECLINED, timeout = M.NOTICE.TIMEOUT,
						busy = M.NOTICE.BUSY })[message.reason]
					waiting(why)
				elseif kindName == "trade_cancel" then
					emit(protocol.tradeCancel(playerId, id, "canceled"))
					waiting(message.reason == "timeout" and M.NOTICE.TIMEOUT or M.NOTICE.CANCELED)
				end
			end
		end
	end

	function self.update(nowMs)
		now = nowMs
		expire()
		if fault then
			reset()
			env.disconnect() -- Server leave clears our advertisement on all peers.
			return
		end
		while #queue > 0 do
			if not env.send(queue[1]) then break end
			table.remove(queue, 1)
		end
		if dirty and env.publish(self.snapshot()) then dirty = false end
	end

	-- #83 consumes this handoff and owns the subsequent trade session. No party
	-- data is exchanged or mutated by the attendant/invitation implementation.
	function self.getSession()
		if state == M.STATE.READY then return { partnerId = partner, initiator = initiator } end
	end

	return self
end

return M
