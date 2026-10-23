-- Issue #24 acceptance tool. Load instead of bridge.lua in mGBA 0.10.5.
-- Reads only the mailbox, never game structs; no config, key or server needed.
-- Scripting > File > Reset before switching between this script and the bridge:
-- an outbound ring must have exactly one Lua reader.
local DIR = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = DIR .. "../lib/?.lua;" .. package.path
local mailbox = require("mailbox")
local romcheck = require("romcheck")
local protocol = require("protocol")

local chunk, loadError = loadfile(DIR .. "../addresses.lua")
if not chunk then console:error("[presence-check] " .. tostring(loadError)); return end
local ok, addresses = pcall(chunk)
if not ok or type(addresses) ~= "table" then
	console:error("[presence-check] addresses.lua must return a table")
	return
end

local box, lastError
local frames, total, lastTotal = 0, 0, 0
local waitingFrames = 0

local function start()
	box, lastError = nil, nil
	frames, total, lastTotal = 0, 0, 0
	waitingFrames = 0
	local verified, reason = romcheck.verify(addresses.romCrc32, emu:checksum())
	if not verified then console:error("[presence-check] " .. reason); return end
	local symbol = type(addresses.symbols) == "table" and addresses.symbols.gCoopMailbox
	if type(symbol) ~= "table" or type(symbol.addr) ~= "number" then
		console:error("[presence-check] gCoopMailbox missing; regenerate addresses.lua")
		return
	end
	box = mailbox.new(emu, symbol.addr)
	console:log("[presence-check] " .. reason .. "; mailbox only, no network")
end

local function reportError(reason)
	if reason ~= lastError then console:error("[presence-check] " .. reason) end
	lastError = reason
end

local function poll()
	if not box then return end
	local ready, reason = box:check()
	if not ready then
		-- Boot/reset clears EWRAM before CoopMailbox_Init writes the header.
		-- Wait quietly through that interval; persistent failures remain errors.
		waitingFrames = waitingFrames + 1
		if waitingFrames == 1 then
			console:log("[presence-check] waiting for mailbox initialization: " .. reason)
		elseif waitingFrames == 300 then
			reportError("mailbox unavailable after 300 frames: " .. reason)
		end
		return
	end
	waitingFrames = 0
	lastError = nil
	while true do
		local message, popError = box:pop()
		if popError then reportError(popError); return end
		if not message then break end
		if message.type == mailbox.MSG.PRESENCE then
			local presence, decodeError = mailbox.decodePresence(message.payload)
			if not presence then reportError(decodeError); return end
			total = total + 1
			console:log(string.format("[presence #%d] %d:%d %d,%d %s %s gender=%d trainerId=%u",
				total, presence.mapGroup, presence.mapNum, presence.x, presence.y,
				protocol.facingName(presence.facing), presence.visible and "visible" or "hidden",
				presence.gender, presence.trainerId))
		else
			reportError("unexpected outbound message type " .. message.type)
		end
	end
	frames = frames + 1
	if frames % 300 == 0 then
		console:log(string.format("[presence-check] last 300 frames: %d messages; total=%d",
			total - lastTotal, total))
		lastTotal = total
	end
end

local function stop() box = nil end
callbacks:add("start", start)
callbacks:add("frame", poll)
callbacks:add("stop", stop)
callbacks:add("shutdown", stop)
if emu then start() end
