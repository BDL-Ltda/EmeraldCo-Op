-- Moves validated presence between the ROM mailbox and the network client.
-- The mailbox and network client are injected so this module stays pure.
local mailbox = require("mailbox")

local M = {}

function M.new(box, client, view, logError)
	local connected = false
	local players, slots, leaving = {}, {}, {}

	local function forget()
		players, slots, leaving = {}, {}, {}
	end

	local bridge = {}

	function bridge.disconnect()
		if connected then box:setLuaConnected(false) end
		connected = false
		forget()
	end

	-- A reset invalidates the mailbox header, so do not write to it.
	function bridge.reset()
		connected = false
		forget()
	end

	function bridge.isConnected()
		return connected
	end

	function bridge.drainOutbound()
		while true do
			local message, err = box:pop()
			if err then logError("[bridge] " .. err); return end
			if not message then return end
			if message.type == mailbox.MSG.PRESENCE then
				local state, decodeError = mailbox.decodePresence(message.payload)
				if state and #message.payload == mailbox.PRESENCE_LENGTH then
					-- Validate the decoded fields before handing them to the protocol.
					local _, validationError = mailbox.encodePresence(state)
					if not validationError then
						client:setPlayerState(state)
						view:setPlayerState(state)
					else
						logError("[bridge] invalid outbound presence: " .. validationError)
					end
				else
					logError("[bridge] invalid outbound presence: " .. (decodeError or "unexpected length"))
				end
			end
		end
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
			connected = true
			box:setLuaConnected(true)
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
	end

	return bridge
end

return M
