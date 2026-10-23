-- Real mailbox codec + pipe + networking + debug model, with byte-addressed
-- ROM memory and an in-process JSON-line relay. Not an emulator acceptance test.
local mailbox, pipeModule = require("mailbox"), require("mailboxbridge")
local net, debugview, json, h = require("net"), require("debugview"), require("json"), require("helpers")
local tests = {}

-- Synthetic base; offsets mirror docs/memory-map.md, never game structs.
local BASE, FLAGS = 4096, 5
local OUT_HEAD, OUT_TAIL, OUT_SLOTS = 6, 7, 8
local IN_HEAD, IN_TAIL, IN_SLOTS = 0x208, 0x209, 0x20A

local function world()
	local w = { now = 0, online = true, peers = {}, connections = {} }
	local function queue(sock, message)
		sock.inbox[#sock.inbox + 1] = assert(json.encode(message)) .. "\n"
	end
	local function broadcast(message, except)
		for _, sock in ipairs(w.connections) do
			if not sock.closed and sock.id and sock ~= except then queue(sock, message) end
		end
	end
	local function connect()
		if not w.online then return nil, "test relay offline" end
		local sock = { inbox = {}, handlers = {}, pending = "" }
		function sock:add(event, fn) self.handlers[event] = fn end
		function sock:send(bytes)
			self.pending = self.pending .. bytes
			while true do
				local line, rest = self.pending:match("^(.-)\n(.*)$")
				if not line then break end
				self.pending = rest
				local m = assert(json.decode(line))
				if m.type == "hello" then
					local players = json.array()
					for _, other in ipairs(w.connections) do
						if other ~= self and not other.closed and other.id then
							players[#players + 1] = { playerId = other.id, trainerId = other.trainerId,
								gender = other.gender, presence = other.presence }
						end
					end
					self.id, self.trainerId, self.gender = m.playerId, m.trainerId, m.gender
					queue(self, { v = 1, type = "welcome", players = players })
					broadcast({ v = 1, type = "join", playerId = self.id,
						trainerId = self.trainerId, gender = self.gender }, self)
				elseif m.type == "presence" then
					self.presence = m
					broadcast(m, self)
				elseif m.type == "ping" then
					queue(self, { v = 1, type = "pong", t = m.t })
				end
			end
			return #bytes
		end
		function sock:receive()
			local chunk = table.remove(self.inbox, 1)
			return chunk, chunk and nil or (self.closed and "disconnected" or "again")
		end
		function sock:close()
			if self.closed then return end
			self.closed = true
			if self.id then broadcast({ v = 1, type = "leave", playerId = self.id, reason = "disconnect" }, self) end
		end
		w.connections[#w.connections + 1] = sock
		return sock
	end
	function w.add(_, id, trainerId, gender)
		local p = { mem = { bytes = {} }, objects = {}, field = true, errors = {} }
		function p.mem:read8(address) return self.bytes[address] or 0 end
		function p.mem:write8(address, value)
			local offset = address - BASE
			assert(offset == FLAGS or offset == OUT_TAIL or offset == IN_HEAD
				or (offset >= IN_SLOTS and offset < 1034), "Lua wrote outside its mailbox fields")
			self.bytes[address] = value
		end
		for i = 1, 4 do p.mem.bytes[BASE + i - 1] = ("COOP"):byte(i) end
		p.mem.bytes[BASE + 4], p.mem.bytes[BASE + FLAGS] = 1, mailbox.FLAG_ROM_READY
		p.box = mailbox.new(p.mem, BASE)
		p.view = debugview.new("localhost", id)
		p.client = assert(net.new({ SERVER_HOST = "localhost", SERVER_PORT = 8765, PLAYER_ID = id,
			JOIN_KEY = "test-only-key" }, {
			connect = connect, again = "again", log = function() end,
			logError = function(line) p.errors[#p.errors + 1] = line end,
			onEvent = function(kind, data, now)
				p.view:onEvent(kind, data, now)
				p.pipe:onEvent(kind, data)
			end,
		}))
		p.pipe = pipeModule.new(p.box, p.client, p.view, function(line) error(line) end)
		function p:publish(x, extra)
			local state = { mapGroup = 0, mapNum = 9, x = x, y = 3, facing = 4,
				visible = true, trainerId = trainerId, gender = gender }
			for key, value in pairs(extra or {}) do state[key] = value end
			local payload = assert(mailbox.encodePresence(state))
			local head = self.mem:read8(BASE + OUT_HEAD)
			assert((head + 1) % 16 ~= self.mem:read8(BASE + OUT_TAIL))
			local slot = BASE + OUT_SLOTS + head * 32
			self.mem.bytes[slot], self.mem.bytes[slot + 1] = mailbox.MSG.PRESENCE, #payload
			for i = 1, #payload do self.mem.bytes[slot + 1 + i] = payload:byte(i) end
			self.mem.bytes[BASE + OUT_HEAD] = (head + 1) % 16
		end
		-- Models only ring consumption/slot state, not the game's renderer.
		function p:romFrame()
			if not self.field then return end
			local connected = self.box:isLuaConnected()
			if not connected then self.objects = {} end
			while self.mem:read8(BASE + IN_TAIL) ~= self.mem:read8(BASE + IN_HEAD) do
				local tail = self.mem:read8(BASE + IN_TAIL)
				local slot, bytes = BASE + IN_SLOTS + tail * 32, {}
				for i = 1, self.mem:read8(slot + 1) do bytes[i] = string.char(self.mem:read8(slot + 1 + i)) end
				local payload = table.concat(bytes)
				if connected then
					if self.mem:read8(slot) == mailbox.MSG.PRESENCE then
						local state = assert(mailbox.decodePresence(payload))
						self.objects[state.slot] = state
					else self.objects[payload:byte()] = nil end
				end
				self.mem.bytes[BASE + IN_TAIL] = (tail + 1) % 16
			end
		end
		w.peers[#w.peers + 1] = p
		return p
	end
	function w:step(ms)
		self.now = self.now + (ms or 50)
		for _, p in ipairs(self.peers) do p.pipe.drainOutbound(); p.client:update(self.now) end
		for _, sock in ipairs(self.connections) do
			if not sock.closed and #sock.inbox > 0 then sock.handlers.received() end
		end
		for _, p in ipairs(self.peers) do p.pipe.flushInbound(); p:romFrame() end
	end
	function w:stopServer()
		self.online = false
		for _, sock in ipairs(self.connections) do
			if not sock.closed then sock:close(); sock.handlers.received() end
		end
	end
	return w
end

local function joined()
	local w = world()
	local a, b = w:add("alice", 42, 0), w:add("bob", 99, 1)
	a:publish(5); b:publish(7)
	w:step(); w:step(); w:step()
	return w, a, b
end

tests["no socket opens before the ROM publishes a session"] = function()
	local w = world()
	w:add("alice", 42, 0)
	w:step(); w:step(10000)
	h.eq(#w.connections, 0)
end

tests["ROM bytes traverse both clients and update the remote mailbox and panel"] = function()
	local w, a, b = joined()
	h.eq(b.objects[0].x, 5)
	h.eq(b.objects[0].trainerId, 42)
	h.eq(a.objects[0].gender, 1)
	a:publish(12, { y = -2, facing = 2 })
	w:step()
	h.eq(b.objects[0].x, 12)
	h.eq(b.objects[0].y, -2)
	h.eq(b.objects[0].facing, 2)
	assert(b.view:update(w.now, true):find("alice  0:9  12,-2  NORTH  visible  same map", 1, true))
	a:publish(12, { visible = false })
	w:step()
	h.eq(b.objects[0].visible, true) -- v1 session semantics, not the local field lock
	assert(a.view:update(w.now, true):find("hidden", 1, true))
end

tests["server loss clears flags and restart replays idle peers without new ROM messages"] = function()
	local w, a, b = joined()
	w:stopServer()
	h.eq(a.box:isLuaConnected(), false)
	h.eq(b.box:isLuaConnected(), false)
	w:step()
	h.eq(next(a.objects), nil)
	h.eq(next(b.objects), nil)
	w.online = true
	w:step(net.RETRY_INTERVAL_MS); w:step(); w:step()
	h.eq(a.box:isLuaConnected(), true)
	h.eq(b.box:isLuaConnected(), true)
	h.eq(a.objects[0].x, 7)
	h.eq(b.objects[0].x, 5)
	assert(b.view:update(w.now, true):find("Remote players: 1", 1, true))
end

tests["full inbound ring during a menu retains the latest movement and leave"] = function()
	local w, a, b = joined()
	b.field = false
	for x = 10, 30 do a:publish(x); w:step(100) end
	h.eq(b.box:isInboundEmpty(), false)
	b.field = true
	w:step(); w:step()
	h.eq(b.objects[0].x, 30)
	a.client:close("test peer leaves")
	b.field = false
	-- Deliver the peer's leave without running Alice's reconnect loop.
	for _, sock in ipairs(w.connections) do
		if not sock.closed and #sock.inbox > 0 then sock.handlers.received() end
	end
	b.pipe.flushInbound()
	b.field = true
	b:romFrame()
	h.eq(next(b.objects), nil)
end

tests["reconnect during a menu never replays stale peers from the old ring"] = function()
	local w, a, b = joined()
	b.field = false
	a:publish(20); w:step()
	h.eq(b.box:isInboundEmpty(), false)
	w:stopServer()
	-- Alice does not rejoin the new server. Bob's old ring still contains Alice.
	w.peers = { b }
	w.online = true
	w:step(net.RETRY_INTERVAL_MS); w:step()
	h.eq(b.box:isLuaConnected(), false)
	b.field = true
	w:step(); w:step()
	h.eq(b.box:isLuaConnected(), true)
	h.eq(next(b.objects), nil)
	assert(b.view:update(w.now, true):find("Remote players: 0", 1, true))
end

return tests
