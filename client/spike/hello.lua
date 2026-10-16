-- Spike for issue #8: validate mGBA Lua scripting on the pinned mGBA 0.10.5.
-- Throwaway code, not the real client. Findings: docs/mgba-scripting.md.
--
-- Load it from mGBA: Tools > Scripting... > File > Load script...
-- Test server: go run ./cmd/echoserver (listens on 127.0.0.1:8765).
--
-- What it checks:
--   1. prints a start message once;
--   2. a frame callback prints a counter every 60 frames;
--   3. emu:read8/16/32 at the base of EWRAM and of the ROM (bases come from
--      mGBA's own memory domains, no address literals);
--   4. a TCP line round trip with the echo server, polled from the frame
--      callback. Receive polling and queued sends don't wait for network
--      data; connection attempts still block the emulator;
--   5. if the server goes away it logs the error, keeps running and retries
--      with backoff, because each connect() attempt stalls the game.

local HOST = "127.0.0.1"
local PORT = 8765
local REPORT_EVERY = 60 -- frames (about 1 s at the GBA's ~59.7 fps)
local PING_EVERY = 300 -- frames between test lines while connected
local RETRY_FIRST = 300 -- frames before the first reconnect attempt (~5 s)
local RETRY_MAX = 3600 -- backoff cap in frames (~60 s)
local RECV_CHUNK = 1024

local frames = 0
local sock = nil
local nextRetry = 0
local retryDelay = RETRY_FIRST -- doubles after each failed connect
local inbox = "" -- bytes received but not yet split into lines
local outbox = "" -- bytes queued but not yet accepted by send()
local pings = 0

local function hex(value, digits)
	return string.format("0x%0" .. digits .. "X", value)
end

-- (3) Memory reads. emu exists only while a game is loaded, so this runs from
-- the "start" callback, or right away if the script is loaded mid-game.
local function dumpMemory()
	for _, name in ipairs({ "wram", "cart0" }) do
		local domain = emu.memory[name]
		local base = domain:base()
		console:log(string.format(
			"[mem] %s (%s): base=%s read8=%s read16=%s read32=%s",
			name, domain:name(), hex(base, 8),
			hex(emu:read8(base), 2), hex(emu:read16(base), 4), hex(emu:read32(base), 8)))
	end
	console:log("[mem] game title from header: " .. emu:getGameTitle())
end

local function disconnect(reason)
	if sock then
		console:error("[net] disconnected: " .. tostring(reason))
		sock:close()
		sock = nil
	end
	inbox = ""
	outbox = ""
	retryDelay = RETRY_FIRST
	nextRetry = frames + retryDelay
end

local function flush()
	if not sock or outbox == "" then
		return
	end
	-- send() can't be trusted to notice a dead connection: in 0.10.5, errors
	-- mGBA doesn't map (e.g. connection reset) come back as "1 byte sent".
	-- The "received" and "error" events catch disconnects instead.
	local sent, err = sock:send(outbox)
	if not sent then
		if err ~= socket.ERRORS.AGAIN then
			disconnect(err)
		end
		return
	end
	-- send() may accept only part of the buffer; keep the rest for next frame.
	outbox = string.sub(outbox, sent + 1)
end

local function sendLine(line)
	outbox = outbox .. line .. "\n"
	flush()
end

-- (4) Drain everything available. Only called when select() reported data,
-- and the socket is non-blocking, so this never waits.
local function onReceived()
	local reads = 0
	while sock do
		local chunk, err = sock:receive(RECV_CHUNK)
		if not chunk then
			-- "disconnected" when the server closed the connection. A first read
			-- that would block right after select() said "readable" is also a
			-- closed peer: recv() returned 0 and the error code mGBA read can be
			-- a stale one from an earlier call.
			if err ~= socket.ERRORS.AGAIN or reads == 0 then
				disconnect(err)
			end
			break
		end
		reads = reads + 1
		inbox = inbox .. chunk
		for line in string.gmatch(inbox, "([^\n]*)\n") do
			console:log("[net] echo: " .. line)
		end
		inbox = string.match(inbox, "[^\n]*$")
	end
end

-- (4) and (5). connect() is the only blocking call in the socket API: the game
-- stalls until it succeeds or fails. On Windows even a refused connect to
-- localhost takes about 2 s, so failed attempts back off from ~5 s to ~60 s.
-- See docs/mgba-scripting.md.
local function tryConnect()
	console:log(string.format("[net] connecting to %s:%d", HOST, PORT))
	local s = socket.tcp()
	local ok, err = s:connect(HOST, PORT)
	if not ok then
		console:error("[net] connect failed: " .. tostring(err) .. "; retrying in " .. retryDelay .. " frames")
		s:close()
		nextRetry = frames + retryDelay
		retryDelay = math.min(retryDelay * 2, RETRY_MAX)
		return
	end
	sock = s
	retryDelay = RETRY_FIRST
	-- mGBA polls connected sockets once per frame and dispatches these events.
	sock:add("received", onReceived)
	sock:add("error", function(_, e) disconnect(e) end)
	console:log("[net] connected")
	sendLine("hello from Emerald Co-Op at frame " .. frames)
end

-- (2) Per-frame work: counter, retries, periodic pings and pending sends.
local function onFrame()
	frames = frames + 1
	if frames % REPORT_EVERY == 0 then
		console:log(string.format("[frame] %d (emulator frame %d)", frames, emu:currentFrame()))
	end
	if sock then
		if frames % PING_EVERY == 0 then
			pings = pings + 1
			sendLine("ping " .. pings)
		else
			flush()
		end
	elseif frames >= nextRetry then
		tryConnect()
	end
end

-- (1) Printed once, when the script is loaded.
console:log("Emerald Co-Op bridge started")

callbacks:add("frame", onFrame)
callbacks:add("start", dumpMemory)
callbacks:add("shutdown", function() disconnect("emulation shut down") end)
if emu then
	dumpMemory()
end
