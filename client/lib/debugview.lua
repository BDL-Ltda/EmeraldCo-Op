-- Milestone 0.3 debug-panel model. Pure: validated network events, local state
-- and a millisecond clock are injected; bridge.lua owns the text buffer.
local protocol = require("protocol")

local M = { STALE_MS = 30000, REDRAW_MS = 250 }
local POSITION_FIELDS = { "mapGroup", "mapNum", "x", "y", "facing", "visible" }

local function copyPosition(source)
	if not source then return nil end
	local result = {}
	for _, field in ipairs(POSITION_FIELDS) do result[field] = source[field] end
	return result
end

local function positionText(p)
	if not p or p.mapGroup == nil then return "no position" end
	return string.format("%d:%d  %d,%d  %s", p.mapGroup, p.mapNum, p.x, p.y, protocol.facingName(p.facing))
end

function M.new(host, playerId)
	-- Only these display settings are retained, never the join key.
	host = type(host) == "string" and host:gsub("%c", "?") or "(unconfigured)"
	playerId = type(playerId) == "string" and playerId:gsub("%c", "?") or "(unconfigured)"
	local view = { remotePlayers = {} }
	local status, connected, latency = "Waiting for game", false, nil
	local localState, lastText, nextDraw = nil, nil, 0

	local function player(id, now)
		if id == playerId then return nil end
		local p = view.remotePlayers[id]
		if not p then
			local count = 0
			for _ in pairs(view.remotePlayers) do count = count + 1 end
			if count >= protocol.MAX_REMOTE_PLAYERS then return nil end
			p = {}
			view.remotePlayers[id] = p
		end
		p.lastUpdate = now
		return p
	end

	local function presence(p, message)
		for _, field in ipairs(POSITION_FIELDS) do p[field] = message[field] end
	end

	-- Events originate in net.lua after validation, not parsed console text.
	function view.onEvent(_, kind, data, now)
		if kind == "status" then
			status = data
			connected = data == "Connected"
			if not connected then view.remotePlayers, latency = {}, nil end
		elseif kind == "message" then
			if data.type == "welcome" then
				view.remotePlayers = {}
				status, connected, latency = "Connected", true, nil
				for _, entry in ipairs(data.players) do
					local p = player(entry.playerId, now)
					if p then
						p.trainerId, p.gender = entry.trainerId, entry.gender
						if entry.presence then presence(p, entry.presence) end
					end
				end
			elseif connected and data.type == "join" then
				-- A replacement must not inherit the previous connection's position.
				view.remotePlayers[data.playerId] = nil
				local p = player(data.playerId, now)
				if p then p.trainerId, p.gender = data.trainerId, data.gender end
			elseif connected and data.type == "presence" then
				local p = player(data.playerId, now)
				if p then presence(p, data) end
			elseif connected and data.type == "leave" then
				view.remotePlayers[data.playerId] = nil
			elseif connected and data.type == "pong" then
				latency = math.max(0, now - data.t)
			end
		end
	end

	function view.setPlayerState(_, state)
		localState = copyPosition(state)
	end

	-- Returns new text only when it changed, no more than four times/second.
	-- Expiry is based on peer updates, not pong or local-player activity.
	function view.update(_, now, force)
		if connected then
			for id, p in pairs(view.remotePlayers) do
				if now - p.lastUpdate >= M.STALE_MS then view.remotePlayers[id] = nil end
			end
		end
		if not force and now < nextDraw then return nil end
		nextDraw = now + M.REDRAW_MS
		local heading = string.format("%s  as %s", status, playerId)
		if connected then heading = string.format("Connected to %s  as %s", host, playerId) end
		if connected then heading = heading .. string.format("  (latency %s)", latency and latency .. " ms" or "pending") end
		local localVisibility = localState and (localState.visible and "visible" or "hidden") or "waiting for game"
		local lines = { heading, "Me:    " .. positionText(localState) .. "  " .. localVisibility }
		local ids = {}
		for id in pairs(view.remotePlayers) do ids[#ids + 1] = id end
		table.sort(ids)
		lines[#lines + 1] = "Remote players: " .. #ids
		for _, id in ipairs(ids) do
			local p = view.remotePlayers[id]
			local relationship = "map unknown"
			if p.mapGroup ~= nil and localState and localState.mapGroup ~= nil then
				relationship = p.mapGroup == localState.mapGroup and p.mapNum == localState.mapNum
					and "same map" or "different map"
			end
			local visibility = p.visible == nil and "awaiting presence" or (p.visible and "visible" or "hidden")
			lines[#lines + 1] = string.format("  %s  %s  %s  %s", id, positionText(p), visibility, relationship)
		end
		local text = table.concat(lines, "\n") .. "\n"
		if text == lastText then return nil end
		lastText = text
		return text
	end

	return view
end

return M
