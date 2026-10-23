-- Protocol v1 messages (docs/protocol.md): builders for what the client sends
-- and validation for what the server sends. Pure: no mGBA globals (see client/README.md).
local json = require("json")

local M = {
	VERSION = 1,
	MAX_PLAYER_ID_LENGTH = 16,
	MAX_JOIN_KEY_LENGTH = 64,
	MAX_CLIENT_VERSION_LENGTH = 32,
	MAX_ERROR_MESSAGE_LENGTH = 256,
	MAX_REMOTE_PLAYERS = 4,
	MAX_TRAINER_ID = 0xFFFFFFFF,
}

-- The decomp's DIR_* values, which are also the protocol's facing values.
local FACING_NAMES = { [1] = "SOUTH", [2] = "NORTH", [3] = "WEST", [4] = "EAST" }
local LEAVE_REASONS = { disconnect = true, timeout = true, kicked = true, replaced = true }
local ERROR_CODES = { bad_key = true, bad_message = true, room_full = true, version_mismatch = true, bad_hello = true }

-- Decoded JSON keeps its shape as a metatable (see json.lua).
local OBJECT, ARRAY = getmetatable(json.object()), getmetatable(json.array())
local function isObject(value) return type(value) == "table" and getmetatable(value) == OBJECT end
local function isArray(value) return type(value) == "table" and getmetatable(value) == ARRAY end

local function isInteger(value, min, max)
	return math.type(value) == "integer" and value >= min and value <= max
end

-- Each check returns nil when the value is valid, or a reason. Reasons never
-- include the value: it can be a join key.
local function checkPlayerId(value)
	if type(value) ~= "string" or #value < 1 or #value > M.MAX_PLAYER_ID_LENGTH then
		return "must be 1-" .. M.MAX_PLAYER_ID_LENGTH .. " characters"
	end
	if value:find("[^%w_%-]") then
		return "may only contain a-z, A-Z, 0-9, _ and -"
	end
end

-- Free text: valid UTF-8, min-max characters, no C0, DEL or C1 control characters.
local function checkText(value, min, max)
	if type(value) ~= "string" then return "must be a string" end
	local length = utf8.len(value)
	if not length then return "is not valid UTF-8" end
	if length < min or length > max then
		return "must be " .. min .. "-" .. max .. " characters"
	end
	for _, code in utf8.codes(value) do
		if code < 0x20 or (code >= 0x7F and code <= 0x9F) then
			return "contains a control character"
		end
	end
end

local function checkGender(value)
	if not isInteger(value, 0, 1) then return "must be 0 or 1" end
end

local function checkTrainerId(value)
	if not isInteger(value, 0, M.MAX_TRAINER_ID) then return "must be 0-" .. M.MAX_TRAINER_ID end
end

-- mapGroup, mapNum, x, y, facing and visible, at the top level of a presence
-- or inside a welcome entry.
local function checkPresenceState(s, prefix)
	if not isInteger(s.mapGroup, 0, 255) then return prefix .. "mapGroup must be 0-255" end
	if not isInteger(s.mapNum, 0, 255) then return prefix .. "mapNum must be 0-255" end
	if not isInteger(s.x, -32768, 32767) then return prefix .. "x must be -32768-32767" end
	if not isInteger(s.y, -32768, 32767) then return prefix .. "y must be -32768-32767" end
	if not isInteger(s.facing, 1, 4) then return prefix .. "facing must be 1-4" end
	if type(s.visible) ~= "boolean" then return prefix .. "visible must be a boolean" end
end

local function field(name, reason)
	if reason then return name .. " " .. reason end
end

local function checkPlayer(p, prefix)
	if not isObject(p) then return prefix .. " must be an object" end
	return field(prefix .. ".playerId", checkPlayerId(p.playerId))
		or field(prefix .. ".trainerId", checkTrainerId(p.trainerId))
		or field(prefix .. ".gender", checkGender(p.gender))
end

-- Validators for the messages a client receives. Each returns nil or a reason.
local VALIDATORS = {
	welcome = function(m)
		local players = m.players
		if not isArray(players) then return "players must be an array" end
		if #players > M.MAX_REMOTE_PLAYERS then
			return "players has more than " .. M.MAX_REMOTE_PLAYERS .. " entries"
		end
		local seen = {}
		for i, p in ipairs(players) do
			local prefix = "players[" .. (i - 1) .. "]"
			local reason = checkPlayer(p, prefix)
			if reason then return reason end
			if seen[p.playerId] then return prefix .. ".playerId is listed twice" end
			seen[p.playerId] = true
			if p.presence ~= nil then
				if not isObject(p.presence) then
					return prefix .. ".presence must be an object"
				end
				reason = checkPresenceState(p.presence, prefix .. ".presence.")
				if reason then return reason end
			end
		end
	end,
	join = function(m)
		return field("playerId", checkPlayerId(m.playerId))
			or field("trainerId", checkTrainerId(m.trainerId))
			or field("gender", checkGender(m.gender))
	end,
	presence = function(m)
		return field("playerId", checkPlayerId(m.playerId)) or checkPresenceState(m, "")
	end,
	leave = function(m)
		return field("playerId", checkPlayerId(m.playerId))
			or (not LEAVE_REASONS[m.reason] and "reason is not a known reason" or nil)
	end,
	pong = function(m)
		if not isInteger(m.t, 0, math.maxinteger) then return "t must be a non-negative integer" end
	end,
	error = function(m)
		return (not ERROR_CODES[m.code] and "code is not a known code" or nil)
			or field("message", checkText(m.message, 0, M.MAX_ERROR_MESSAGE_LENGTH))
	end,
}

-- Decodes and validates one line from the server. Returns the message table,
-- or nil and a reason. A message of a type the client doesn't handle is
-- returned with unknown = true, as the protocol says to ignore it.
-- A line whose v is not ours fails with versionMismatch = true as third value.
function M.decode(line)
	local m, err = json.decode(line)
	if err then return nil, "not valid JSON: " .. err end
	if not isObject(m) then
		return nil, "not a JSON object"
	end
	if m.v == nil or m.v == json.null then return nil, "v is missing" end
	if m.v ~= M.VERSION or math.type(m.v) ~= "integer" then
		return nil, "protocol version is not " .. M.VERSION, true
	end
	if type(m.type) ~= "string" then return nil, "type must be a string" end
	local validate = VALIDATORS[m.type]
	if not validate then
		m.unknown = true
		return m
	end
	local reason = validate(m)
	if reason then return nil, "invalid " .. m.type .. ": " .. reason end
	return m
end

-- Encodes a message built below as one line, without the LF.
function M.encode(message)
	return json.encode(message)
end

function M.hello(playerId, joinKey, trainerId, gender, clientVersion)
	return { v = M.VERSION, type = "hello", playerId = playerId, joinKey = joinKey,
		trainerId = trainerId, gender = gender, clientVersion = clientVersion }
end

-- state: memory.lua's getPlayerState() result with every position field set.
function M.presence(playerId, state)
	return { v = M.VERSION, type = "presence", playerId = playerId, mapGroup = state.mapGroup,
		mapNum = state.mapNum, x = state.x, y = state.y, facing = state.facing, visible = state.visible }
end

function M.ping(t)
	return { v = M.VERSION, type = "ping", t = t }
end

-- Validation of local values before they go on the wire. Each returns nil or
-- a reason naming the field (never its value).
function M.checkHelloIdentity(playerId, joinKey, trainerId, gender, clientVersion)
	return field("playerId", checkPlayerId(playerId))
		or field("joinKey", checkText(joinKey, 1, M.MAX_JOIN_KEY_LENGTH))
		or field("trainerId", checkTrainerId(trainerId))
		or field("gender", checkGender(gender))
		or field("clientVersion", checkText(clientVersion, 1, M.MAX_CLIENT_VERSION_LENGTH))
end

function M.checkPresenceState(state)
	return checkPresenceState(state, "")
end

M.checkPlayerId = checkPlayerId

function M.checkJoinKey(value)
	return checkText(value, 1, M.MAX_JOIN_KEY_LENGTH)
end

function M.facingName(facing)
	return FACING_NAMES[facing] or ("UNKNOWN(" .. tostring(facing) .. ")")
end

return M
