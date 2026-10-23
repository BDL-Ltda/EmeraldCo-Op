local h = require("helpers")
local mailbox = require("mailbox")
local bridge = require("mailboxbridge")

local tests = {}

tests["client exports only the mailbox and removes the legacy reader"] = function()
	local addresses = dofile("client/addresses.lua")
	local count = 0
	for name in pairs(addresses.symbols) do h.eq(name, "gCoopMailbox"); count = count + 1 end
	h.eq(count, 1)
	local legacy = io.open("client/memory.lua", "rb")
	if legacy then legacy:close(); error("legacy game-struct reader must remain removed") end
end

local function presence(x)
	return { mapGroup = 0, mapNum = 9, x = x or 5, y = 3, facing = 1, visible = true,
		gender = 0, trainerId = 42 }
end

local function fixture()
	local outbound, inbound, states, errors = {}, {}, {}, {}
	local box = { connected = false, full = false, empty = true }
	function box:isInboundEmpty() return self.empty end
	function box.pop(_)
		if #outbound == 0 then return nil end
		return table.remove(outbound, 1)
	end
	function box:push(kind, payload)
		if self.full then return false, "mailbox inbound ring full" end
		assert(self.connected, "new messages require lua_connected")
		inbound[#inbound + 1] = { type = kind, payload = payload }
		return true
	end
	function box:setLuaConnected(value) self.connected = value end
	local client = { setPlayerState = function(_, state) states[#states + 1] = state end }
	local view = { setPlayerState = function(_, state) states[#states + 1] = state end }
	local pipe = bridge.new(box, client, view, function(err) errors[#errors + 1] = err end)
	return { box = box, outbound = outbound, inbound = inbound, states = states,
		errors = errors, pipe = pipe }
end

tests["outbound mailbox presence reaches network and panel without struct reads"] = function()
	local f = fixture()
	f.outbound[1] = { type = mailbox.MSG.PRESENCE, payload = assert(mailbox.encodePresence(presence())) }
	f.outbound[2] = { type = mailbox.MSG.PRESENCE, payload = "bad" }
	f.pipe.drainOutbound()
	h.eq(#f.states, 2)
	h.eq(f.states[1].trainerId, 42)
	h.eq(#f.errors, 1)
	h.eq(#f.outbound, 0)
end

tests["welcome and presence allocate slots and encode ROM identity"] = function()
	local f = fixture()
	f.pipe:onEvent("message", { type = "welcome", players = {
		{ playerId = "amy", trainerId = 7, gender = 1, presence = presence(6) },
		{ playerId = "zoe", trainerId = 8, gender = 0 },
	} })
	h.eq(f.box.connected, false)
	f.pipe.flushInbound()
	h.eq(f.box.connected, true)
	h.eq(#f.inbound, 5)
	for slot = 0, 3 do
		h.eq(f.inbound[slot + 1].type, mailbox.MSG.LEAVE)
		h.eq(f.inbound[slot + 1].payload:byte(), slot)
	end
	local first = assert(mailbox.decodePresence(f.inbound[5].payload))
	h.eq(first.slot, 0)
	h.eq(first.trainerId, 7)
	h.eq(first.gender, 1)
	f.pipe:onEvent("message", { type = "presence", playerId = "zoe", mapGroup = 0,
		mapNum = 9, x = 8, y = 3, facing = 4, visible = true })
	f.pipe.flushInbound()
	h.eq(assert(mailbox.decodePresence(f.inbound[6].payload)).slot, 1)
end

tests["full ring keeps latest state and retries leave before reusing slot"] = function()
	local f = fixture()
	f.pipe:onEvent("message", { type = "welcome", players = {
		{ playerId = "amy", trainerId = 7, gender = 1, presence = presence(1) },
	} })
	f.box.full = true
	f.pipe.flushInbound()
	f.pipe:onEvent("message", { type = "presence", playerId = "amy", mapGroup = 0,
		mapNum = 9, x = 9, y = 3, facing = 1, visible = true })
	f.box.full = false
	f.pipe.flushInbound()
	h.eq(assert(mailbox.decodePresence(f.inbound[5].payload)).x, 9)
	f.pipe:onEvent("message", { type = "leave", playerId = "amy" })
	f.box.full = true
	f.pipe.flushInbound()
	f.pipe:onEvent("message", { type = "join", playerId = "ben", trainerId = 8, gender = 0 })
	f.pipe:onEvent("message", { type = "presence", playerId = "ben", mapGroup = 0,
		mapNum = 9, x = 4, y = 3, facing = 1, visible = true })
	f.box.full = false
	f.pipe.flushInbound()
	h.eq(f.inbound[6].type, mailbox.MSG.LEAVE)
	h.eq(f.inbound[6].payload:byte(), 0)
	h.eq(assert(mailbox.decodePresence(f.inbound[7].payload)).slot, 0)
end

tests["disconnect clears the ROM flag and welcome replays all peers"] = function()
	local f = fixture()
	local welcome = { type = "welcome", players = {
		{ playerId = "amy", trainerId = 7, gender = 1, presence = presence(6) },
	} }
	f.pipe:onEvent("message", welcome)
	f.pipe.flushInbound()
	f.pipe:onEvent("status", "Retrying")
	h.eq(f.box.connected, false)
	f.pipe:onEvent("message", welcome)
	f.pipe.flushInbound()
	h.eq(f.box.connected, true)
	h.eq(#f.inbound, 10)
end

tests["reconnect waits for ROM to discard a full old-session queue"] = function()
	local f = fixture()
	f.pipe:onEvent("message", { type = "welcome", players = {} })
	f.pipe.flushInbound()
	f.pipe:onEvent("status", "Retrying")
	f.box.empty = false -- ROM is in a menu and has not observed the cleared flag
	f.pipe:onEvent("message", { type = "welcome", players = {
		{ playerId = "amy", trainerId = 7, gender = 1, presence = presence(6) },
	} })
	f.pipe.flushInbound()
	h.eq(f.box.connected, false)
	h.eq(f.pipe.isConnected(), false)
	h.eq(#f.inbound, 4)
	f.pipe:onEvent("message", { type = "presence", playerId = "amy", mapGroup = 0,
		mapNum = 9, x = 12, y = 3, facing = 2, visible = true })
	f.box.empty = true -- overworld resumed and ROM discarded the stale messages
	f.pipe.flushInbound()
	h.eq(f.box.connected, true)
	h.eq(#f.inbound, 9)
	h.eq(assert(mailbox.decodePresence(f.inbound[9].payload)).x, 12)
end

tests["outbound work is bounded and accepts compatible payload extensions"] = function()
	local f = fixture()
	for i = 1, 20 do
		f.outbound[i] = { type = mailbox.MSG.PRESENCE,
			payload = assert(mailbox.encodePresence(presence(i))) .. "extension" }
	end
	f.pipe.drainOutbound()
	h.eq(#f.outbound, 5)
	h.eq(#f.errors, 0)
	h.eq(f.states[#f.states].x, 15)
	f.pipe.drainOutbound()
	h.eq(#f.outbound, 0)
	h.eq(f.states[#f.states].x, 20)
end

tests["mailbox hidden remains local while wire v1 keeps session visibility"] = function()
	local f = fixture()
	local state = presence()
	state.visible = false
	f.outbound[1] = { type = mailbox.MSG.PRESENCE, payload = assert(mailbox.encodePresence(state)) }
	f.pipe.drainOutbound()
	h.eq(f.states[1].visible, true) -- network's running-session contract
	h.eq(f.states[2].visible, false) -- Me row's controllable-overworld contract
end

tests["all four slots remain stable and replacement cannot inherit old identity"] = function()
	local f = fixture()
	local players = {}
	for i = 1, 4 do
		players[i] = { playerId = "p" .. i, trainerId = i, gender = 0, presence = presence(i) }
	end
	f.pipe:onEvent("message", { type = "welcome", players = players })
	f.pipe.flushInbound()
	for i = 1, 4 do h.eq(assert(mailbox.decodePresence(f.inbound[4 + i].payload)).slot, i - 1) end
	f.pipe:onEvent("message", { type = "leave", playerId = "p2" })
	f.pipe:onEvent("message", { type = "join", playerId = "p2", trainerId = 99, gender = 1 })
	f.pipe.flushInbound()
	h.eq(#f.inbound, 9) -- leave only: no inherited position for the replacement
	f.pipe:onEvent("message", { type = "presence", playerId = "p2", mapGroup = 1,
		mapNum = 4, x = -3, y = 8, facing = 4, visible = false })
	f.pipe.flushInbound()
	local p = assert(mailbox.decodePresence(f.inbound[10].payload))
	h.eq(p.slot, 1)
	h.eq(p.trainerId, 99)
	h.eq(p.gender, 1)
	h.eq(p.visible, false)
	h.eq(p.x, -3)
end

tests["reset forgets pending work without writing an invalid mailbox"] = function()
	local f = fixture()
	f.pipe:onEvent("message", { type = "welcome", players = {} })
	f.pipe.flushInbound()
	f.box.setLuaConnected = function() error("must not touch reset memory") end
	f.pipe.reset()
	f.pipe.disconnect()
	f.pipe.flushInbound()
	h.eq(f.pipe.isConnected(), false)
	h.eq(#f.inbound, 4)
end

return tests
