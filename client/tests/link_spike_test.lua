local h = require("helpers")
local mailbox = require("mailbox")
local fragments = require("fragments")
local json = require("json")
local tests = {}

local function harness(valid, delay)
	local handlers, outbound, inbound, sent, logs, network = {}, {}, {}, {}, {}, {}
	local box = { connected = false }
	function box.check() return true end
	function box:setLuaConnected(value) self.connected = value end
	function box.pop() return table.remove(outbound, 1) end
	function box.push(_, kind, payload) inbound[#inbound + 1] = { kind, payload }; return true end
	local sock = { closed = false }
	function sock.connect() return true end
	function sock.send(_, data) sent[#sent + 1] = data; return #data end
	function sock.receive() return table.remove(network, 1), "again" end
	function sock.add(_, event, fn) handlers[event] = fn end
	function sock.close() sock.closed = true end
	local env = setmetatable({
		console = { log = function(_, s) logs[#logs + 1] = s end,
			error = function(_, s) logs[#logs + 1] = s end },
		callbacks = { add = function(_, event, fn) handlers[event] = fn end },
		emu = { checksum = function() return "fixture" end },
		socket = { tcp = function() return sock end, ERRORS = { AGAIN = "again" } },
		loadfile = function(path)
			if path:match("config%.lua$") then
				return function() return { SERVER_HOST = "fixture", SERVER_PORT = 8765, JOIN_KEY = "fixture-key" } end
			end
			return function() return { symbols = { gCoopMailbox = { addr = 123 } } } end
		end,
		require = function(name)
			if name == "mailbox" then
				return setmetatable({ new = function() return box end }, { __index = mailbox })
			elseif name == "romcheck" then return { verify = function() return valid, "fixture" end } end
			return require(name)
		end,
	}, { __index = _G })
	assert(loadfile("client/spike/link.lua", "t", env))()("spike_a", "spike_b", 0, delay or 0)
	local result = { handlers = handlers, logs = logs, sock = sock, box = box }
	function result.tick(n) for _ = 1, n or 1 do handlers.frame() end end
	function result.presence()
		local data = assert(mailbox.encodePresence({ mapGroup = 0, mapNum = 9, x = 10, y = 10,
			facing = 1, visible = true, trainerId = 42, gender = 0 }))
		outbound[#outbound + 1] = { type = mailbox.MSG.PRESENCE, payload = data }
	end
	function result.receive(message)
		network[#network + 1] = assert(json.encode(message)) .. "\n"
		handlers.received()
	end
	function result.ready()
		result.presence(); result.tick()
		result.receive({ v = 2, type = "welcome", players = json.array() })
		result.receive({ v = 2, type = "trade_available", playerId = "spike_b", available = true })
		result.tick()
	end
	function result.rom(data)
		for _, payload in ipairs(assert(fragments.split(5, data))) do
			outbound[#outbound + 1] = { type = mailbox.MSG.FRAGMENT, payload = payload }
		end
	end
	function result.wire()
		local messages = {}
		for line in table.concat(sent):gmatch("([^\n]+)\n") do messages[#messages + 1] = assert(json.decode(line)) end
		return messages
	end
	function result.inbound()
		local messages, reassembler = {}, fragments.newReassembler()
		for _, slot in ipairs(inbound) do
			local kind, data = reassembler:feed(slot[2])
			if kind then messages[#messages + 1] = data end
		end
		return messages
	end
	return result
end

tests["spike refuses a mismatched ROM before attaching or connecting"] = function()
	local t = harness(false)
	h.eq(t.handlers.frame, nil)
	h.eq(t.box.connected, false)
end

tests["spike waits for overworld identity and starts the selected role only after partner readiness"] = function()
	local t = harness(true)
	t.tick(); h.eq(#t.wire(), 0)
	t.presence(); t.tick()
	h.eq(t.wire()[1].type, "hello"); h.eq(t.wire()[1].playerId, "spike_a")
	h.eq(t.wire()[1].trainerId, 42)
	h.eq(#t.inbound(), 0)
	t.receive({ v = 2, type = "welcome", players = json.array() })
	t.tick(); h.eq(#t.inbound(), 0)
	t.receive({ v = 2, type = "trade_available", playerId = "spike_b", available = true })
	t.tick(); h.eq(t.inbound()[1], string.char(0, 0, 0))
end

tests["spike filters unrelated peers and targets before feeding the ROM"] = function()
	local t = harness(true); t.ready()
	for _, pair in ipairs({ { "stranger", "spike_a" }, { "spike_b", "stranger" } }) do
		t.receive({ v = 2, type = "trade_link", playerId = pair[1], targetId = pair[2], seq = 1, data = "0102" })
	end
	t.tick(); h.eq(#t.inbound(), 1)
	t.receive({ v = 2, type = "trade_link", playerId = "spike_b", targetId = "spike_a", seq = 1, data = "0102" })
	t.tick(); h.eq(t.inbound()[2], string.char(1, 2))
end

tests["spike preserves ROM bytes and injects outbound latency without blocking"] = function()
	local t = harness(true, 100); t.ready()
	local bytes = string.char(2) .. string.rep("\0\255", 100)
	t.rom(bytes); t.tick()
	local function links()
		local messages = {}
		for _, m in ipairs(t.wire()) do if m.type == "trade_link" then messages[#messages + 1] = m end end
		return messages
	end
	h.eq(#links(), 0)
	t.tick(12)
	h.eq(#links(), 1)
	h.eq(links()[1].data, require("protocol").toHex(bytes))
	h.eq(links()[1].seq, 1)
end

tests["all outgoing trade messages include the required sender and pass the protocol contract"] = function()
	local t = harness(true); t.ready()
	t.rom(string.char(2) .. string.rep("a", 200)); t.tick()
	local seen = {}
	for _, message in ipairs(t.wire()) do
		if message.type:match("^trade_") then
			h.eq(message.playerId, "spike_a")
			h.eq(require("protocol").check(message), nil)
			seen[message.type] = true
		end
	end
	assert(seen.trade_available and seen.trade_link)
end

tests["spike stops on a partner sequence gap without logging private settings"] = function()
	local t = harness(true); t.ready()
	t.receive({ v = 2, type = "trade_link", playerId = "spike_b", targetId = "spike_a", seq = 2, data = "01" })
	h.eq(t.sock.closed, true); h.eq(t.box.connected, false)
	assert(not table.concat(t.logs):find("fixture-key", 1, true))
end

tests["loading another game closes the socket without writing the old mailbox"] = function()
	local t = harness(true); t.ready()
	local writes = 0
	t.box.setLuaConnected = function() writes = writes + 1 end
	t.handlers.start()
	h.eq(writes, 0); h.eq(t.sock.closed, true)
	t.tick(); h.eq(writes, 0)
end

return tests
