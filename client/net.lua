-- Network client for milestone 0.2 (#17): connects to the relay server, sends
-- hello, presence when the local state changes and a ping every 5 s, and logs
-- the other players. Protocol: docs/protocol.md.
--
-- Pure apart from what it is given: no emu, socket or callbacks globals, so
-- tests can drive it with a fake socket and clock. bridge.lua wires it to
-- mGBA's socket API (docs/mgba-scripting.md).

local framing = require("framing")
local protocol = require("protocol")

local M = {
	CLIENT_VERSION = "0.2.0",
	PING_INTERVAL_MS = 5000,
	RETRY_INTERVAL_MS = 5000,
	-- The server closes a connection that sends more than 50 messages in one
	-- second. Presence goes out at most once per 2 frames (one frame is about
	-- 16.7 ms), so about 30 per second.
	MIN_PRESENCE_INTERVAL_MS = 30,
	-- Messages sent per clock second (now // 1000). bridge.lua's clock keeps
	-- that second within one wall-clock second (lib/netclock.lua), so any real
	-- second spans at most two of them: 40 messages, plus at most one held
	-- back by a blocked socket, below the server's 50, even when fast-forward
	-- runs many frames per real second.
	MAX_MESSAGES_PER_SECOND = 20,
	-- Bytes received per receive() call.
	RECEIVE_CHUNK = 4096,
	-- A server that stops reading must not grow the send buffer without bound.
	MAX_OUTBOX = 64 * 1024,
	-- Without DEBUG, latency is logged on the first pong and then every Nth.
	LATENCY_LOG_EVERY = 12,
}

-- Error codes after which retrying with the same config or client can't
-- succeed. The others (room_full, bad_message) are retried.
local FATAL_ERRORS = {
	bad_key = "Check JOIN_KEY in client/config.lua, then reload the script.",
	version_mismatch = "Update the client to the server's version, then reload the script.",
	bad_hello = "The server rejected this client's hello. Report it, with the console log.",
}

-- Checks the network settings of client/config.lua. Returns nil or a reason.
-- Never includes the join key or the host in the reason.
function M.checkConfig(config)
	if type(config.SERVER_HOST) ~= "string" or config.SERVER_HOST == "" then
		return "SERVER_HOST must be a non-empty string"
	end
	local port = config.SERVER_PORT
	if math.type(port) ~= "integer" or port < 1 or port > 65535 then
		return "SERVER_PORT must be an integer from 1 to 65535"
	end
	local reason = protocol.checkPlayerId(config.PLAYER_ID)
	if reason then return "PLAYER_ID " .. reason end
	reason = protocol.checkJoinKey(config.JOIN_KEY)
	if reason then return "JOIN_KEY " .. reason end
end

local function formatPresence(m)
	return string.format("%d:%d %d,%d %s %s", m.mapGroup, m.mapNum, m.x, m.y,
		protocol.facingName(m.facing), m.visible and "visible" or "hidden")
end

local function samePresence(a, b)
	return a and b and a.mapGroup == b.mapGroup and a.mapNum == b.mapNum and a.x == b.x
		and a.y == b.y and a.facing == b.facing and a.visible == b.visible
end

-- config: the table from client/config.lua.
-- env:
--   connect(host, port): a connected socket, or nil and an error. The socket
--     has send(data), receive(maxBytes), close() and add(event, fn), the same
--     shape as mGBA's socket.tcp(). connect may block (docs/mgba-scripting.md).
--   again: the error string for "would block" (socket.ERRORS.AGAIN in mGBA).
--   log(line), logError(line): console output.
-- Returns a client, or nil and an error for an invalid config.
function M.new(config, env)
	local configError = M.checkConfig(config)
	if configError then
		return nil, "network disabled: " .. configError .. ". Fix client/config.lua and reload the script."
	end
	local verbose = config.DEBUG == true
	local log, logError = env.log, env.logError

	local sock = nil
	local framer = nil
	local outbox = ""
	local joined = false -- welcome received on this connection
	local stopped = false -- a fatal error: no more retries until reload
	local now = 0 -- ms, from the last update()
	local nextAttempt = 0
	local identity = nil -- { trainerId, gender } of the current game session
	local helloIdentity = nil -- the identity sent in this connection's hello
	local state = nil -- the last local player state
	local lastSent = nil -- the last presence sent on this connection
	local lastPresenceAt = nil
	local lastPingAt = nil
	local pongs = 0
	local waitingLogged = false
	local budgetSecond, sentThisSecond = nil, 0

	local client = {}

	local function disconnect(why, retryIn)
		if not sock then return end
		local s = sock
		sock, framer, outbox, joined = nil, nil, "", false
		helloIdentity, lastSent, lastPresenceAt, lastPingAt = nil, nil, nil, nil
		s:close()
		if stopped then
			logError("[net] disconnected: " .. why)
			return
		end
		retryIn = retryIn or M.RETRY_INTERVAL_MS
		nextAttempt = now + retryIn
		if retryIn == 0 then
			log("[net] disconnected: " .. why)
		else
			logError(string.format("[net] disconnected: %s; retrying in %d s", why, retryIn // 1000))
		end
	end

	-- Sends as much of the queued bytes as the socket takes right now.
	local function flush()
		if not sock or outbox == "" then return end
		-- send() can't be trusted to notice a dead connection (unmapped errors
		-- look like 1 byte sent); disconnects come from receive() and "error".
		local sent, err = sock:send(outbox)
		if not sent then
			if err ~= env.again then disconnect("send failed: " .. tostring(err)) end
			return
		end
		outbox = outbox:sub(sent + 1)
	end

	local function canSend()
		if budgetSecond ~= now // 1000 then
			budgetSecond, sentThisSecond = now // 1000, 0
		end
		return sentThisSecond < M.MAX_MESSAGES_PER_SECOND
	end

	-- A new ping or presence is only queued once everything before it has gone
	-- out. Messages are then counted when they are transmitted, so a socket
	-- that blocked for seconds can't release a backlog above the budget, and
	-- the latest state waits in `state` instead of the send buffer.
	local function readyToSend()
		flush()
		return sock ~= nil and outbox == "" and canSend()
	end

	local function send(message)
		canSend() -- starts a new second's count if needed
		sentThisSecond = sentThisSecond + 1
		local line, err = protocol.encode(message)
		if not line then
			logError("[net] could not encode " .. tostring(message.type) .. ": " .. err)
			return
		end
		if #outbox + #line + 1 > M.MAX_OUTBOX then
			disconnect("the server is not reading; send buffer full")
			return
		end
		outbox = outbox .. line .. "\n"
		flush()
	end

	local function onMessage(m)
		local kind = m.type
		if m.unknown then
			if verbose then log("[net] ignoring unknown message type " .. kind) end
		elseif kind == "welcome" then
			joined = true
			log(string.format("[net] joined as %s; %d other player(s) online", config.PLAYER_ID, #m.players))
			for _, p in ipairs(m.players) do
				log(string.format("[remote] %s is here (trainerId %d, gender %d)", p.playerId, p.trainerId, p.gender))
				if p.presence then log("[remote] " .. p.playerId .. " " .. formatPresence(p.presence)) end
			end
		elseif kind == "join" then
			log(string.format("[remote] %s joined (trainerId %d, gender %d)", m.playerId, m.trainerId, m.gender))
		elseif kind == "presence" then
			log("[remote] " .. m.playerId .. " " .. formatPresence(m))
		elseif kind == "leave" then
			log(string.format("[remote] %s left (%s)", m.playerId, m.reason))
		elseif kind == "pong" then
			pongs = pongs + 1
			if verbose or pongs % M.LATENCY_LOG_EVERY == 1 then
				log(string.format("[net] latency %d ms", now - m.t))
			end
		elseif kind == "error" then
			local hint = FATAL_ERRORS[m.code]
			logError(string.format("[net] the server rejected this client: %s (%s)", m.code, m.message))
			if hint then
				stopped = true
				logError("[net] stopped. " .. hint)
			end
			disconnect("closed after error " .. m.code)
		end
	end

	local function onLine(line)
		local m, err, versionMismatch = protocol.decode(line)
		if not m then
			if versionMismatch then
				stopped = true
				logError("[net] the server speaks another protocol version. Update the client, then reload the script.")
				disconnect("protocol version mismatch")
			else
				-- Never log the line itself: keep logs free of anything secret.
				logError("[net] ignoring an invalid message from the server: " .. err)
			end
			return
		end
		onMessage(m)
	end

	-- Drains the socket. mGBA calls this from its per-frame select() poll when
	-- data is waiting, so it never waits.
	local function onReceived()
		local reads = 0
		while sock do
			local chunk, err = sock:receive(M.RECEIVE_CHUNK)
			if not chunk then
				-- A first read that would block right after select() said
				-- "readable" is a closed peer on Windows (docs/mgba-scripting.md).
				if err ~= env.again or reads == 0 then
					local closed = err == env.again or err == "disconnected"
					disconnect(closed and "the server closed the connection" or tostring(err))
				end
				return
			end
			reads = reads + 1
			local lines, ferr = framer:feed(chunk)
			if not lines then
				disconnect("bad data from the server: " .. ferr)
				return
			end
			for _, line in ipairs(lines) do
				if not sock then return end
				onLine(line)
			end
		end
	end

	local function connect()
		local reason = protocol.checkHelloIdentity(config.PLAYER_ID, config.JOIN_KEY,
			identity.trainerId, identity.gender, M.CLIENT_VERSION)
		if reason then
			logError("[net] cannot send hello: " .. reason)
			nextAttempt = now + M.RETRY_INTERVAL_MS
			return
		end
		log("[net] connecting to the server")
		-- Blocks the game until it succeeds or fails.
		local s, err = env.connect(config.SERVER_HOST, config.SERVER_PORT)
		if not s then
			nextAttempt = now + M.RETRY_INTERVAL_MS
			logError(string.format("[net] connect failed: %s; retrying in %d s",
				tostring(err), M.RETRY_INTERVAL_MS // 1000))
			return
		end
		sock, framer, outbox = s, framing.new(), ""
		s:add("received", onReceived)
		s:add("error", function(_, e) disconnect(tostring(e)) end)
		log("[net] connected; sending hello")
		helloIdentity = identity
		send(protocol.hello(config.PLAYER_ID, config.JOIN_KEY, identity.trainerId, identity.gender,
			M.CLIENT_VERSION))
	end

	-- Called once per game loop with memory.lua's getPlayerState().
	function client.setPlayerState(_, s)
		-- A sample without a position must not replace one that is still waiting
		-- for the throttle or the budget: after a soft reset memory.lua reports
		-- the last position as hidden only once, then no position at all.
		if s.mapGroup ~= nil or not state or state.mapGroup == nil or samePresence(state, lastSent) then
			state = s
		end
		if s.trainerId ~= nil and s.gender ~= nil then
			if not identity or identity.trainerId ~= s.trainerId or identity.gender ~= s.gender then
				identity = { trainerId = s.trainerId, gender = s.gender }
			end
		end
	end

	-- Called once per frame. nowMs: a millisecond clock that never goes back.
	function client.update(_, nowMs)
		now = nowMs
		if stopped then return end
		if not sock then
			if not identity then
				if not waitingLogged then
					log("[net] waiting for a game to start before connecting")
					waitingLogged = true
				end
				return
			end
			if now >= nextAttempt then connect() end
			return
		end
		-- hello carries the trainer ID and gender; a new game session with
		-- another save needs a new hello. The server replaces our old connection.
		if helloIdentity and identity ~= helloIdentity then
			disconnect("the game session changed; reconnecting with a new hello", 0)
			return
		end
		if joined then
			if (not lastPingAt or now - lastPingAt >= M.PING_INTERVAL_MS) and readyToSend() then
				lastPingAt = now
				send(protocol.ping(now))
			end
			if state and state.mapGroup ~= nil and not samePresence(state, lastSent)
				and (not lastPresenceAt or now - lastPresenceAt >= M.MIN_PRESENCE_INTERVAL_MS) and readyToSend() then
				local reason = protocol.checkPresenceState(state)
				if reason then
					-- Remembered as sent so it is skipped (and logged) once, not every frame.
					lastSent = state
					if verbose then log("[net] not sending presence: " .. reason) end
				else
					local message = protocol.presence(config.PLAYER_ID, state)
					lastSent, lastPresenceAt = message, now
					if verbose then log("[net] sent presence " .. formatPresence(message)) end
					send(message)
				end
			end
		end
		flush()
	end

	-- Closes the connection, e.g. when the ROM changes or emulation stops.
	-- The next update() reconnects once a verified game is running again.
	function client.close(_, why)
		disconnect(why, 0)
		identity, state = nil, nil
		waitingLogged = false
	end

	function client.isConnected()
		return sock ~= nil and joined
	end

	return client
end

return M
