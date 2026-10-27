-- Tests for client/net.lua with a fake socket and clock: no mGBA or server.
local net, json, h = require("net"), require("json"), require("helpers")
local tests = {}

local AGAIN = "again"
local KEY = "secret-key-123"
local CONFIG = { SERVER_HOST = "127.0.0.1", SERVER_PORT = 8765, PLAYER_ID = "bernardo", JOIN_KEY = KEY, DEBUG = true }

-- A socket shaped like mGBA's: the test plays the server through it.
local function newSocket()
	local sock = { sent = "", inbox = {}, handlers = {}, closed = false, accept = nil }
	function sock.add(_, event, fn) sock.handlers[event] = fn end
	function sock.send(_, data)
		if sock.sendError then return nil, sock.sendError end
		local n = sock.accept and math.min(sock.accept, #data) or #data
		sock.sent = sock.sent .. data:sub(1, n)
		return n
	end
	function sock.receive(_, max)
		local chunk = table.remove(sock.inbox, 1)
		if chunk == nil then return nil, AGAIN end
		if type(chunk) == "table" then return nil, chunk.err end
		assert(#chunk <= max)
		return chunk
	end
	function sock.close() sock.closed = true end
	-- Server -> client bytes, delivered like mGBA's per-frame "received" event.
	function sock.deliver(...)
		for _, chunk in ipairs({ ... }) do sock.inbox[#sock.inbox + 1] = chunk end
		sock.handlers.received(sock)
	end
	-- Complete lines the client sent, decoded, and cleared.
	function sock.take()
		local out = {}
		for text in sock.sent:gmatch("([^\n]*)\n") do out[#out + 1] = assert(json.decode(text)) end
		sock.sent = sock.sent:match("[^\n]*$")
		return out
	end
	return sock
end

-- A client plus its world: sockets it opened, logs and a clock.
local function setup(config)
	local world = { sockets = {}, logs = {}, errors = {}, events = {}, refuse = nil }
	local cfg = {}
	for k, v in pairs(CONFIG) do cfg[k] = v end
	for k, v in pairs(config or {}) do cfg[k] = v end
	world.client = assert(net.new(cfg, {
		connect = function(host, port)
			h.eq(host, cfg.SERVER_HOST)
			h.eq(port, cfg.SERVER_PORT)
			if world.refuse then
				world.attempts = (world.attempts or 0) + 1
				return nil, world.refuse
			end
			local s = newSocket()
			world.sockets[#world.sockets + 1] = s
			return s
		end,
		again = AGAIN,
		log = function(text) world.logs[#world.logs + 1] = text end,
		logError = function(text) world.errors[#world.errors + 1] = text end,
		onEvent = function(kind, data, now)
			world.events[#world.events + 1] = { kind = kind, data = data, now = now }
		end,
	}))
	world.now = 0
	function world.step(ms, state)
		world.now = world.now + (ms or 0)
		if state then world.client:setPlayerState(state) end
		world.client:update(world.now)
	end
	function world.sock() return world.sockets[#world.sockets] end
	function world.logged(pattern)
		for _, list in ipairs({ world.logs, world.errors }) do
			for _, text in ipairs(list) do
				if text:find(pattern, 1, true) then return true end
			end
		end
		return false
	end
	return world
end

local function state(x, y, facing, extra)
	local s = { mapGroup = 0, mapNum = 9, x = x or 5, y = y or 3, facing = facing or 1, visible = true,
		trainerId = 12345, gender = 1 }
	for k, v in pairs(extra or {}) do s[k] = v end
	return s
end

-- Connected, hello answered with an empty welcome, first ping and presence taken.
local function joined(config)
	local w = setup(config)
	w.step(0, state())
	w.sock().deliver('{"v":2,"type":"welcome","players":[]}\n')
	w.step(16)
	w.sock().take()
	return w
end

tests["invalid network settings disable networking with a clear error"] = function()
	local env = { connect = function() error("must not connect") end, again = AGAIN, log = print, logError = print }
	local cases = {
		{ { SERVER_HOST = "" }, "SERVER_HOST" },
		{ { SERVER_PORT = 0 }, "SERVER_PORT" },
		{ { SERVER_PORT = "8765" }, "SERVER_PORT" },
		{ { PLAYER_ID = "your player" }, "PLAYER_ID may only contain" },
		{ { PLAYER_ID = string.rep("a", 17) }, "PLAYER_ID must be 1-16" },
		{ { JOIN_KEY = "" }, "JOIN_KEY must be 1-64" },
		{ { JOIN_KEY = KEY .. "\t" }, "JOIN_KEY contains a control character" },
	}
	for _, case in ipairs(cases) do
		local cfg = {}
		for k, v in pairs(CONFIG) do cfg[k] = v end
		for k, v in pairs(case[1]) do cfg[k] = v end
		local client, err = net.new(cfg, env)
		h.rejected(client, err)
		assert(err:find(case[2], 1, true), err)
		assert(not err:find(KEY, 1, true), "error leaks the join key")
	end
end

tests["waits for a game session before connecting"] = function()
	local w = setup()
	w.step(0)
	w.step(16, { visible = false })
	h.eq(#w.sockets, 0)
	assert(w.logged("waiting for a game to start"))
	w.step(16, state())
	h.eq(#w.sockets, 1)
end

tests["connect sends hello with the save's identity"] = function()
	local w = setup()
	w.step(0, state())
	local sent = w.sock().take()
	h.eq(#sent, 1)
	h.same(sent[1], json.object({ v = 2, type = "hello", playerId = "bernardo", joinKey = KEY,
		trainerId = 12345, gender = 1, clientVersion = net.CLIENT_VERSION }))
	-- Nothing else until welcome arrives.
	w.step(5000)
	h.eq(#w.sock().take(), 0)
end

tests["welcome starts presence and ping"] = function()
	local w = setup()
	w.step(0, state())
	w.sock().take()
	w.sock().deliver('{"v":2,"type":"welcome","players":[{"playerId":"leo","trainerId":7,"gender":1,'
		.. '"presence":{"mapGroup":0,"mapNum":9,"x":7,"y":5,"facing":3,"visible":true}},'
		.. '{"playerId":"davi","trainerId":9,"gender":0}]}\n')
	assert(w.logged("[net] joined as bernardo; 2 other player(s) online"))
	assert(w.logged("[remote] leo 0:9 7,5 WEST visible"))
	assert(w.logged("[remote] davi is here"))
	w.step(16)
	local sent = w.sock().take()
	h.eq(#sent, 2)
	h.eq(sent[1].type, "ping")
	h.eq(sent[2].type, "presence")
	h.same(sent[2], json.object({ v = 2, type = "presence", playerId = "bernardo", mapGroup = 0, mapNum = 9,
		x = 5, y = 3, facing = 1, visible = true }))
	assert(w.client:isConnected())
end

tests["presence changes are sent without per-frame repeats"] = function()
	local w = joined()
	w.step(33, state())
	w.step(33, state())
	h.eq(#w.sock().take(), 0)
	w.step(33, state(6, 3, 4))
	w.step(33, state(6, 3, 2))
	w.step(33, state(6, 3, 2, { visible = false }))
	w.step(33, state(6, 3, 2, { mapNum = 10 }))
	local sent = w.sock().take()
	h.eq(#sent, 4)
	h.eq(sent[1].x, 6)
	h.eq(sent[2].facing, 2)
	h.eq(sent[3].visible, false)
	h.eq(sent[4].mapNum, 10)
	-- No position yet (new session) or an impossible facing: nothing to send.
	w.step(33, { visible = true, trainerId = 12345, gender = 1 })
	w.step(33, state(1, 1, 0))
	w.step(33, state(1, 1, 0))
	h.eq(#w.sock().take(), 0)
end

tests["presence is throttled below the server's rate limit"] = function()
	-- joined() sent the first presence at 16 ms; frames are 16-17 ms apart.
	local w = joined()
	w.step(16, state(6))
	w.step(16, state(7))
	w.step(16, state(8))
	w.step(16, state(8))
	local sent = w.sock().take()
	h.eq(#sent, 2)
	h.eq(sent[1].x, 7)
	h.eq(sent[2].x, 8)
end

tests["ping every 5 s and latency from pong"] = function()
	local w = joined()
	w.step(4999)
	h.eq(#w.sock().take(), 0)
	w.step(1)
	local sent = w.sock().take()
	h.eq(#sent, 1)
	h.eq(sent[1].type, "ping")
	h.eq(sent[1].t, 5016)
	w.step(42)
	w.sock().deliver('{"v":2,"type":"pong","t":5016}\n')
	assert(w.logged("[net] latency 42 ms"))
end

tests["remote players are logged from split chunks"] = function()
	local w = joined()
	local stream = '{"v":2,"type":"join","playerId":"davi","trainerId":54321,"gender":0}\n'
		.. '{"v":2,"type":"presence","playerId":"joao","mapGroup":0,"mapNum":9,"x":7,"y":3,"facing":3,"visible":true}\n'
		.. '{"v":2,"type":"leave","playerId":"davi","reason":"disconnect"}\n'
	local chunks = {}
	for pos = 1, #stream, 7 do chunks[#chunks + 1] = stream:sub(pos, pos + 6) end
	w.sock().deliver(table.unpack(chunks))
	assert(w.logged("[remote] davi joined (trainerId 54321, gender 0)"))
	assert(w.logged("[remote] joao 0:9 7,3 WEST visible"))
	assert(w.logged("[remote] davi left (disconnect)"))
end

tests["invalid and unknown messages are ignored without logging their text"] = function()
	local w = joined()
	w.sock().deliver('{"v":2,"type":"presence","playerId":"' .. KEY .. '","mapGroup":0}\n',
		'{"v":2,"type":"emote","name":"wave"}\n')
	assert(w.logged("ignoring an invalid message from the server"))
	assert(not w.logged(KEY))
	assert(w.client:isConnected())
	h.eq(w.sock().closed, false)
end

tests["a wrong join key stops retrying with a readable error"] = function()
	local w = setup()
	w.step(0, state())
	w.sock().deliver('{"v":2,"type":"error","code":"bad_key","message":"wrong join key"}\n',
		{ err = "disconnected" })
	assert(w.logged("the server rejected this client: bad_key (wrong join key)"))
	assert(w.logged("Check JOIN_KEY in client/config.lua"))
	assert(w.sock().closed)
	w.step(60000)
	h.eq(#w.sockets, 1)
	for _, list in ipairs({ w.logs, w.errors }) do
		for _, text in ipairs(list) do assert(not text:find(KEY, 1, true), "log leaks the join key") end
	end
end

tests["a full room is retried"] = function()
	local w = setup()
	w.step(0, state())
	w.sock().deliver('{"v":2,"type":"error","code":"room_full","message":"the room is full"}\n')
	assert(w.sock().closed)
	w.step(4999)
	h.eq(#w.sockets, 1)
	w.step(1)
	h.eq(#w.sockets, 2)
end

tests["another protocol version stops retrying"] = function()
	local w = setup()
	w.step(0, state())
	w.sock().deliver('{"v":1,"type":"welcome","players":[]}\n')
	assert(w.logged("another protocol version"))
	assert(w.sock().closed)
	w.step(60000)
	h.eq(#w.sockets, 1)
end

tests["a lost connection is retried every 5 s"] = function()
	local w = joined()
	w.sock().deliver({ err = "disconnected" })
	assert(w.sock().closed)
	assert(w.logged("disconnected: the server closed the connection; retrying in 5 s"))
	h.eq(w.client:isConnected(), false)
	w.refuse = "connection refused"
	w.step(4999)
	h.eq(w.attempts, nil)
	w.step(1)
	h.eq(w.attempts, 1)
	assert(w.logged("connect failed: connection refused; retrying in 5 s"))
	w.step(4999)
	h.eq(w.attempts, 1)
	w.step(1)
	h.eq(w.attempts, 2)
	w.refuse = nil
	w.step(5000)
	h.eq(#w.sockets, 2)
	h.eq(w.sock().take()[1].type, "hello")
end

tests["a readable socket with nothing to read is a closed peer"] = function()
	local w = joined()
	w.sock().deliver()
	assert(w.sock().closed)
end

tests["the socket error event disconnects"] = function()
	local w = joined()
	w.sock().handlers.error(w.sock(), "unknown error")
	assert(w.sock().closed)
	assert(w.logged("disconnected: unknown error"))
end

tests["a failed send disconnects, a blocked one waits"] = function()
	local w = joined()
	w.sock().sendError = AGAIN
	w.step(33, state(9))
	h.eq(w.sock().closed, false)
	w.sock().sendError = "broken pipe"
	w.step(16)
	assert(w.sock().closed)
end

tests["partial sends keep the rest for the next frame"] = function()
	local w = joined()
	w.sock().accept = 10
	w.step(33, state(9))
	h.eq(#w.sock().take(), 0)
	w.sock().accept = nil
	w.step(16)
	h.eq(w.sock().take()[1].x, 9)
end

tests["an oversized line from the server disconnects"] = function()
	local w = joined()
	w.sock().deliver(string.rep("x", 4000), string.rep("x", 97))
	assert(w.sock().closed)
	assert(w.logged("line exceeds maximum length"))
end

tests["a new save reconnects with a new hello"] = function()
	local w = joined()
	w.step(16, state(5, 3, 1, { trainerId = 999, gender = 0 }))
	h.eq(w.sockets[1].closed, true)
	w.step(16)
	h.eq(#w.sockets, 2)
	local hello = w.sock().take()[1]
	h.eq(hello.type, "hello")
	h.eq(hello.trainerId, 999)
	h.eq(hello.gender, 0)
end

tests["close waits for the next verified game"] = function()
	local w = joined()
	w.client:close("a game was loaded")
	assert(w.sockets[1].closed)
	w.step(10000)
	h.eq(#w.sockets, 1)
	w.step(16, state())
	h.eq(#w.sockets, 2)
end

tests["net.lua does not use mGBA globals"] = function()
	local source = assert(io.open("client/net.lua", "r"))
	-- Comments may name mGBA's API; the code must not touch its globals.
	local text = source:read("a"):gsub("%-%-[^\n]*", "")
	source:close()
	for _, forbidden in ipairs({ "emu[:.]", "socket[:.]", "callbacks[:.]", "console[:.]" }) do
		assert(not text:match("%f[%w_]" .. forbidden .. "%w"), "net.lua uses " .. forbidden)
	end
end

tests["a throttled hidden presence survives a later no-position sample"] = function()
	-- Keep the hidden tuple while it waits behind the send throttle.
	local w = joined()
	w.step(16, state(5, 3, 1, { visible = false }))
	for _ = 1, 1000 do w.step(16, { visible = false }) end
	local hidden = 0
	for _, m in ipairs(w.sock().take()) do
		if m.type == "presence" then
			h.eq(m.visible, false)
			hidden = hidden + 1
		end
	end
	h.eq(hidden, 2) -- Initial hidden transition plus its 10-second renewal.
	assert(w.client:isConnected())
end

tests["a new position replaces a presence still waiting to be sent"] = function()
	local w = joined()
	-- Both samples arrive inside the throttle window after the 16 ms presence.
	w.step(8, state(5, 3, 1, { visible = false }))
	w.step(8, state(9, 9))
	w.step(16)
	local sent = w.sock().take()
	h.eq(#sent, 1)
	h.eq(sent[1].x, 9)
	h.eq(sent[1].visible, true)
end

tests["no more than the budget is sent in one clock second"] = function()
	local w = joined()
	w.sock().take()
	local count = 0
	-- 1000..1999 ms: one clock second with a new tile every 33 ms.
	w.step(1000 - w.now)
	for i = 1, 30 do w.step(33, state(10 + i)) end
	for _, m in ipairs(w.sock().take()) do
		if m.type == "presence" or m.type == "ping" then count = count + 1 end
	end
	h.eq(count, net.MAX_MESSAGES_PER_SECOND)
	-- The latest state goes out once the next second starts.
	w.step(2000 - w.now, state(10 + 30))
	local sent = w.sock().take()
	h.eq(sent[#sent].x, 40)
end

tests["a socket that blocked for seconds does not release a burst"] = function()
	-- Davi's reproduction: 3.3 s of AGAIN while the player keeps moving, then
	-- the socket takes everything again. Count what is actually transmitted.
	local w = joined()
	local sent = {} -- { at = ms, count = complete messages } per update
	local function step(ms, s)
		w.step(ms, s)
		sent[#sent + 1] = { at = w.now, count = #w.sock().take() }
	end
	w.sock().sendError = AGAIN
	for i = 1, 100 do step(33, state(5 + i)) end
	w.sock().sendError = nil
	step(1)
	assert(sent[#sent].count <= 2, "released " .. sent[#sent].count .. " messages at once")
	for i = 1, 200 do step(16, state(200 + i % 2)) end
	assert(w.client:isConnected())
	for i, first in ipairs(sent) do
		local total = 0
		for j = i, #sent do
			if sent[j].at - first.at >= 1000 then break end
			total = total + sent[j].count
		end
		assert(total < 50, total .. " messages within one second from " .. first.at .. " ms")
	end
end

tests["the latest state is sent once a blocked socket drains"] = function()
	local w = joined()
	w.sock().sendError = AGAIN
	for i = 1, 50 do w.step(33, state(5 + i)) end
	w.step(33, state(5, 3, 1, { visible = false }))
	w.step(33, { visible = false })
	w.sock().sendError = nil
	for _ = 1, 5 do w.step(33) end
	local sent = w.sock().take()
	local last = sent[#sent]
	h.eq(last.type, "presence")
	h.eq(last.visible, false)
	assert(#sent <= 4, "sent " .. #sent .. " messages")
end

tests["fast-forward stays below the server's rate limit"] = function()
	-- 8x speed: 477 frames per real second, a new tile every 8 frames, with
	-- bridge.lua's clock. The server allows 50 messages per rolling second.
	local netclock = require("netclock")
	local w = setup()
	local clock = netclock.new()
	local perSecond = {}
	local frame = 0
	for second = 0, 5 do
		local count = 0
		for _ = 1, 477 do
			frame = frame + 1
			w.client:setPlayerState(state(frame // 8 % 200))
			w.client:update(clock:tick(1000 + second))
			if frame == 1 then w.sock().deliver('{"v":2,"type":"welcome","players":[]}\n') end
			count = count + #w.sock().take()
		end
		perSecond[#perSecond + 1] = count
	end
	assert(w.client:isConnected())
	for i, count in ipairs(perSecond) do
		assert(count <= net.MAX_MESSAGES_PER_SECOND, "second " .. i .. " sent " .. count)
		if i > 1 then assert(count + perSecond[i - 1] < 50, "two seconds sent " .. count + perSecond[i - 1]) end
	end
	assert(perSecond[3] > 0, "nothing was sent")
end

tests["quiet mode still publishes validated panel events"] = function()
	local w = joined({ DEBUG = false })
	w.step(42)
	w.sock().deliver('{"v":2,"type":"join","playerId":"davi","trainerId":7,"gender":0}\n'
		.. '{"v":2,"type":"presence","playerId":"davi","mapGroup":0,"mapNum":9,"x":7,"y":3,"facing":3,"visible":true}\n'
		.. '{"v":2,"type":"pong","t":16}\n'
		.. '{"v":2,"type":"leave","playerId":"davi","reason":"disconnect"}\n')
	assert(not w.logged("[remote]"))
	local types = {}
	for _, event in ipairs(w.events) do
		if event.kind == "message" then types[#types + 1] = event.data.type end
		assert(not assert(json.encode(event)):find(KEY, 1, true), "event leaks the join key")
	end
	h.eq(table.concat(types, ","), "welcome,join,presence,pong,leave")
	h.eq(w.events[#w.events].now, w.now)
	local count = #w.events
	w.sock().deliver('{"v":2,"type":"presence","playerId":"invalid"}\n'
		.. '{"v":2,"type":"future"}\n')
	h.eq(#w.events, count)
	w.sock().deliver({ err = "disconnected" })
	h.eq(w.events[#w.events].data, "Retrying")
end

tests["unchanged presence renews at ten seconds without extra updates"] = function()
	local w = joined()
	w.step(net.PRESENCE_REFRESH_MS - 1, state())
	for _, m in ipairs(w.sock().take()) do assert(m.type ~= "presence") end
	w.step(1, state())
	local sent = w.sock().take()
	h.eq(#sent, 1)
	h.eq(sent[1].type, "presence")
	h.eq(sent[1].x, 5)
	w.step(33, state(8))
	h.eq(w.sock().take()[1].x, 8)
	w.step(net.PRESENCE_REFRESH_MS - 1, state(8))
	for _, m in ipairs(w.sock().take()) do assert(m.type ~= "presence") end
	w.step(1, state(8))
	local renewed = w.sock().take()
	h.eq(renewed[#renewed].x, 8)
end

tests["two idle clients remain in each others panels beyond 45 seconds"] = function()
	local debugview = require("debugview")
	local alice, bob = setup({ PLAYER_ID = "alice" }), setup({ PLAYER_ID = "bob" })
	local views = { debugview.new("localhost", "alice"), debugview.new("localhost", "bob") }
	local worlds = { alice, bob }
	local eventIndex, presenceCount = { 1, 1 }, { 0, 0 }
	for i, w in ipairs(worlds) do
		w.step(0, state())
		w.sock().take() -- hello
		local peerId = i == 1 and "bob" or "alice"
		w.sock().deliver('{"v":2,"type":"welcome","players":[{"playerId":"' .. peerId
			.. '","trainerId":12345,"gender":1}]}\n')
		views[i]:setPlayerState(state())
	end
	for _ = 1, 450 do
		for i, w in ipairs(worlds) do
			w.step(100, state()) -- Same tile/facing throughout, including menus/dialogue.
			for _, m in ipairs(w.sock().take()) do
				if m.type == "presence" then
					presenceCount[i] = presenceCount[i] + 1
					local other = worlds[i == 1 and 2 or 1]
					other.sock().deliver(assert(json.encode(m)) .. "\n")
				elseif m.type == "ping" then
					w.sock().deliver(assert(json.encode({ v = 2, type = "pong", t = m.t })) .. "\n")
				end
			end
		end
		for i, w in ipairs(worlds) do
			while eventIndex[i] <= #w.events do
				local event = w.events[eventIndex[i]]
				views[i]:onEvent(event.kind, event.data, event.now)
				eventIndex[i] = eventIndex[i] + 1
			end
			views[i]:update(w.now)
			local peer = views[i].remotePlayers[i == 1 and "bob" or "alice"]
			assert(peer, "idle peer expired while its connection was alive")
			h.eq(peer.visible, true)
			h.eq(peer.x, 5)
			h.eq(peer.trainerId, 12345)
		end
	end
	for _, count in ipairs(presenceCount) do h.eq(count, 5) end
	assert(alice.client:isConnected() and bob.client:isConnected())
end

tests["reset hidden state keeps renewing without resurrecting the avatar"] = function()
	local view = require("debugview").new("localhost", "observer")
	view:onEvent("message", { type = "welcome", players = {
		{ playerId = "bernardo", trainerId = 12345, gender = 1, presence = state() },
	} }, 0)
	local w = joined()
	w.step(16, state(5, 3, 1, { visible = false }))
	local hidden = 0
	for _ = 1, 450 do
		w.step(100, { visible = false })
		for _, m in ipairs(w.sock().take()) do
			if m.type == "presence" then
				h.eq(m.visible, false)
				hidden = hidden + 1
				view:onEvent("message", m, w.now)
			end
		end
		view:update(w.now)
		local peer = view.remotePlayers.bernardo
		assert(peer, "hidden peer expired")
		h.eq(peer.visible, false)
	end
	h.eq(hidden, 5)
end

tests["renewals wait for a writable socket without building a backlog"] = function()
	local w = joined()
	w.sock().sendError = AGAIN
	for _ = 1, 450 do w.step(100, state()) end
	h.eq(#w.sock().take(), 0)
	w.sock().sendError = nil
	w.step(1)
	local sent = w.sock().take()
	assert(#sent <= 3, "renewal backlog was flushed in a burst")
	h.eq(sent[#sent].type, "presence")
	h.eq(sent[#sent].x, 5)
end

tests["invalid states are not renewed or repeatedly logged"] = function()
	local w = joined()
	w.step(net.PRESENCE_REFRESH_MS, state(5, 3, 0))
	for _ = 1, 100 do w.step(100, state(5, 3, 0)) end
	for _, m in ipairs(w.sock().take()) do assert(m.type ~= "presence") end
	local count = 0
	for _, text in ipairs(w.logs) do
		if text:find("not sending presence", 1, true) then count = count + 1 end
	end
	h.eq(count, 1)
end

tests["late callbacks from a closed socket cannot affect the replacement"] = function()
	local w = joined()
	local old = w.sock()
	w.client:close("ROM reset")
	w.step(16, state())
	local current = w.sock()
	current.deliver('{"v":2,"type":"welcome","players":[]}\n')
	w.step(16)
	old.handlers.error(old, "late old error")
	old.handlers.received(old)
	h.eq(current.closed, false)
	h.eq(w.client.isConnected(), true)
end

return tests
