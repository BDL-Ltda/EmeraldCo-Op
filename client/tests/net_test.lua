-- Tests for client/net.lua with a fake socket and clock: no mGBA or server.
local net, json, h = require("net"), require("json"), require("helpers")
local tests = {}

local AGAIN = "again"
local KEY = "secret-key-123"
local CONFIG = { SERVER_HOST = "127.0.0.1", SERVER_PORT = 8765, PLAYER_ID = "bernardo", JOIN_KEY = KEY }

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
	local world = { sockets = {}, logs = {}, errors = {}, refuse = nil }
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
	w.sock().deliver('{"v":1,"type":"welcome","players":[]}\n')
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
	h.same(sent[1], json.object({ v = 1, type = "hello", playerId = "bernardo", joinKey = KEY,
		trainerId = 12345, gender = 1, clientVersion = net.CLIENT_VERSION }))
	-- Nothing else until welcome arrives.
	w.step(5000)
	h.eq(#w.sock().take(), 0)
end

tests["welcome starts presence and ping"] = function()
	local w = setup()
	w.step(0, state())
	w.sock().take()
	w.sock().deliver('{"v":1,"type":"welcome","players":[{"playerId":"leo","trainerId":7,"gender":1,'
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
	h.same(sent[2], json.object({ v = 1, type = "presence", playerId = "bernardo", mapGroup = 0, mapNum = 9,
		x = 5, y = 3, facing = 1, visible = true }))
	assert(w.client:isConnected())
end

tests["presence is sent only when the state changes"] = function()
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
	w.sock().deliver('{"v":1,"type":"pong","t":5016}\n')
	assert(w.logged("[net] latency 42 ms"))
end

tests["remote players are logged from split chunks"] = function()
	local w = joined()
	local stream = '{"v":1,"type":"join","playerId":"davi","trainerId":54321,"gender":0}\n'
		.. '{"v":1,"type":"presence","playerId":"joao","mapGroup":0,"mapNum":9,"x":7,"y":3,"facing":3,"visible":true}\n'
		.. '{"v":1,"type":"leave","playerId":"davi","reason":"disconnect"}\n'
	local chunks = {}
	for pos = 1, #stream, 7 do chunks[#chunks + 1] = stream:sub(pos, pos + 6) end
	w.sock().deliver(table.unpack(chunks))
	assert(w.logged("[remote] davi joined (trainerId 54321, gender 0)"))
	assert(w.logged("[remote] joao 0:9 7,3 WEST visible"))
	assert(w.logged("[remote] davi left (disconnect)"))
end

tests["invalid and unknown messages are ignored without logging their text"] = function()
	local w = joined()
	w.sock().deliver('{"v":1,"type":"presence","playerId":"' .. KEY .. '","mapGroup":0}\n',
		'{"v":1,"type":"emote","name":"wave"}\n')
	assert(w.logged("ignoring an invalid message from the server"))
	assert(not w.logged(KEY))
	assert(w.client:isConnected())
	h.eq(w.sock().closed, false)
end

tests["a wrong join key stops retrying with a readable error"] = function()
	local w = setup()
	w.step(0, state())
	w.sock().deliver('{"v":1,"type":"error","code":"bad_key","message":"wrong join key"}\n',
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
	w.sock().deliver('{"v":1,"type":"error","code":"room_full","message":"the room is full"}\n')
	assert(w.sock().closed)
	w.step(4999)
	h.eq(#w.sockets, 1)
	w.step(1)
	h.eq(#w.sockets, 2)
end

tests["another protocol version stops retrying"] = function()
	local w = setup()
	w.step(0, state())
	w.sock().deliver('{"v":2,"type":"welcome","players":[]}\n')
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

return tests
