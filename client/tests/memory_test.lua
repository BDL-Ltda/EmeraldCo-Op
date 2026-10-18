-- Tests for client/memory.lua with fake memory. Run from the repository root:
--   lua5.4 client/tests/memory_test.lua
-- Standalone until the shared test runner from #16 exists.

package.path = "client/?.lua;" .. package.path
local memory = require("memory")

local failures = 0
local function test(name, fn)
	local ok, err = pcall(fn)
	print((ok and "ok   " or "FAIL ") .. name .. (ok and "" or ": " .. tostring(err)))
	if not ok then failures = failures + 1 end
end
local function eq(got, want)
	if got ~= want then error(string.format("got %q, want %q", tostring(got), tostring(want)), 2) end
end

-- Synthetic symbol table: the real one is client/addresses.lua. These values
-- only need to be distinct; CB1/CB2 are odd like real Thumb function pointers.
local SYMBOLS = {
	CB1_Overworld = { addr = 0x08001001 },
	CB2_Overworld = { addr = 0x08002001 },
	gMain = { addr = 0x03001000 },
	gObjectEvents = { addr = 0x02001000 },
	gPlayerAvatar = { addr = 0x02002000 },
	gSaveBlock1Ptr = { addr = 0x03002000 },
	gSaveBlock2Ptr = { addr = 0x03002004 },
	sPlayTimeCounterState = { addr = 0x03003000 },
}
local OTHER_CALLBACK = 0x08009001

-- Little-endian byte-addressed fake bus, the same shape as mGBA's emu.
local function newBus()
	local bytes = {}
	local bus = {}
	function bus.read8(_, a) return bytes[a] or 0 end
	function bus:read16(a) return self:read8(a) | self:read8(a + 1) << 8 end
	function bus:read32(a) return self:read16(a) | self:read16(a + 2) << 16 end
	function bus.write8(_, a, v) bytes[a] = v & 0xFF end
	function bus:write16(a, v) self:write8(a, v); self:write8(a + 1, v >> 8) end
	function bus:write32(a, v) self:write16(a, v); self:write16(a + 2, v >> 16) end
	return bus
end

local SB1, SB2 = 0x02020000, 0x02024000

-- A running game in the field: player object 3 at map 0:9, tile (5,3), facing south.
local function inGame()
	local bus = newBus()
	bus:write8(SYMBOLS.sPlayTimeCounterState.addr, 1)
	bus:write32(SYMBOLS.gMain.addr, SYMBOLS.CB1_Overworld.addr)
	bus:write32(SYMBOLS.gMain.addr + 4, SYMBOLS.CB2_Overworld.addr)
	bus:write32(SYMBOLS.gSaveBlock1Ptr.addr, SB1)
	bus:write32(SYMBOLS.gSaveBlock2Ptr.addr, SB2)
	bus:write8(SB1 + 0x04, 0)
	bus:write8(SB1 + 0x05, 9)
	bus:write8(SB2 + 0x08, 1)
	bus:write16(SB2 + 0x0A, 0x3039) -- trainerId 12345 + 0x0001 << 16
	bus:write16(SB2 + 0x0C, 0x0001)
	bus:write8(SYMBOLS.gPlayerAvatar.addr + 0x05, 3)
	local obj = SYMBOLS.gObjectEvents.addr + 3 * 0x24
	bus:write16(obj + 0x10, 5 + 7)
	bus:write16(obj + 0x12, 3 + 7)
	bus:write8(obj + 0x18, 0x31) -- movementDirection 3 in the high bits, facing 1 (south)
	return bus
end

local function setPosition(bus, group, num, x, y, facing)
	local sb1 = bus:read32(SYMBOLS.gSaveBlock1Ptr.addr)
	bus:write8(sb1 + 0x04, group)
	bus:write8(sb1 + 0x05, num)
	local id = bus:read8(SYMBOLS.gPlayerAvatar.addr + 0x05)
	local obj = SYMBOLS.gObjectEvents.addr + id * 0x24
	bus:write16(obj + 0x10, x + 7)
	bus:write16(obj + 0x12, y + 7)
	bus:write8(obj + 0x18, facing)
end

local function fieldRunning(bus, running)
	bus:write32(SYMBOLS.gMain.addr + 4, running and SYMBOLS.CB2_Overworld.addr or OTHER_CALLBACK)
end

local function assertPosition(s, group, num, x, y, facing)
	eq(s.mapGroup, group); eq(s.mapNum, num); eq(s.x, x); eq(s.y, y); eq(s.facing, facing)
end

test("reads the full state in the field", function()
	local s = assert(memory.new(inGame(), SYMBOLS)).getPlayerState()
	assertPosition(s, 0, 9, 5, 3, 1)
	eq(s.visible, true)
	eq(s.gender, 1)
	eq(s.trainerId, 0x00013039)
end)

test("missing symbol is a clear error", function()
	local symbols = {}
	for k, v in pairs(SYMBOLS) do symbols[k] = v end
	symbols.gMain = nil
	local reader, err = memory.new(inGame(), symbols)
	eq(reader, nil)
	assert(err:find("gMain", 1, true), err)
end)

test("title screen is hidden with no position", function()
	local bus = inGame()
	bus:write8(SYMBOLS.sPlayTimeCounterState.addr, 0)
	local s = memory.new(bus, SYMBOLS).getPlayerState()
	eq(s.visible, false)
	eq(s.mapGroup, nil)
	eq(s.gender, nil)
	eq(s.trainerId, nil)
end)

test("play time maxed out still counts as visible", function()
	local bus = inGame()
	bus:write8(SYMBOLS.sPlayTimeCounterState.addr, 2)
	eq(memory.new(bus, SYMBOLS).getPlayerState().visible, true)
end)

test("walking and turning update the position", function()
	local bus = inGame()
	local reader = memory.new(bus, SYMBOLS)
	reader.getPlayerState()
	setPosition(bus, 0, 9, 6, 3, 4)
	assertPosition(reader.getPlayerState(), 0, 9, 6, 3, 4)
	setPosition(bus, 0, 9, 6, 2, 2)
	assertPosition(reader.getPlayerState(), 0, 9, 6, 2, 2)
end)

test("coordinates are signed and offset by 7", function()
	local bus = inGame()
	setPosition(bus, 0, 9, -7, -1, 3) -- raw 0 and 6
	assertPosition(memory.new(bus, SYMBOLS).getPlayerState(), 0, 9, -7, -1, 3)
	local obj = SYMBOLS.gObjectEvents.addr + 3 * 0x24
	bus:write16(obj + 0x10, 0xFFFF) -- raw -1
	eq(memory.new(bus, SYMBOLS).getPlayerState().x, -8)
end)

test("map load keeps the last snapshot as one tuple", function()
	local bus = inGame()
	local reader = memory.new(bus, SYMBOLS)
	reader.getPlayerState()
	-- Mid warp: new map ID already written, coordinates still the old map's.
	fieldRunning(bus, false)
	bus:write32(SYMBOLS.gMain.addr, 0)
	setPosition(bus, 1, 0, 5, 3, 1)
	local s = reader.getPlayerState()
	assertPosition(s, 0, 9, 5, 3, 1)
	eq(s.visible, true)
	-- Field running again on the new map: the whole tuple is replaced.
	bus:write32(SYMBOLS.gMain.addr, SYMBOLS.CB1_Overworld.addr)
	fieldRunning(bus, true)
	setPosition(bus, 1, 0, 8, 2, 2)
	assertPosition(reader.getPlayerState(), 1, 0, 8, 2, 2)
end)

test("battles and menus keep the snapshot", function()
	local bus = inGame()
	local reader = memory.new(bus, SYMBOLS)
	reader.getPlayerState()
	fieldRunning(bus, false)
	setPosition(bus, 0, 9, 40, 40, 4)
	local s = reader.getPlayerState()
	assertPosition(s, 0, 9, 5, 3, 1)
	eq(s.visible, true)
end)

test("save blocks are dereferenced on every read", function()
	local bus = inGame()
	local reader = memory.new(bus, SYMBOLS)
	reader.getPlayerState()
	local moved1, moved2 = SB1 + 0x84, SB2 + 0x44
	bus:write32(SYMBOLS.gSaveBlock1Ptr.addr, moved1)
	bus:write32(SYMBOLS.gSaveBlock2Ptr.addr, moved2)
	bus:write8(SB1 + 0x05, 0xEE) -- stale copy must not be read
	bus:write8(moved1 + 0x04, 2)
	bus:write8(moved1 + 0x05, 7)
	bus:write8(moved2 + 0x08, 0)
	bus:write16(moved2 + 0x0A, 54321)
	bus:write16(moved2 + 0x0C, 0)
	local s = reader.getPlayerState()
	eq(s.mapGroup, 2); eq(s.mapNum, 7)
	eq(s.gender, 0); eq(s.trainerId, 54321)
end)

test("player object id is read on every read", function()
	local bus = inGame()
	local reader = memory.new(bus, SYMBOLS)
	reader.getPlayerState()
	bus:write8(SYMBOLS.gPlayerAvatar.addr + 0x05, 0)
	local obj = SYMBOLS.gObjectEvents.addr
	bus:write16(obj + 0x10, 20 + 7)
	bus:write16(obj + 0x12, 21 + 7)
	bus:write8(obj + 0x18, 3)
	assertPosition(reader.getPlayerState(), 0, 9, 20, 21, 3)
end)

test("undefined map or bad object id keeps the snapshot", function()
	local bus = inGame()
	local reader = memory.new(bus, SYMBOLS)
	reader.getPlayerState()
	setPosition(bus, 0xFF, 0xFF, 1, 1, 2)
	assertPosition(reader.getPlayerState(), 0, 9, 5, 3, 1)
	setPosition(bus, 0, 9, 1, 1, 2)
	bus:write8(SYMBOLS.gPlayerAvatar.addr + 0x05, 16)
	assertPosition(reader.getPlayerState(), 0, 9, 5, 3, 1)
end)

test("new session waits for a valid snapshot", function()
	local bus = inGame()
	fieldRunning(bus, false)
	local s = memory.new(bus, SYMBOLS).getPlayerState()
	eq(s.visible, true)
	eq(s.mapGroup, nil)
end)

test("soft reset reports hidden once, then drops the snapshot", function()
	local bus = inGame()
	local reader = memory.new(bus, SYMBOLS)
	reader.getPlayerState()
	bus:write8(SYMBOLS.sPlayTimeCounterState.addr, 0)
	local s = reader.getPlayerState()
	eq(s.visible, false)
	assertPosition(s, 0, 9, 5, 3, 1)
	s = reader.getPlayerState()
	eq(s.visible, false)
	eq(s.mapGroup, nil)
	-- Next session, still loading: the old snapshot must not come back.
	bus:write8(SYMBOLS.sPlayTimeCounterState.addr, 1)
	fieldRunning(bus, false)
	s = reader.getPlayerState()
	eq(s.visible, true)
	eq(s.mapGroup, nil)
	fieldRunning(bus, true)
	setPosition(bus, 0, 10, 2, 8, 1)
	assertPosition(reader.getPlayerState(), 0, 10, 2, 8, 1)
end)

test("format matches the issue's log line", function()
	eq(memory.format({ mapGroup = 0, mapNum = 9, x = 5, y = 3, facing = 1, visible = true }),
		"[state] map 0:9  pos 5,3  facing SOUTH  visible")
	eq(memory.format({ mapGroup = 1, mapNum = 0, x = -2, y = 3, facing = 4, visible = false }),
		"[state] map 1:0  pos -2,3  facing EAST  hidden")
	eq(memory.format({ visible = false }), "[state] no position  hidden")
	eq(memory.format({ visible = true }), "[state] no position  visible")
end)

test("facing names follow DIR_*", function()
	eq(memory.facingName(1), "SOUTH")
	eq(memory.facingName(2), "NORTH")
	eq(memory.facingName(3), "WEST")
	eq(memory.facingName(4), "EAST")
	eq(memory.facingName(0), "UNKNOWN(0)")
end)

if failures > 0 then
	print(failures .. " test(s) failed")
	os.exit(1)
end
print("all memory tests passed")
