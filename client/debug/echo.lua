-- Issue #77 acceptance tool: multi-slot mailbox messages (layout v2), both ways.
-- Load instead of bridge.lua in mGBA 0.10.5, with the game in the overworld.
-- No config, key or server needed. Scripting > File > Reset before switching
-- between this script and the bridge: each ring has exactly one Lua side.
--
-- Round 1 pushes the first 5 fragments of a 600-byte message and stops (an
-- incomplete message), then sends a different 600-byte message. Round 2 sends
-- a 1024-byte message. The ROM sends each complete COOP_MSG_DEBUG_ECHO back
-- unchanged; this script compares the bytes and counts the presence messages
-- that arrived while each echo was on its way.
local DIR = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = DIR .. "../lib/?.lua;" .. package.path
local mailbox = require("mailbox")
local fragments = require("fragments")
local romcheck = require("romcheck")

local TAG = "[echo] "
local TIMEOUT_FRAMES = 600

local chunk, loadError = loadfile(DIR .. "../addresses.lua")
if not chunk then console:error(TAG .. tostring(loadError)); return end
local ok, addresses = pcall(chunk)
if not ok or type(addresses) ~= "table" then
	console:error(TAG .. "addresses.lua must return a table")
	return
end

local function pattern(length, seed)
	local bytes = {}
	for i = 0, length - 1 do bytes[#bytes + 1] = string.char((i * seed + i // 256 + 3) & 0xFF) end
	return table.concat(bytes)
end

local ROUNDS = {
	{ name = "600 bytes after an incomplete message", truncated = pattern(600, 31), data = pattern(600, 7) },
	{ name = "1024 bytes (the largest message)", data = pattern(1024, 13) },
}

local box, lastError, round, state
local sender, reassembler = fragments.newSender(), fragments.newReassembler()

local function push(payload) return box:push(mailbox.MSG.FRAGMENT, payload) end

local function startRound(index)
	round = index
	local r = ROUNDS[index]
	if not r then
		console:log(TAG .. "done; lua_connected cleared")
		box:setLuaConnected(false)
		box = nil
		return
	end
	local truncated = {}
	if r.truncated then
		local all = assert(fragments.split(mailbox.MSG.DEBUG_ECHO, r.truncated))
		for i = 1, 5 do truncated[i] = all[i] end
	end
	assert(sender:send(mailbox.MSG.DEBUG_ECHO, r.data))
	local count = #assert(fragments.split(mailbox.MSG.DEBUG_ECHO, r.data))
	state = { frames = 0, presences = 0, truncated = truncated, fragments = count }
	console:log(string.format("%sround %d: %s, %d fragments%s", TAG, index, r.name, state.fragments,
		r.truncated and ", after 5 of 24 fragments of another message" or ""))
end

local function start()
	box, lastError, round, state = nil, nil, nil, nil
	sender:clear()
	reassembler:reset()
	local verified, reason = romcheck.verify(addresses.romCrc32, emu:checksum())
	if not verified then console:error(TAG .. reason); return end
	local symbol = type(addresses.symbols) == "table" and addresses.symbols.gCoopMailbox
	if type(symbol) ~= "table" or type(symbol.addr) ~= "number" then
		console:error(TAG .. "gCoopMailbox missing; regenerate addresses.lua")
		return
	end
	box = mailbox.new(emu, symbol.addr)
	console:log(TAG .. reason .. "; mailbox only, no network")
end

local function reportError(reason)
	if reason ~= lastError then console:error(TAG .. reason) end
	lastError = reason
end

local function onEcho(msgType, data)
	local r = ROUNDS[round]
	if msgType ~= mailbox.MSG.DEBUG_ECHO then
		reportError("unexpected message type " .. msgType)
		return
	end
	if data == r.data then
		console:log(string.format("%sround %d PASS: %d bytes match byte-for-byte after %d frames; "
			.. "%d presence messages arrived meanwhile", TAG, round, #data, state.frames, state.presences))
	else
		local first = 1
		while first <= math.min(#data, #r.data) and data:byte(first) == r.data:byte(first) do first = first + 1 end
		console:error(string.format("%sround %d FAIL: got %d bytes, want %d; first difference at byte %d",
			TAG, round, #data, #r.data, first - 1))
	end
	startRound(round + 1)
end

local function poll()
	if not box then return end
	local ready, reason = box:check()
	if not ready then reportError("mailbox unavailable: " .. reason); return end
	if not round then
		-- The ROM reads the inbound ring and sends multi-slot messages only
		-- while lua_connected is set.
		box:setLuaConnected(true)
		startRound(1)
		if not box then return end
	end
	state.frames = state.frames + 1
	while #state.truncated > 0 and push(state.truncated[1]) do table.remove(state.truncated, 1) end
	if #state.truncated == 0 then
		local _, err = sender:pump(push)
		if err and err ~= "mailbox inbound ring full" then reportError(err) end
	end
	while box do
		local message, popError = box:pop()
		if popError then reportError(popError); return end
		if not message then break end
		if message.type == mailbox.MSG.PRESENCE then
			state.presences = state.presences + 1
		elseif message.type == mailbox.MSG.FRAGMENT then
			local msgType, data, dropped = reassembler:feed(message.payload)
			if dropped then reportError(dropped) end
			if msgType then onEcho(msgType, data) end
		end
	end
	if box and state.frames == TIMEOUT_FRAMES then
		reportError(string.format("round %d: no echo after %d frames. Is the game in the overworld?",
			round, TIMEOUT_FRAMES))
	end
end

local function stop()
	if box then box:setLuaConnected(false) end
	box = nil
end
callbacks:add("start", start)
callbacks:add("frame", poll)
callbacks:add("stop", stop)
callbacks:add("shutdown", stop)
if emu then start() end
