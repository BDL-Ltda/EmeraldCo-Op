-- Drive the real entry point, mailbox, pipe and network client. Only the
-- emulator, clock, console and sockets are adapters; no private config is read.
local mailbox, json, h = require("mailbox"), require("json"), require("helpers")
local tests = {}
local BASE = 4096 -- synthetic base, not a game address
local FLAGS, OUT_HEAD, OUT_TAIL, OUT_SLOTS = 5, 6, 7, 8
local IN_HEAD, IN_TAIL = 0x208, 0x209

local function setup()
	local w = { bytes = {}, handlers = {}, sockets = {}, seconds = 0, logs = {}, panel = "" }
	local emu = {}
	function emu.checksum() return "\x01\x02\x03\x04" end
	function emu.read8(_, address) return w.bytes[address] or 0 end
	function emu.write8(_, address, value)
		local offset = address - BASE
		assert(offset == FLAGS or offset == OUT_TAIL or offset == IN_HEAD
			or (offset >= 0x20A and offset < 1034), "write outside Lua-owned mailbox fields")
		w.bytes[address] = value
	end
	function w:resetRom()
		-- Model CoopMailbox_Init completing entirely between two callbacks.
		-- No reset callback is emitted (e.g. an in-ROM BIOS soft reset).
		self.bytes = {}
		for i = 1, 4 do self.bytes[BASE + i - 1] = ("COOP"):byte(i) end
		self.bytes[BASE + 4], self.bytes[BASE + FLAGS] = 1, mailbox.FLAG_ROM_READY
	end
	w:resetRom()
	local function newSocket()
		local s = { handlers = {}, inbox = {}, sent = "", closed = false }
		function s.connect()
			if w.refuse then return nil, "test server offline" end
			w.sockets[#w.sockets + 1] = s
			return 1
		end
		function s.add(_, event, fn) s.handlers[event] = fn end
		function s.send(_, data) s.sent = s.sent .. data; return #data end
		function s.receive()
			local chunk = table.remove(s.inbox, 1)
			return chunk, chunk and nil or "again"
		end
		function s.close() s.closed = true end
		function s.deliver(message)
			s.inbox[#s.inbox + 1] = assert(json.encode(message)) .. "\n"
			s.handlers.received(s)
		end
		function s.messages(kind)
			local result = {}
			for line in s.sent:gmatch("([^\n]+)\n") do
				local message = assert(json.decode(line))
				if message.type == kind then result[#result + 1] = message end
			end
			return result
		end
		return s
	end
	local buffer = {}
	function buffer.setSize() end
	function buffer.clear() w.panel = "" end
	function buffer.moveCursor() end
	function buffer.print(_, text) w.panel = w.panel .. text .. "\n" end
	local config = { SERVER_HOST = "localhost", SERVER_PORT = 8765, PLAYER_ID = "test-player",
		JOIN_KEY = "test-only-key", DEBUG = false }
	local env = setmetatable({
		console = { createBuffer = function() return buffer end,
			log = function(_, line) w.logs[#w.logs + 1] = line end,
			error = function(_, line) w.logs[#w.logs + 1] = line end },
		callbacks = { add = function(_, kind, fn) w.handlers[kind] = fn end },
		emu = emu, socket = { tcp = newSocket, ERRORS = { AGAIN = "again" } },
		os = { time = function() return w.seconds end },
		loadfile = function(path)
			if path:match("config%.lua$") then return function() return config end end
			if path:match("addresses%.lua$") then
				return function() return { romCrc32 = "01020304",
					symbols = { gCoopMailbox = { addr = BASE } } } end
			end
			error("unexpected file")
		end,
		require = function(name)
			if name == "mailbox" then
				return setmetatable({ new = function(mem, base)
					w.box = mailbox.new(mem, base)
					return w.box
				end }, { __index = mailbox })
			end
			return require(name)
		end,
	}, { __index = _G })
	assert(loadfile("client/bridge.lua", "t", env))()
	function w:frame(seconds)
		self.seconds = self.seconds + (seconds or 0)
		self.handlers.frame()
	end
	function w:publish(trainerId, x)
		local payload = assert(mailbox.encodePresence({ mapGroup = 0, mapNum = 9,
			x = x, y = 3, facing = 1, visible = true, trainerId = trainerId, gender = 0 }))
		local head = emu:read8(BASE + OUT_HEAD)
		local slot = BASE + OUT_SLOTS + head * 32
		self.bytes[slot], self.bytes[slot + 1] = mailbox.MSG.PRESENCE, #payload
		for i = 1, #payload do self.bytes[slot + 1 + i] = payload:byte(i) end
		self.bytes[BASE + OUT_HEAD] = (head + 1) % 16
	end
	function w:welcome()
		self.sockets[#self.sockets].deliver({ v = 1, type = "welcome", players = json.array() })
		self:frame()
	end
	function w.isConnected(_)
		return emu:read8(BASE + FLAGS) & mailbox.FLAG_LUA_CONNECTED ~= 0
	end
	return w
end

local function joined()
	local w = setup()
	w:publish(42, 5); w:frame(); w:welcome()
	h.eq(w:isConnected(), true)
	h.eq(#w.sockets[1].messages("presence"), 1)
	return w
end

tests["completed reset while retrying requires fresh ROM state before any new hello"] = function()
	local w = joined()
	w.sockets[1].handlers.error(nil, "test disconnect")
	h.eq(w:isConnected(), false)
	w:resetRom()
	w:frame(); w:frame(6)
	h.eq(#w.sockets, 1)
	h.eq(w:isConnected(), false)
	assert(w.panel:find("waiting for game", 1, true))
	w:publish(99, 12); w:frame(); w:welcome()
	h.eq(#w.sockets, 2)
	h.eq(w.sockets[2].messages("hello")[1].trainerId, 99)
	h.eq(w.sockets[2].messages("presence")[1].x, 12)
end

tests["completed reset while awaiting welcome closes the old socket and cached state"] = function()
	local w = setup()
	w:publish(42, 5); w:frame()
	h.eq(#w.sockets, 1)
	h.eq(w:isConnected(), false)
	w:resetRom()
	w:frame(); w:frame(6)
	h.eq(w.sockets[1].closed, true)
	h.eq(#w.sockets, 1)
	-- Even a late welcome from the invalidated socket cannot reattach the ROM.
	w.sockets[1].deliver({ v = 1, type = "welcome", players = json.array() })
	w:frame()
	h.eq(w:isConnected(), false)
end

tests["completed reset while awaiting ROM handoff forgets the authenticated session"] = function()
	local w = joined()
	-- Keep inbound messages queued as if the ROM were in a menu.
	w.sockets[1].handlers.error(nil, "test disconnect")
	w:frame(6); w:welcome()
	h.eq(#w.sockets, 2)
	h.eq(w:isConnected(), false)
	w:resetRom()
	w:frame(); w:frame(6)
	h.eq(w.sockets[2].closed, true)
	h.eq(#w.sockets, 2)
	h.eq(w:isConnected(), false)
	w:publish(77, 9); w:frame(); w:welcome()
	h.eq(w.sockets[3].messages("hello")[1].trainerId, 77)
	h.eq(w:isConnected(), true)
end

tests["reset followed by a fresh tuple in the same observed frame uses only the new identity"] = function()
	local w = joined()
	w.sockets[1].handlers.error(nil, "test disconnect")
	w:resetRom(); w:publish(99, 18)
	w:frame(); w:frame(6); w:welcome()
	h.eq(w.sockets[2].messages("hello")[1].trainerId, 99)
	h.eq(w.sockets[2].messages("presence")[1].x, 18)
end

tests["reset is detected even when every observed ring index was already zero"] = function()
	local w = joined()
	for i = 1, 15 do w:publish(42, i); w:frame() end
	-- Model the ROM consuming the initial cleanup, then drive the real inbound
	-- writer through a wrap. The unused-slot marker must survive normal traffic.
	w.bytes[BASE + IN_TAIL] = w.bytes[BASE + IN_HEAD]
	for _ = 1, 12 do
		assert(w.box:push(mailbox.MSG.LEAVE, string.char(0)))
		w.bytes[BASE + IN_TAIL] = w.bytes[BASE + IN_HEAD]
	end
	for _, index in ipairs({ OUT_HEAD, OUT_TAIL, IN_HEAD, IN_TAIL }) do
		h.eq(w.bytes[BASE + index] or 0, 0)
	end
	w.sockets[1].handlers.error(nil, "test disconnect")
	w:resetRom(); w:frame(); w:frame(6)
	h.eq(#w.sockets, 1)
	h.eq(w:isConnected(), false)
end

return tests
