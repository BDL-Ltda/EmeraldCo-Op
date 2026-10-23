local h = require("helpers")
local mailbox = require("mailbox")
local bridge = require("mailboxbridge")

local tests = {}

local function presence(x)
	return { mapGroup = 0, mapNum = 9, x = x or 5, y = 3, facing = 1, visible = true,
		gender = 0, trainerId = 42 }
end

local function fixture()
	local outbound, inbound, states, errors = {}, {}, {}, {}
	local box = { connected = false, full = false }
	function box.pop(_)
		if #outbound == 0 then return nil end
		return table.remove(outbound, 1)
	end
	function box:push(kind, payload)
		if self.full then return false, "mailbox inbound ring full" end
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
	h.eq(f.box.connected, true)
	f.pipe.flushInbound()
	h.eq(#f.inbound, 1)
	local first = assert(mailbox.decodePresence(f.inbound[1].payload))
	h.eq(first.slot, 0)
	h.eq(first.trainerId, 7)
	h.eq(first.gender, 1)
	f.pipe:onEvent("message", { type = "presence", playerId = "zoe", mapGroup = 0,
		mapNum = 9, x = 8, y = 3, facing = 4, visible = true })
	f.pipe.flushInbound()
	h.eq(assert(mailbox.decodePresence(f.inbound[2].payload)).slot, 1)
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
	h.eq(assert(mailbox.decodePresence(f.inbound[1].payload)).x, 9)
	f.pipe:onEvent("message", { type = "leave", playerId = "amy" })
	f.box.full = true
	f.pipe.flushInbound()
	f.pipe:onEvent("message", { type = "join", playerId = "ben", trainerId = 8, gender = 0 })
	f.pipe:onEvent("message", { type = "presence", playerId = "ben", mapGroup = 0,
		mapNum = 9, x = 4, y = 3, facing = 1, visible = true })
	f.box.full = false
	f.pipe.flushInbound()
	h.eq(f.inbound[2].type, mailbox.MSG.LEAVE)
	h.eq(f.inbound[2].payload:byte(), 0)
	h.eq(assert(mailbox.decodePresence(f.inbound[3].payload)).slot, 0)
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
	h.eq(#f.inbound, 2)
end

return tests
