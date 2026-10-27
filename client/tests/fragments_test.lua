-- Tests for client/lib/fragments.lua (mailbox layout v2 multi-slot messages).
local h = require("helpers")
local mailbox = require("mailbox")
local fragments = require("fragments")

local tests = {}
local ECHO = mailbox.MSG.DEBUG_ECHO

local function pattern(length, seed)
	local bytes = {}
	for i = 0, length - 1 do bytes[#bytes + 1] = string.char((i * (seed or 7) + i // 256 + 3) & 0xFF) end
	return table.concat(bytes)
end

-- Feeds every fragment; returns the delivered messages and the drop reasons.
local function feedAll(reassembler, list)
	local got, drops = {}, {}
	for _, payload in ipairs(list) do
		local msgType, data, dropped = reassembler:feed(payload)
		if dropped then drops[#drops + 1] = dropped end
		if msgType then got[#got + 1] = { type = msgType, data = data } end
	end
	return got, drops
end

tests["constants match include/coop/mailbox.h and include/constants/coop.h"] = function()
	h.eq(fragments.HEADER_SIZE, 4)
	h.eq(fragments.DATA_SIZE, 26)
	h.eq(fragments.HEADER_SIZE + fragments.DATA_SIZE, 30)
	h.eq(fragments.MAX_LENGTH, 1024)
	h.eq(mailbox.MSG.FRAGMENT, 3)
	h.eq(mailbox.MSG.DEBUG_ECHO, 4)
	h.eq(mailbox.LAYOUT_VERSION, 2)
end

tests["split writes the documented fragment header"] = function()
	h.eq(assert(fragments.split(ECHO, "AB"))[1], "\4\0\2\0AB")
	local list = assert(fragments.split(ECHO, pattern(600)))
	h.eq(#list, 24)
	for index, payload in ipairs(list) do
		local msgType, fragmentIndex, total = string.unpack("<BBI2", payload)
		h.eq(msgType, ECHO)
		h.eq(fragmentIndex, index - 1)
		h.eq(total, 600)
		h.eq(#payload, index < 24 and 30 or 4 + 600 - 23 * 26)
	end
	-- 600 = 0x258: little-endian total length.
	h.eq(list[1]:sub(3, 4), "\x58\x02")
end

tests["split covers the size boundaries"] = function()
	for _, case in ipairs({ { 1, 1 }, { 26, 1 }, { 27, 2 }, { 52, 2 }, { 53, 3 }, { 1024, 40 } }) do
		local list = assert(fragments.split(ECHO, pattern(case[1])))
		h.eq(#list, case[2])
		local got = feedAll(fragments.newReassembler(), list)
		h.eq(#got, 1)
		h.eq(got[1].data, pattern(case[1]))
	end
end

tests["split rejects bad types and lengths"] = function()
	for _, msgType in ipairs({ 0, mailbox.MSG.FRAGMENT, 256, -1, 1.5 }) do
		h.rejected(fragments.split(msgType, "x"))
	end
	h.rejected(fragments.split("4", "x"))
	h.rejected(fragments.split(ECHO, ""))
	h.rejected(fragments.split(ECHO, pattern(1025)))
	h.rejected(fragments.split(ECHO, 42))
end

tests["reassembler round-trips every length up to 100 and the largest message"] = function()
	local reassembler = fragments.newReassembler()
	for length = 1, 100 do
		local got, drops = feedAll(reassembler, assert(fragments.split(ECHO, pattern(length, length))))
		h.eq(#drops, 0)
		h.eq(#got, 1)
		h.eq(got[1].type, ECHO)
		h.eq(got[1].data, pattern(length, length))
	end
	local got = feedAll(reassembler, assert(fragments.split(1, pattern(1024, 255))))
	h.eq(got[1].type, 1)
	h.eq(got[1].data, pattern(1024, 255))
end

tests["truncated message is dropped and does not block the next one"] = function()
	local reassembler = fragments.newReassembler()
	local truncated = assert(fragments.split(ECHO, pattern(600, 31)))
	local list = {}
	for i = 1, 5 do list[i] = truncated[i] end
	for _, payload in ipairs(assert(fragments.split(ECHO, pattern(600)))) do list[#list + 1] = payload end
	local got, drops = feedAll(reassembler, list)
	h.eq(#got, 1)
	h.eq(got[1].data, pattern(600))
	h.eq(#drops, 1)
	assert(drops[1]:find("new message started", 1, true), drops[1])
end

tests["out-of-sequence and malformed fragments drop the message"] = function()
	local list = assert(fragments.split(ECHO, pattern(100)))
	local other = assert(fragments.split(ECHO, pattern(101)))
	local wrongType = assert(fragments.split(1, pattern(100)))
	local cases = {
		{ list[1], list[2], list[4] }, -- gap
		{ list[1], list[3] }, -- gap
		{ list[1], list[1]:sub(1, 20) }, -- a short first fragment
		{ list[1], other[2], list[3], list[4] }, -- another total length
		{ list[1], wrongType[2], list[3], list[4] }, -- another type
		{ list[2], list[3], list[4] }, -- no first fragment
		{ "\4\0\100\0" }, -- header only
		{ "\4\0" }, -- shorter than the header
		{ "\0\0\1\0x" }, -- type NONE
		{ "\3\0\1\0x" }, -- type FRAGMENT
		{ "\4\0\0\0x" }, -- total length 0
		{ "\4\0\1\4" .. pattern(26) }, -- total length 1025
		{ "\4\0\100\0" .. pattern(20) }, -- first fragment not full
	}
	for number, case in ipairs(cases) do
		local reassembler = fragments.newReassembler()
		local got, drops = feedAll(reassembler, case)
		assert(#got == 0, "case " .. number .. " delivered a message")
		assert(#drops >= 1, "case " .. number .. " reported no drop")
		-- The next complete message still gets through.
		got = feedAll(reassembler, list)
		h.eq(#got, 1)
		h.eq(got[1].data, pattern(100))
	end
end

tests["reset drops the message in progress"] = function()
	local reassembler = fragments.newReassembler()
	local list = assert(fragments.split(ECHO, pattern(100)))
	h.eq(reassembler:reset(), false)
	feedAll(reassembler, { list[1], list[2] })
	h.eq(reassembler:reset(), true)
	local got, drops = feedAll(reassembler, { list[3], list[4] })
	h.eq(#got, 0)
	h.eq(#drops, 2)
end

tests["sender streams queued messages in order and retries a refused fragment"] = function()
	local sender = fragments.newSender()
	h.eq(sender:isIdle(), true)
	assert(sender:send(ECHO, pattern(600)))
	assert(sender:send(1, "hello"))
	h.eq(sender:isIdle(), false)
	local pushed, room = {}, 10
	local function push(payload)
		if room == 0 then return false, "mailbox inbound ring full" end
		room = room - 1
		pushed[#pushed + 1] = payload
		return true
	end
	local count, err = sender:pump(push)
	h.eq(count, 10)
	h.eq(err, "mailbox inbound ring full")
	room = 100
	h.eq((sender:pump(push)), 15)
	h.eq(sender:isIdle(), true)
	local got, drops = feedAll(fragments.newReassembler(), pushed)
	h.eq(#drops, 0)
	h.eq(#got, 2)
	h.eq(got[1].data, pattern(600))
	h.eq(got[2].data, "hello")
	h.eq(got[2].type, 1)
	h.eq((sender:pump(push)), 0)
end

tests["sender rejects bad messages, bounds its queue and clears"] = function()
	local sender = fragments.newSender()
	local okSend, err = sender:send(mailbox.MSG.FRAGMENT, "x")
	h.eq(okSend, false)
	assert(err)
	h.eq((sender:send(ECHO, "")), false)
	for _ = 1, fragments.MAX_QUEUED do assert(sender:send(ECHO, "x")) end
	h.eq((sender:send(ECHO, "x")), false)
	local pushed = {}
	sender:pump(function(payload)
		pushed[#pushed + 1] = payload
		return #pushed < 3, "mailbox inbound ring full"
	end)
	sender:clear()
	h.eq(sender:isIdle(), true)
	h.eq((sender:pump(function() error("nothing should be pushed") end)), 0)
end

-- Byte-addressed mailbox in fake memory, with ROM-side helpers that follow
-- docs/memory-map.md#ring-rules (the same model as mailbox_test.lua).
local BASE = 0x02030000
local OUT_HEAD, OUT_TAIL, OUT_SLOTS = 0x006, 0x007, 0x008
local IN_HEAD, IN_TAIL, IN_SLOTS = 0x208, 0x209, 0x20A

local function booted()
	local mem = { bytes = {} }
	function mem:read8(a) return self.bytes[a] or 0 end
	function mem:write8(a, v) self.bytes[a] = v end
	for i = 1, 4 do mem.bytes[BASE + i - 1] = ("COOP"):byte(i) end
	mem.bytes[BASE + 4], mem.bytes[BASE + 5] = mailbox.LAYOUT_VERSION, mailbox.FLAG_ROM_READY
	local box = mailbox.new(mem, BASE)
	assert(box:check())
	return mem, box
end

local function romPush(mem, msgType, payload)
	local head = mem:read8(BASE + OUT_HEAD)
	if (head + 1) % 16 == mem:read8(BASE + OUT_TAIL) then return false end
	local slot = BASE + OUT_SLOTS + head * 32
	mem.bytes[slot], mem.bytes[slot + 1] = msgType, #payload
	for i = 0, 29 do mem.bytes[slot + 2 + i] = i < #payload and payload:byte(i + 1) or 0 end
	mem.bytes[BASE + OUT_HEAD] = (head + 1) % 16
	return true
end

local function romPop(mem)
	local tail = mem:read8(BASE + IN_TAIL)
	if tail == mem:read8(BASE + IN_HEAD) then return nil end
	local slot = BASE + IN_SLOTS + tail * 32
	local bytes = {}
	for i = 0, mem:read8(slot + 1) - 1 do bytes[#bytes + 1] = string.char(mem:read8(slot + 2 + i)) end
	mem.bytes[BASE + IN_TAIL] = (tail + 1) % 16
	return mem:read8(slot), table.concat(bytes)
end

local PRESENCE = assert(mailbox.encodePresence({ mapGroup = 0, mapNum = 9, x = 7, y = -1, facing = 4,
	visible = true, gender = 1, trainerId = 0xDEADBEEF, slot = 0 }))

tests["lua to rom: 600 bytes stream past the ring capacity while presence flows"] = function()
	local mem, box = booted()
	local sender, romSide = fragments.newSender(), fragments.newReassembler()
	assert(600 > 15 * fragments.DATA_SIZE, "the message must not fit in the ring")
	assert(sender:send(ECHO, pattern(600)))
	local got, presences, frames = nil, 0, 0
	while not got do
		frames = frames + 1
		assert(frames < 50, "message never arrived")
		-- Lua frame: presence first, then as many fragments as fit.
		assert(box:push(mailbox.MSG.PRESENCE, PRESENCE))
		sender:pump(function(payload) return box:push(mailbox.MSG.FRAGMENT, payload) end)
		-- ROM frame: reads at most 8 slots.
		for _ = 1, 8 do
			local msgType, payload = romPop(mem)
			if not msgType then break end
			if msgType == mailbox.MSG.PRESENCE then
				h.eq(payload, PRESENCE)
				presences = presences + 1
			else
				h.eq(msgType, mailbox.MSG.FRAGMENT)
				local doneType, data, dropped = romSide:feed(payload)
				assert(not dropped, dropped)
				if doneType then got = { type = doneType, data = data } end
			end
		end
	end
	h.eq(got.type, ECHO)
	h.eq(got.data, pattern(600))
	assert(frames > 1 and presences > 1)
end

tests["rom to lua: 600 bytes stream past the ring capacity while presence flows"] = function()
	local mem, box = booted()
	local romFragments = assert(fragments.split(ECHO, pattern(600)))
	local nextFragment, luaSide = 1, fragments.newReassembler()
	local got, presences, frames = nil, 0, 0
	while not got do
		frames = frames + 1
		assert(frames < 50, "message never arrived")
		-- ROM frame (CoopOverworld_Update): presence, then the stream.
		romPush(mem, mailbox.MSG.PRESENCE, PRESENCE:sub(1, 13))
		while romFragments[nextFragment] and romPush(mem, mailbox.MSG.FRAGMENT, romFragments[nextFragment]) do
			nextFragment = nextFragment + 1
		end
		-- Lua frame: reads at most 8 slots.
		for _ = 1, 8 do
			local message = box:pop()
			if not message then break end
			if message.type == mailbox.MSG.PRESENCE then
				presences = presences + 1
			else
				local doneType, data, dropped = luaSide:feed(message.payload)
				assert(not dropped, dropped)
				if doneType then got = { type = doneType, data = data } end
			end
		end
	end
	h.eq(got.type, ECHO)
	h.eq(got.data, pattern(600))
	assert(frames > 1 and presences > 1)
end

return tests
