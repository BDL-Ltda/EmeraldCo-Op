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
	local outbound, inbound, states, errors, messages = {}, {}, {}, {}, {}
	-- room: slots left this frame, or nil for unlimited.
	local box = { connected = false, full = false, empty = true }
	function box:isInboundEmpty() return self.empty end
	function box.pop(_)
		if #outbound == 0 then return nil end
		return table.remove(outbound, 1)
	end
	function box:push(kind, payload)
		if self.full or self.room == 0 then return false, "mailbox inbound ring full" end
		assert(self.connected, "new messages require lua_connected")
		if self.room then self.room = self.room - 1 end
		inbound[#inbound + 1] = { type = kind, payload = payload }
		return true
	end
	function box:setLuaConnected(value) self.connected = value end
	local client = { setPlayerState = function(_, state) states[#states + 1] = state end }
	local view = { setPlayerState = function(_, state) states[#states + 1] = state end }
	local pipe = bridge.new(box, client, view, function(err) errors[#errors + 1] = err end,
		function(msgType, data) messages[#messages + 1] = { type = msgType, data = data } end)
	return { box = box, outbound = outbound, inbound = inbound, states = states,
		errors = errors, messages = messages, pipe = pipe }
end

tests["single-slot attendant controls reach the dispatcher unchanged"] = function()
	local f = fixture()
	local bytes = string.pack("<BI2", 2, 7) .. "alice"
	f.outbound[1] = { type = mailbox.MSG.TRADE_COMMAND, payload = bytes }
	f.pipe.drainOutbound()
	h.same(f.messages, { { type = mailbox.MSG.TRADE_COMMAND, data = bytes } })
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

local fragments = require("fragments")
local function bytes(length, seed)
	local out = {}
	for i = 0, length - 1 do out[#out + 1] = string.char((i * seed + 3) & 0xFF) end
	return table.concat(out)
end

tests["outbound multi-slot message is reassembled while presence keeps flowing"] = function()
	local f = fixture()
	local list = assert(fragments.split(mailbox.MSG.DEBUG_ECHO, bytes(600, 7)))
	for i, payload in ipairs(list) do
		f.outbound[#f.outbound + 1] = { type = mailbox.MSG.FRAGMENT, payload = payload }
		if i % 5 == 0 then
			f.outbound[#f.outbound + 1] = { type = mailbox.MSG.PRESENCE,
				payload = assert(mailbox.encodePresence(presence(i))) }
		end
	end
	for _ = 1, 3 do f.pipe.drainOutbound() end
	h.eq(#f.outbound, 0)
	h.eq(#f.errors, 0)
	h.eq(#f.messages, 1)
	h.eq(f.messages[1].type, mailbox.MSG.DEBUG_ECHO)
	h.eq(f.messages[1].data, bytes(600, 7))
	h.eq(#f.states, 8) -- 4 presences, each to the network and the panel
end

tests["incomplete outbound message is dropped and logged, the next one delivered"] = function()
	local f = fixture()
	local first = assert(fragments.split(mailbox.MSG.DEBUG_ECHO, bytes(600, 31)))
	for i = 1, 5 do f.outbound[i] = { type = mailbox.MSG.FRAGMENT, payload = first[i] } end
	f.pipe.drainOutbound()
	h.eq(#f.messages, 0)
	for _, payload in ipairs(assert(fragments.split(mailbox.MSG.DEBUG_ECHO, bytes(100, 7)))) do
		f.outbound[#f.outbound + 1] = { type = mailbox.MSG.FRAGMENT, payload = payload }
	end
	f.pipe.drainOutbound()
	h.eq(#f.messages, 1)
	h.eq(f.messages[1].data, bytes(100, 7))
	h.eq(#f.errors, 1)
	assert(f.errors[1]:find("incomplete message dropped", 1, true), f.errors[1])
end

local function inboundFragments(f, from)
	local list = {}
	for i = from or 1, #f.inbound do
		if f.inbound[i].type == mailbox.MSG.FRAGMENT then list[#list + 1] = f.inbound[i].payload end
	end
	return list
end

tests["inbound multi-slot message streams after presence over several frames"] = function()
	local f = fixture()
	h.eq((f.pipe.sendMessage(mailbox.MSG.DEBUG_ECHO, "x")), false) -- no session yet
	f.pipe:onEvent("message", { type = "welcome", players = {
		{ playerId = "amy", trainerId = 7, gender = 1, presence = presence(6) },
	} })
	assert(f.pipe.sendMessage(mailbox.MSG.DEBUG_ECHO, bytes(600, 7)))
	local frames = 0
	repeat
		frames = frames + 1
		f.box.room = 15
		f.pipe:onEvent("message", { type = "presence", playerId = "amy", mapGroup = 0,
			mapNum = 9, x = frames, y = 3, facing = 1, visible = true })
		f.pipe.flushInbound()
	until #inboundFragments(f) == 24 or frames == 10
	h.eq(#inboundFragments(f), 24)
	assert(frames > 1)
	-- Every frame's presence went out before that frame's fragments.
	h.eq(f.inbound[5].type, mailbox.MSG.PRESENCE)
	h.eq(f.inbound[16].type, mailbox.MSG.PRESENCE)
	h.eq(assert(mailbox.decodePresence(f.inbound[16].payload)).x, 2)
	local reassembler = fragments.newReassembler()
	local got
	for _, payload in ipairs(inboundFragments(f)) do
		local msgType, data = reassembler:feed(payload)
		if msgType then got = data end
	end
	h.eq(got, bytes(600, 7))
	h.eq(#f.errors, 0)
end

tests["disconnect drops the queued and partly sent inbound messages"] = function()
	local f = fixture()
	f.pipe:onEvent("message", { type = "welcome", players = {} })
	assert(f.pipe.sendMessage(mailbox.MSG.DEBUG_ECHO, bytes(600, 7)))
	assert(f.pipe.sendMessage(mailbox.MSG.DEBUG_ECHO, bytes(10, 7)))
	f.box.room = 10
	f.pipe.flushInbound()
	h.eq(#inboundFragments(f), 6) -- after the four LEAVEs
	f.pipe:onEvent("status", "Retrying")
	h.eq((f.pipe.sendMessage(mailbox.MSG.DEBUG_ECHO, "x")), false)
	f.pipe:onEvent("message", { type = "welcome", players = {} })
	local before = #f.inbound
	f.box.room = nil
	f.pipe.flushInbound()
	h.eq(#inboundFragments(f, before + 1), 0)
	-- A new message starts at fragment 0, so the ROM drops the partial one.
	assert(f.pipe.sendMessage(mailbox.MSG.DEBUG_ECHO, bytes(30, 7)))
	f.pipe.flushInbound()
	local list = inboundFragments(f, before + 1)
	h.eq(#list, 2)
	h.eq(list[1]:byte(2), 0)
end

tests["outbound partial message from before a reset is dropped"] = function()
	local f = fixture()
	local list = assert(fragments.split(mailbox.MSG.DEBUG_ECHO, bytes(100, 7)))
	f.outbound[1] = { type = mailbox.MSG.FRAGMENT, payload = list[1] }
	f.outbound[2] = { type = mailbox.MSG.FRAGMENT, payload = list[2] }
	f.pipe.drainOutbound()
	f.pipe.reset()
	f.outbound[1] = { type = mailbox.MSG.FRAGMENT, payload = list[3] }
	f.outbound[2] = { type = mailbox.MSG.FRAGMENT, payload = list[4] }
	f.pipe.drainOutbound()
	h.eq(#f.messages, 0)
	h.eq(#f.errors, 2)
end

return tests
