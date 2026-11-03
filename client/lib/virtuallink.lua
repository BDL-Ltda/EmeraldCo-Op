-- Virtual link relay (issue #81, docs/virtual-link.md).
--
-- During a co-op trade session the ROM's virtual link (src/coop/virtual_link.c)
-- talks to the partner's ROM in COOP_MSG_LINK packets. This module is the dumb
-- pipe between the two: ROM packets go to the partner as protocol trade_link
-- messages, and the partner's trade_link messages go back into the mailbox.
-- Nothing else is relayed: only the partner's packets, only the kinds a peer
-- may send, in sequence. The ROM owns the timeout and the cancel; Lua only
-- tells it early when the partner leaves the room or the link breaks.
--
-- Pure: the network and the mailbox are injected (env.sendLink, env.toRom).

local protocol = require("protocol")

local M = {
	MSG_TYPE = 5, -- COOP_MSG_LINK in include/constants/coop.h
	-- Packet kinds, the first byte of every packet (include/coop/virtual_link.h).
	START = 0, HELLO = 1, BLOCK = 2, REQUEST = 3, BARRIER = 4, CLOSE = 5,
	CANCEL = 6, ABORT = 7, END = 8, KEEPALIVE = 9,
	-- END outcomes and CANCEL reasons.
	END_DONE = 0, END_CANCELED = 1, END_REFUSED = 2,
	CANCEL_LEFT = 1, CANCEL_BROKEN = 2,
	-- Packets waiting in each direction. The ROM sends at most one per frame
	-- and waits for most of them to drain, so a full queue means a stuck link.
	MAX_QUEUED = 64,
	MAX_SEQ = 4294967295,
	-- Debug trigger: retry a START the ROM refused (not in the free overworld).
	START_RETRY_MS = 2000,
}

-- Kinds one ROM sends to the other. START, CANCEL and END are local controls
-- between Lua and its own ROM and are never relayed in either direction.
local PEER_KINDS = {
	[M.HELLO] = true, [M.BLOCK] = true, [M.REQUEST] = true, [M.BARRIER] = true,
	[M.CLOSE] = true, [M.ABORT] = true, [M.KEEPALIVE] = true,
}

local OUTCOMES = { [M.END_DONE] = "done", [M.END_CANCELED] = "canceled", [M.END_REFUSED] = "refused" }

-- Both sides derive the same roles without negotiating: the lower player ID
-- leads the trade (multiplayer ID 0). The server keeps player IDs unique.
function M.role(selfId, partnerId)
	return selfId < partnerId and 0 or 1
end

-- The START packet for the ROM: kind, role, partner ID length, partner ID.
function M.startPacket(selfId, partnerId)
	return string.char(M.START, M.role(selfId, partnerId), #partnerId) .. partnerId
end

-- selfId: config.PLAYER_ID.
-- env:
--   sendLink(message): queues a trade_link message; false to retry next frame.
--   toRom(bytes): queues a COOP_MSG_LINK message for the ROM; false to retry.
--   log(line), optional.
function M.new(selfId, env)
	local log = env.log or function() end
	local partner, active, canceled = nil, false, false
	local toNet, toRom = {}, {}
	local nextSeq = 0 -- Our trade_link sequence on this connection.
	local lastSeen = {} -- Last seq received from each player on this connection.
	local expected = nil -- Next seq from the partner in this session.

	local link = {}

	local function endSession()
		active, canceled, expected = false, false, nil
		toRom = {}
	end

	-- Tells the ROM the partner is gone. The ROM answers with END.
	local function cancel(reason, why)
		if canceled then return end
		canceled = true
		toRom = { string.char(M.CANCEL, reason) }
		log("[link] canceling the trade with " .. partner .. ": " .. why)
	end

	function link.isActive() return active end
	function link.partner() return partner end

	-- Starts a session with partnerId. Returns true, or false and a reason.
	function link.start(partnerId)
		if active then return false, "a session is already running" end
		local reason = protocol.checkPlayerId(partnerId)
		if reason then return false, "partner " .. reason end
		if partnerId == selfId then return false, "cannot trade with yourself" end
		partner, active, canceled, expected = partnerId, true, false, nil
		toNet, toRom = {}, { M.startPacket(selfId, partnerId) }
		log(string.format("[link] starting a trade session with %s (role %d)", partnerId, M.role(selfId, partnerId)))
		return true
	end

	-- A complete COOP_MSG_LINK message from the ROM. Returns the outcome when
	-- it is END, so the caller can react to the end of a session.
	function link.onRomMessage(data)
		local kind = data:byte(1)
		if kind == M.END then
			local outcome = data:byte(2)
			if active then
				log(string.format("[link] trade session with %s ended: %s", partner,
					OUTCOMES[outcome] or tostring(outcome)))
			end
			endSession()
			return outcome
		end
		if not active or not PEER_KINDS[kind] then return end
		if #toNet >= M.MAX_QUEUED then
			cancel(M.CANCEL_BROKEN, "send queue full")
			return
		end
		toNet[#toNet + 1] = data
	end

	local function onLink(m)
		local from = m.playerId
		if not active or canceled or from ~= partner then
			lastSeen[from] = m.seq
			return
		end
		if expected == nil then
			-- Packets sent before this side started are lost; anything up to
			-- the last one seen belongs to an earlier session.
			if lastSeen[from] ~= nil and m.seq <= lastSeen[from] then return end
		elseif m.seq ~= expected then
			cancel(M.CANCEL_BROKEN, string.format("expected seq %d, got %d", expected, m.seq))
			return
		end
		expected = (m.seq + 1) % (M.MAX_SEQ + 1)
		lastSeen[from] = m.seq
		local data = protocol.fromHex(m.data)
		-- A partner may only send peer packets, never our ROM's controls.
		if not data or #data == 0 or not PEER_KINDS[data:byte(1)] then return end
		if #toRom >= M.MAX_QUEUED then
			cancel(M.CANCEL_BROKEN, "receive queue full")
			return
		end
		toRom[#toRom + 1] = data
	end

	-- net.lua events (see bridge.lua): status changes and server messages.
	function link.onEvent(kind, data)
		if kind == "status" then
			if data ~= "Connected" then link.disconnect() end
			return
		end
		if kind ~= "message" then return end
		if data.type == "welcome" then
			-- A new connection: the server starts every sequence again.
			nextSeq, lastSeen = 0, {}
		elseif data.type == "join" or data.type == "leave" then
			lastSeen[data.playerId] = nil
			if data.type == "leave" and active and data.playerId == partner then
				cancel(M.CANCEL_LEFT, "partner left")
			end
		elseif data.type == "trade_link" and data.targetId == selfId then
			onLink(data)
		end
	end

	-- The socket is gone. The ROM sees the cleared lua_connected flag and
	-- cancels on its own; nothing queued can be delivered any more.
	function link.disconnect()
		if active then log("[link] connection lost during the trade session with " .. partner) end
		endSession()
		toNet = {}
	end

	-- A ROM reset or another game: forget everything.
	function link.reset()
		endSession()
		partner, toNet, nextSeq, lastSeen = nil, {}, 0, {}
	end

	-- Once per frame: moves queued packets on. After END the ROM's last
	-- packets (its ABORT) still go out to the partner.
	function link.update()
		while toRom[1] and env.toRom(toRom[1]) do table.remove(toRom, 1) end
		while toNet[1] do
			local message = protocol.tradeLink(selfId, partner, nextSeq, protocol.toHex(toNet[1]))
			if not env.sendLink(message) then break end
			table.remove(toNet, 1)
			nextSeq = (nextSeq + 1) % (M.MAX_SEQ + 1)
		end
	end

	return link
end

-- Debug trigger until the attendant (#82) and the trade session (#83) start
-- sessions: once per script load, start a session with partnerId as soon as
-- that player is in the room. Set TRADE_LINK_PARTNER in client/config.lua on
-- both sides, each naming the other.
function M.newDebugTrigger(link, partnerId)
	local present, done, retryAt = false, false, 0
	local trigger = {}

	function trigger.onEvent(kind, data)
		if kind ~= "message" then return end
		if data.type == "welcome" then
			present = false
			for _, player in ipairs(data.players) do
				if player.playerId == partnerId then present = true end
			end
		elseif data.type == "join" and data.playerId == partnerId then
			present = true
		elseif data.type == "leave" and data.playerId == partnerId then
			present = false
		end
	end

	-- An END from the ROM: a refused START is tried again later.
	function trigger.onEnd(outcome)
		if outcome == M.END_REFUSED then retryAt = nil else done = true end
	end

	function trigger.update(now)
		if retryAt == nil then retryAt = now + M.START_RETRY_MS end
		if done or not present or link.isActive() or now < retryAt then return end
		if link.start(partnerId) then retryAt = now + M.START_RETRY_MS end
	end

	return trigger
end

return M
