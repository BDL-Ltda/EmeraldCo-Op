-- Exercise the real entry point with injected mGBA adapters.
local h = require("helpers")
local mailbox = require("mailbox")
local tests = {}

local function bridge(validRom)
	local handlers, lines, logs, outbound, states, inbound, wire = {}, {}, {}, {}, {}, {}, {}
	local buffer = {}
	function buffer.clear() lines[#lines + 1] = "" end
	function buffer.setSize(_, cols, rows) assert(cols >= 80 and rows >= 4) end
	function buffer.moveCursor(_, x, y) h.eq(x, 0); buffer.row = y end
	function buffer.print(_, text)
		assert(not text:find("\n"), "native buffer must receive explicitly positioned rows")
		lines[#lines] = lines[#lines] .. text .. "\n"
	end
	local config = { SERVER_HOST = "localhost", SERVER_PORT = 8765, PLAYER_ID = "me",
		JOIN_KEY = "test-only-key", DEBUG = false }
	local box = { connected = true, valid = true, checks = 0, writes = 0 }
	function box:check()
		self.checks = self.checks + 1
		return self.valid, self.valid and "mailbox ready" or "mailbox reset"
	end
	function box.isInboundEmpty() return true end
	function box.watchReset() return true end
	function box.wasReset() return false end
	function box:isLuaConnected() return self.connected end
	function box:setLuaConnected(value)
		assert(self.valid, "must not write an invalid mailbox")
		self.writes = self.writes + 1
		self.connected = value
	end
	function box.pop(_)
		if #outbound == 0 then return nil end
		return table.remove(outbound, 1)
	end
	function box.push(_, kind, payload)
		inbound[#inbound + 1] = { type = kind, payload = payload }
		return true
	end
	local client = {}
	function client.setPlayerState(_, state) states[#states + 1] = state end
	function client.update(_) client.updates = (client.updates or 0) + 1 end
	function client.sendTrade(_, message) wire[#wire + 1] = message; return true end
	function client.close(_)
		client.closes = (client.closes or 0) + 1
		if client.adapter then client.adapter.onEvent("status", "Waiting for game", 0) end
	end
	local env = setmetatable({
		console = {
			createBuffer = function(_, name) h.eq(name, "Emerald Co-Op"); return buffer end,
			log = function(_, text) logs[#logs + 1] = text end,
			error = function(_, text) logs[#logs + 1] = text end,
		},
		callbacks = { add = function(_, kind, fn) handlers[kind] = fn end },
		emu = { checksum = function() return "fixture" end },
		socket = { ERRORS = { AGAIN = "again" } },
		loadfile = function(path)
			if path:match("config%.lua$") then return function() return config end end
			if path:match("addresses%.lua$") then
				return function() return { symbols = { gCoopMailbox = { addr = 123 } } } end
			end
			error("unexpected file")
		end,
		require = function(name)
			if name == "romcheck" then
				return { verify = function() return box.romValid ~= false and validRom, "ROM fixture" end }
			end
			if name == "mailbox" then
				return setmetatable({ new = function() return box end }, { __index = mailbox })
			end
			if name == "net" then return { new = function(_, adapter) client.adapter = adapter; return client end } end
			return require(name)
		end,
	}, { __index = _G })
	assert(loadfile("client/bridge.lua", "t", env))()
	return { handlers = handlers, lines = lines, logs = logs, box = box,
		outbound = outbound, client = client, states = states, inbound = inbound, wire = wire }
end

tests["the bridge reads the mailbox every frame and updates its panel"] = function()
	local b = bridge(true)
	h.eq(b.box.connected, false)
	h.eq(b.handlers.keysRead, nil)
	b.outbound[1] = { type = mailbox.MSG.PRESENCE, payload = assert(mailbox.encodePresence({
		mapGroup = 0, mapNum = 9, x = 5, y = 3, facing = 1, visible = true,
		gender = 0, trainerId = 42,
	})) }
	b.handlers.frame()
	h.eq(b.states[1].trainerId, 42)
	assert(b.lines[#b.lines]:find("Me:    0:9  5,3  SOUTH  visible", 1, true))
	b.client.adapter.onEvent("message", { type = "welcome", players = {} }, 0)
	b.handlers.frame()
	h.eq(b.box.connected, true)
	b.client.adapter.onEvent("status", "Retrying", 0)
	h.eq(b.box.connected, false)
	b.handlers.shutdown()
	assert(b.lines[#b.lines]:find("waiting for game", 1, true))
end

tests["stop prevents frame callbacks from restarting until a verified start"] = function()
	local b = bridge(true)
	b.handlers.frame()
	b.handlers.stop()
	local updates, checks = b.client.updates, b.box.checks
	b.handlers.frame()
	h.eq(b.client.updates, updates)
	h.eq(b.box.checks, checks)
	b.handlers.start()
	b.handlers.frame()
	h.eq(b.client.updates, updates + 1)
end

tests["invalid mailbox closes the socket without writing until reinitialized"] = function()
	local b = bridge(true)
	b.client.adapter.onEvent("message", { type = "welcome", players = {} }, 0)
	b.handlers.frame()
	h.eq(b.box.connected, true)
	local writes, closes = b.box.writes, b.client.closes
	b.box.valid = false
	b.handlers.frame()
	h.eq(b.box.writes, writes)
	h.eq(b.client.closes, closes + 1)
	b.box.valid, b.box.connected = true, false
	b.handlers.frame()
	h.eq(b.box.connected, false)
end

tests["a soft reset with an already valid header closes the old session"] = function()
	local b = bridge(true)
	b.client.adapter.onEvent("message", { type = "welcome", players = {} }, 0)
	b.handlers.frame()
	local closes = b.client.closes
	b.box.connected = false
	b.handlers.frame()
	h.eq(b.client.closes, closes + 1)
	h.eq(b.box.connected, false)
end

tests["switching to an unverified ROM never writes the old mailbox"] = function()
	local b = bridge(true)
	b.client.adapter.onEvent("message", { type = "welcome", players = {} }, 0)
	b.handlers.frame()
	local writes, updates = b.box.writes, b.client.updates
	b.box.romValid = false
	b.handlers.start()
	b.handlers.frame()
	h.eq(b.box.writes, writes)
	h.eq(b.client.updates, updates)
end

tests["a mismatched ROM never opens the mailbox"] = function()
	local b = bridge(false)
	h.eq(b.box.connected, true)
	b.handlers.frame()
	assert(b.lines[#b.lines]:find("ROM not verified", 1, true))
end

tests["attendant commands and targeted replies cross the real bridge, including reset"] = function()
	local b = bridge(true)
	local trade = require("trade")
	local function welcome()
		b.client.adapter.onEvent("message", { type = "welcome", players = {
			{ playerId = "bob", trainerId = 7, gender = 1 },
		} }, 0)
		b.handlers.frame()
	end
	local function command(kind, token, id)
		b.outbound[#b.outbound + 1] = { type = mailbox.MSG.TRADE_COMMAND,
			payload = string.pack("<BI2", kind, token) .. (id or "") }
		b.handlers.frame()
	end
	welcome()
	command(trade.COMMAND.OPEN, 1)
	h.eq(b.wire[#b.wire].available, true)
	b.client.adapter.onEvent("message", { type = "trade_available", playerId = "bob", available = true }, 0)
	command(trade.COMMAND.INVITE, 1, "bob")
	h.eq(b.wire[#b.wire].type, "trade_invite")
	h.eq(b.wire[#b.wire].targetId, "bob")
	b.client.adapter.onEvent("message", { type = "trade_accept", playerId = "bob", targetId = "me" }, 0)
	b.handlers.frame()
	local assembler, latest = require("fragments").newReassembler(), nil
	for _, message in ipairs(b.inbound) do
		if message.type == mailbox.MSG.FRAGMENT then
			local kind, bytes = assembler:feed(message.payload)
			if kind == mailbox.MSG.TRADE_STATE then latest = bytes end
		end
	end
	assert(latest)
	h.eq(latest:byte(3), trade.STATE.READY)
	b.box.connected = false
	b.handlers.frame()
	welcome()
	command(trade.COMMAND.OPEN, 1) -- ROM token restarts at one after soft reset.
	h.eq(b.wire[#b.wire].available, true)
end

return tests
