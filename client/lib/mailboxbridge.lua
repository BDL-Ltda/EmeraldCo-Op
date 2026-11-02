-- Moves validated presence between the ROM mailbox and the network client,
-- and multi-slot messages (mailbox layout v2, lib/fragments.lua) both ways.
-- The mailbox and network client are injected so this module stays pure.
local mailbox = require("mailbox")
local fragments = require("fragments")

local M = { MAX_OUTBOUND_PER_FRAME = 15 }

-- onMessage(type, data), optional: called with each complete multi-slot
-- message from the ROM. Without it those messages are dropped.
function M.new(box, client, view, logError, onMessage)
	local connected, active = false, false
	local players, slots, leaving = {}, {}, {}
	local sender, reassembler = fragments.newSender(), fragments.newReassembler()

	-- Both directions drop an incomplete multi-slot message: the other side
	-- drops its part when the next message starts with fragment 0.
	local function forget()
		players, slots, leaving = {}, {}, {}
		sender:clear()
		reassembler:reset()
	end

	local bridge = {}

	function bridge.disconnect()
		if connected then box:setLuaConnected(false) end
		connected, active = false, false
		forget()
	end

	-- A reset invalidates the mailbox header, so do not write to it.
	function bridge.reset()
		connected, active = false, false
		forget()
	end

	function bridge.isConnected()
		return active
	end

	function bridge.drainOutbound()
		-- Bound work even if the ROM publishes while this callback runs.
		for _ = 1, M.MAX_OUTBOUND_PER_FRAME do
			local message, err = box:pop()
			if err then logError("[bridge] " .. err); return end
			if not message then return end
			if message.type == mailbox.MSG.PRESENCE then
				local state, decodeError = mailbox.decodePresence(message.payload)
				if state then
					-- Byte 14 is a slot only inbound; outbound extensions are unknown.
					state.slot = nil
					-- Validate the decoded fields before handing them to the protocol.
					local _, validationError = mailbox.encodePresence(state)
					if not validationError then
						-- Mailbox visibility is controllable-overworld state. Wire v1
						-- means a running session, including menus/battles. Every ROM
						-- snapshot has a session; reset closes the socket instead.
						local wire = {}
						for key, value in pairs(state) do wire[key] = value end
						wire.visible = true
						client:setPlayerState(wire)
						view:setPlayerState(state)
					else
						logError("[bridge] invalid outbound presence: " .. validationError)
					end
				else
					logError("[bridge] invalid outbound presence: " .. (decodeError or "unexpected length"))
				end
			elseif message.type == mailbox.MSG.FRAGMENT then
				local msgType, data, dropped = reassembler:feed(message.payload)
				if dropped then logError("[bridge] mailbox: " .. dropped) end
				if msgType and onMessage then onMessage(msgType, data) end
			elseif message.type == mailbox.MSG.TRADE_COMMAND and onMessage then
				onMessage(message.type, message.payload)
			end
		end
	end

	-- Queues a multi-slot message for the ROM, sent in order after presence
	-- over as many frames as it needs. Returns true, or false and a reason.
	-- Only during a session: a disconnect drops what is still queued.
	function bridge.sendMessage(msgType, data)
		if not connected then return false, "not connected" end
		return sender:send(msgType, data)
	end

	local function remove(id)
		local player = players[id]
		if not player then return end
		if player.slot then
			leaving[player.slot] = true
			slots[player.slot] = false -- reserved until LEAVE reaches the ROM
		end
		players[id] = nil
	end

	function bridge.onEvent(_, kind, data)
		if kind == "status" then
			if data ~= "Connected" then bridge.disconnect() end
			return
		end
		if kind ~= "message" then return end
		if data.type == "welcome" then
			forget()
			connected, active = true, false
			box:setLuaConnected(false)
			-- Also clear slots restored from a save or a previous script instance.
			for slot = 1, mailbox.REMOTE_SLOTS do leaving[slot] = true end
			for _, entry in ipairs(data.players) do
				players[entry.playerId] = { trainerId = entry.trainerId, gender = entry.gender,
					presence = entry.presence }
			end
		elseif not connected then
			return
		elseif data.type == "join" then
			remove(data.playerId)
			players[data.playerId] = { trainerId = data.trainerId, gender = data.gender }
		elseif data.type == "presence" then
			local player = players[data.playerId]
			if player then
				player.presence = data
				player.dirty = true
			end
		elseif data.type == "leave" then
			remove(data.playerId)
		end
	end

	function bridge.flushInbound()
		if not connected then return end
		if not active then
			local empty, err = box:isInboundEmpty()
			if not empty then
				if err then logError("[bridge] " .. err) end
				return
			end
			-- With the old queue drained, these four LEAVEs fit before any new
			-- presence. The ROM owns the tail and the session's object cleanup.
			box:setLuaConnected(true)
			active = true
		end
		for slot = 1, mailbox.REMOTE_SLOTS do
			if leaving[slot] then
				local ok, err = box:push(mailbox.MSG.LEAVE, string.char(slot - 1))
				if not ok then
					if err ~= "mailbox inbound ring full" then logError("[bridge] " .. err) end
					return
				end
				leaving[slot], slots[slot] = nil, nil
			end
		end
		local ids = {}
		for id, player in pairs(players) do
			if player.presence then ids[#ids + 1] = id end
		end
		table.sort(ids)
		for _, id in ipairs(ids) do
			local player = players[id]
			if not player.slot then
				for slot = 1, mailbox.REMOTE_SLOTS do
					if slots[slot] == nil then
						player.slot, slots[slot], player.dirty = slot, id, true
						break
					end
				end
			end
			if player.slot and player.dirty then
				local p = player.presence
				local payload, err = mailbox.encodePresence({ mapGroup = p.mapGroup, mapNum = p.mapNum,
					x = p.x, y = p.y, facing = p.facing, visible = p.visible,
					gender = player.gender, trainerId = player.trainerId, slot = player.slot - 1 })
				if not payload then
					logError("[bridge] invalid inbound presence: " .. err)
					player.dirty = false
				else
					local ok, pushError = box:push(mailbox.MSG.PRESENCE, payload)
					if not ok then
						if pushError ~= "mailbox inbound ring full" then logError("[bridge] " .. pushError) end
						return
					end
					player.dirty = false
				end
			end
		end
		local _, pushError = sender:pump(function(payload) return box:push(mailbox.MSG.FRAGMENT, payload) end)
		if pushError and pushError ~= "mailbox inbound ring full" then logError("[bridge] " .. pushError) end
	end

	return bridge
end

return M
