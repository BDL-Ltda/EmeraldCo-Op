-- Tests for client/lib/mailbox.lua with fake memory, discovered by client/tests/run.lua.

package.path = "client/lib/?.lua;" .. package.path
local mailbox = require("mailbox")

local tests = {}
local function test(name, fn)
	tests[name] = fn
end
local function eq(got, want)
	if got ~= want then error(string.format("got %q, want %q", tostring(got), tostring(want)), 2) end
end

-- Synthetic base address: the real one is symbols.gCoopMailbox.addr in client/addresses.lua.
local BASE = 0x02030000

-- Offsets from docs/memory-map.md#header-and-rings, written out again so the
-- tests catch a wrong offset in the module.
local FLAGS, OUT_HEAD, OUT_TAIL, OUT_SLOTS = 0x005, 0x006, 0x007, 0x008
local IN_HEAD, IN_TAIL, IN_SLOTS = 0x208, 0x209, 0x20A
local SLOT_SIZE = 0x20

-- Byte-addressed fake memory, the same shape as mGBA's emu. Records every write.
local function newMem()
	local mem = { bytes = {}, writes = {} }
	function mem:read8(a) return self.bytes[a] or 0 end
	function mem:write8(a, v)
		self.bytes[a] = v
		self.writes[#self.writes + 1] = a
	end
	return mem
end

-- The header CoopMailbox_Init() leaves behind: rings empty, rom_ready set.
local function booted()
	local mem = newMem()
	for i = 1, 4 do mem.bytes[BASE + i - 1] = ("COOP"):byte(i) end
	mem.bytes[BASE + 0x004] = 1
	mem.bytes[BASE + FLAGS] = mailbox.FLAG_ROM_READY
	return mem, mailbox.new(mem, BASE)
end

-- What CoopMailbox_Push does on the ROM side (outbound ring).
local function romPush(mem, msgType, payload)
	local head = mem:read8(BASE + OUT_HEAD)
	local slot = BASE + OUT_SLOTS + head * SLOT_SIZE
	mem.bytes[slot] = msgType
	mem.bytes[slot + 1] = #payload
	for i = 0, 29 do mem.bytes[slot + 2 + i] = i < #payload and payload:byte(i + 1) or 0 end
	mem.bytes[BASE + OUT_HEAD] = (head + 1) % 16
end

-- What CoopMailbox_Pop does on the ROM side (inbound ring).
local function romPop(mem)
	local tail = mem:read8(BASE + IN_TAIL)
	if tail == mem:read8(BASE + IN_HEAD) then return nil end
	local slot = BASE + IN_SLOTS + tail * SLOT_SIZE
	local bytes = {}
	for i = 0, mem:read8(slot + 1) - 1 do bytes[#bytes + 1] = string.char(mem:read8(slot + 2 + i)) end
	mem.bytes[BASE + IN_TAIL] = (tail + 1) % 16
	return mem:read8(slot), table.concat(bytes)
end

local PRESENCE = {
	mapGroup = 0, mapNum = 9, x = 7, y = -1, facing = 4, visible = true, gender = 1, trainerId = 0xDEADBEEF,
}

test("check passes on a booted mailbox", function()
	local _, box = booted()
	local ok, msg = box:check()
	eq(ok, true)
	eq(msg, "mailbox ready (layout v1)")
end)

test("check rejects a magic mismatch", function()
	local mem, box = booted()
	mem.bytes[BASE + 3] = ("X"):byte()
	local ok, msg = box:check()
	eq(ok, false)
	assert(msg:find("magic mismatch", 1, true) and msg:find('"COOX"', 1, true), msg)
end)

test("check rejects zeroed memory (ROM not booted or not the Co-Op ROM)", function()
	local ok, msg = mailbox.new(newMem(), BASE):check()
	eq(ok, false)
	assert(msg:find("magic mismatch", 1, true), msg)
end)

test("check rejects a layout version mismatch", function()
	local mem, box = booted()
	mem.bytes[BASE + 0x004] = 2
	local ok, msg = box:check()
	eq(ok, false)
	eq(msg, "mailbox layout version mismatch: ROM has 2, client expects 1. "
		.. "Use a client and ROM from the same release.")
end)

test("check rejects a header without rom_ready", function()
	local mem, box = booted()
	mem.bytes[BASE + FLAGS] = 0
	eq((box:check()), false)
end)

test("setLuaConnected changes only its own bit", function()
	local mem, box = booted()
	box:setLuaConnected(true)
	eq(mem:read8(BASE + FLAGS), mailbox.FLAG_ROM_READY | mailbox.FLAG_LUA_CONNECTED)
	box:setLuaConnected(false)
	eq(mem:read8(BASE + FLAGS), mailbox.FLAG_ROM_READY)
	eq(#mem.writes, 2)
end)

test("pop on an empty ring returns nil and writes nothing", function()
	local mem, box = booted()
	eq(box:pop(), nil)
	eq(#mem.writes, 0)
end)

test("pop returns ROM messages in order and advances tail", function()
	local mem, box = booted()
	romPush(mem, 1, "first")
	romPush(mem, 7, "")
	local msg = box:pop()
	eq(msg.type, 1)
	eq(msg.payload, "first")
	eq(mem:read8(BASE + OUT_TAIL), 1)
	msg = box:pop()
	eq(msg.type, 7)
	eq(msg.payload, "")
	eq(box:pop(), nil)
end)

test("pop writes only outbound tail, after reading the slot", function()
	local mem, box = booted()
	romPush(mem, 1, "x")
	box:pop()
	eq(#mem.writes, 1)
	eq(mem.writes[1], BASE + OUT_TAIL)
end)

test("pop clamps a length above 30 like the ROM", function()
	local mem, box = booted()
	romPush(mem, 1, ("a"):rep(30))
	mem.bytes[BASE + OUT_SLOTS + 1] = 200
	eq(#box:pop().payload, 30)
end)

test("pop wraps around past slot 15", function()
	local mem, box = booted()
	mem.bytes[BASE + OUT_HEAD], mem.bytes[BASE + OUT_TAIL] = 14, 14
	for i = 1, 4 do romPush(mem, 1, string.char(i)) end
	eq(mem:read8(BASE + OUT_HEAD), 2)
	for i = 1, 4 do eq(box:pop().payload, string.char(i)) end
	eq(mem:read8(BASE + OUT_TAIL), 2)
	eq(box:pop(), nil)
end)

test("pop drains a full ring of 15 messages", function()
	local mem, box = booted()
	for i = 1, 15 do romPush(mem, 1, string.char(i)) end
	for i = 1, 15 do eq(box:pop().payload, string.char(i)) end
	eq(box:pop(), nil)
end)

test("pop rejects out-of-range indices", function()
	local mem, box = booted()
	mem.bytes[BASE + OUT_HEAD] = 16
	local msg, err = box:pop()
	eq(msg, nil)
	assert(err:find("out of range", 1, true), err)
end)

test("push writes a zero-filled slot that the ROM can pop", function()
	local mem, box = booted()
	for i = 0, 29 do mem.bytes[BASE + IN_SLOTS + 2 + i] = 0xAA end
	eq(box:push(1, "hi"), true)
	eq(mem:read8(BASE + IN_HEAD), 1)
	eq(mem:read8(BASE + IN_SLOTS + 1), 2)
	for i = 2, 29 do eq(mem:read8(BASE + IN_SLOTS + 2 + i), 0) end
	local msgType, payload = romPop(mem)
	eq(msgType, 1)
	eq(payload, "hi")
end)

test("push writes the slot before advancing inbound head", function()
	local mem, box = booted()
	box:push(1, "abc")
	eq(#mem.writes, 1 + 1 + 30 + 1)
	for i = 1, #mem.writes - 1 do
		local a = mem.writes[i]
		assert(a >= BASE + IN_SLOTS and a < BASE + IN_SLOTS + SLOT_SIZE, "write outside slot 0 before head")
	end
	eq(mem.writes[#mem.writes], BASE + IN_HEAD)
end)

test("push holds 15 messages and then reports full", function()
	local mem, box = booted()
	for i = 1, 15 do eq(box:push(1, string.char(i)), true) end
	local before = #mem.writes
	local ok, err = box:push(1, "x")
	eq(ok, false)
	eq(err, "mailbox inbound ring full")
	eq(#mem.writes, before)
	eq(mem:read8(BASE + IN_HEAD), 15)
	romPop(mem)
	eq(box:push(1, "x"), true)
	eq(mem:read8(BASE + IN_HEAD), 0)
end)

test("push wraps around past slot 15", function()
	local mem, box = booted()
	mem.bytes[BASE + IN_HEAD], mem.bytes[BASE + IN_TAIL] = 15, 15
	eq(box:push(1, "a"), true)
	eq(mem:read8(BASE + IN_HEAD), 0)
	eq(box:push(1, "b"), true)
	eq(mem:read8(BASE + IN_SLOTS + 0 * SLOT_SIZE + 2), ("b"):byte())
	eq(select(2, romPop(mem)), "a")
	eq(select(2, romPop(mem)), "b")
	eq(romPop(mem), nil)
end)

test("push rejects bad messages without writing", function()
	local mem, box = booted()
	eq((box:push(1, ("a"):rep(31))), false)
	eq((box:push(0, "")), false)
	eq((box:push(256, "")), false)
	eq((box:push(1, nil)), false)
	eq((box:push(1.5, "")), false)
	eq(#mem.writes, 0)
end)

test("presence encodes to 13 little-endian bytes", function()
	local bytes = assert(mailbox.encodePresence(PRESENCE))
	eq(#bytes, mailbox.PRESENCE_LENGTH)
	eq(bytes, "\x00\x09\x07\x00\xff\xff\x04\x01\x01\xef\xbe\xad\xde")
end)

test("presence round trip without slot", function()
	local got = assert(mailbox.decodePresence(assert(mailbox.encodePresence(PRESENCE))))
	for key, value in pairs(PRESENCE) do eq(got[key], value) end
	eq(got.slot, nil)
end)

test("presence round trip through both rings, with slot inbound", function()
	local mem, box = booted()
	romPush(mem, mailbox.MSG.PRESENCE, assert(mailbox.encodePresence(PRESENCE)))
	local msg = box:pop()
	eq(msg.type, mailbox.MSG.PRESENCE)
	local got = assert(mailbox.decodePresence(msg.payload))
	got.slot = 3
	got.x, got.visible = -32768, false
	assert(box:push(mailbox.MSG.PRESENCE, assert(mailbox.encodePresence(got))))
	local msgType, payload = romPop(mem)
	eq(msgType, mailbox.MSG.PRESENCE)
	eq(#payload, mailbox.PRESENCE_INBOUND_LENGTH)
	local back = assert(mailbox.decodePresence(payload))
	eq(back.slot, 3)
	eq(back.x, -32768)
	eq(back.visible, false)
	eq(back.trainerId, 0xDEADBEEF)
end)

test("presence encode rejects out-of-range fields", function()
	local function with(key, value)
		local p = {}
		for k, v in pairs(PRESENCE) do p[k] = v end
		p[key] = value
		return mailbox.encodePresence(p)
	end
	for _, case in ipairs({
		{ "mapGroup", 256 }, { "mapNum", -1 }, { "x", 0x8000 }, { "y", 1.5 }, { "facing", 0 },
		{ "facing", 5 }, { "visible", 1 }, { "gender", 2 }, { "trainerId", 0x100000000 }, { "slot", 4 },
	}) do
		local bytes, err = with(case[1], case[2])
		eq(bytes, nil)
		assert(type(err) == "string" and #err > 0, "expected an error for " .. case[1])
	end
	eq((mailbox.encodePresence(nil)), nil)
end)

test("presence decode rejects a short payload", function()
	local got, err = mailbox.decodePresence(("\0"):rep(12))
	eq(got, nil)
	assert(err:find("13 bytes", 1, true), err)
end)

return tests
