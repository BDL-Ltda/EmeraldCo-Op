-- Lua side of gCoopMailbox, the ROM <-> Lua shared-memory mailbox (0.4 onward).
--
-- Pure apart from the memory it is given: no emu, socket or callbacks globals,
-- so tests can drive it with fake memory. The base address comes from
-- addresses.lua (symbols.gCoopMailbox.addr); every offset below is documented
-- in docs/memory-map.md#mailbox, which mirrors include/coop/mailbox.h.

local M = {}

-- Header, ring and slot layout (docs/memory-map.md#header-and-rings, #slot).
local LAYOUT = {
	magic = 0x000, -- 4 bytes, ASCII "COOP"
	layoutVersion = 0x004,
	flags = 0x005,
	outboundHead = 0x006, -- ROM writes
	outboundTail = 0x007, -- Lua writes
	outboundSlots = 0x008,
	inboundHead = 0x208, -- Lua writes
	inboundTail = 0x209, -- ROM writes
	inboundSlots = 0x20A,
	slotCount = 16,
	slotSize = 0x20,
	slotType = 0x00,
	slotLength = 0x01,
	slotPayload = 0x02,
	payloadMax = 30,
}

M.MAGIC = "COOP"
M.LAYOUT_VERSION = 1

-- flags bits (docs/memory-map.md#header-and-rings).
M.FLAG_LUA_CONNECTED = 0x01
M.FLAG_ROM_READY = 0x02

-- Message types, mirroring include/constants/coop.h (docs/memory-map.md#message-types).
M.MSG = { NONE = 0, PRESENCE = 1, LEAVE = 2 }

local Mailbox = {}
Mailbox.__index = Mailbox

-- mem: anything with read8(address) / write8(address, value), e.g. mGBA's emu.
-- baseAddr: addresses.symbols.gCoopMailbox.addr from client/addresses.lua.
function M.new(mem, baseAddr)
	assert(type(baseAddr) == "number", "mailbox: baseAddr must be a number")
	return setmetatable({ mem = mem, base = baseAddr }, Mailbox)
end

function Mailbox:read8(offset)
	return self.mem:read8(self.base + offset) & 0xFF
end

function Mailbox:write8(offset, value)
	self.mem:write8(self.base + offset, value & 0xFF)
end

-- Returns ok, message. Call it before using the mailbox, and again when it may
-- have been reset (soft reset zeroes it and rewrites the header).
function Mailbox:check()
	local magic = {}
	for i = 0, #M.MAGIC - 1 do
		magic[#magic + 1] = string.char(self:read8(LAYOUT.magic + i))
	end
	magic = table.concat(magic)
	if magic ~= M.MAGIC then
		return false, string.format(
			"mailbox magic mismatch: expected %q, got %q. Load the Co-Op ROM matching addresses.lua and let it boot.",
			M.MAGIC, magic)
	end
	local version = self:read8(LAYOUT.layoutVersion)
	if version ~= M.LAYOUT_VERSION then
		return false, string.format(
			"mailbox layout version mismatch: ROM has %d, client expects %d. Use a client and ROM from the same release.",
			version, M.LAYOUT_VERSION)
	end
	if self:read8(LAYOUT.flags) & M.FLAG_ROM_READY == 0 then
		return false, "mailbox is not ready: the ROM has not set rom_ready."
	end
	return true, string.format("mailbox ready (layout v%d)", version)
end

-- Sets or clears lua_connected with a read-modify-write that keeps the ROM's bits.
function Mailbox:setLuaConnected(connected)
	local flags = self:read8(LAYOUT.flags)
	if connected then
		flags = flags | M.FLAG_LUA_CONNECTED
	else
		flags = flags & ~M.FLAG_LUA_CONNECTED
	end
	self:write8(LAYOUT.flags, flags)
end

local function nextIndex(index)
	return (index + 1) % LAYOUT.slotCount
end

-- Pops the oldest outbound (ROM -> Lua) message: {type = n, payload = bytes},
-- or nil when the ring is empty. Copies the slot first, then advances tail.
function Mailbox:pop()
	local head = self:read8(LAYOUT.outboundHead)
	local tail = self:read8(LAYOUT.outboundTail)
	if head >= LAYOUT.slotCount or tail >= LAYOUT.slotCount then
		return nil, string.format("mailbox outbound indices out of range (head %d, tail %d)", head, tail)
	end
	if tail == head then return nil end
	local slot = LAYOUT.outboundSlots + tail * LAYOUT.slotSize
	local msgType = self:read8(slot + LAYOUT.slotType)
	local length = math.min(self:read8(slot + LAYOUT.slotLength), LAYOUT.payloadMax)
	local payload = {}
	for i = 0, length - 1 do
		payload[#payload + 1] = string.char(self:read8(slot + LAYOUT.slotPayload + i))
	end
	self:write8(LAYOUT.outboundTail, nextIndex(tail))
	return { type = msgType, payload = table.concat(payload) }
end

-- Pushes one inbound (Lua -> ROM) message. payload is a byte string of at most
-- 30 bytes. Returns true, or false and a reason (ring full, bad message), like
-- CoopMailbox_Push. Fills the whole slot first, then advances head.
function Mailbox:push(msgType, payload)
	if math.type(msgType) ~= "integer" or msgType < 1 or msgType > 0xFF then
		return false, "mailbox: message type must be an integer 1-255"
	end
	if type(payload) ~= "string" or #payload > LAYOUT.payloadMax then
		return false, string.format("mailbox: payload must be a string of at most %d bytes", LAYOUT.payloadMax)
	end
	local head = self:read8(LAYOUT.inboundHead)
	local tail = self:read8(LAYOUT.inboundTail)
	if head >= LAYOUT.slotCount or tail >= LAYOUT.slotCount then
		return false, string.format("mailbox inbound indices out of range (head %d, tail %d)", head, tail)
	end
	if nextIndex(head) == tail then return false, "mailbox inbound ring full" end
	local slot = LAYOUT.inboundSlots + head * LAYOUT.slotSize
	self:write8(slot + LAYOUT.slotType, msgType)
	self:write8(slot + LAYOUT.slotLength, #payload)
	for i = 0, LAYOUT.payloadMax - 1 do
		self:write8(slot + LAYOUT.slotPayload + i, i < #payload and payload:byte(i + 1) or 0)
	end
	self:write8(LAYOUT.inboundHead, nextIndex(head))
	return true
end

-- PRESENCE payload (docs/memory-map.md#presence-payload): little-endian
-- mapGroup u8, mapNum u8, x s16, y s16, facing u8, visible u8, gender u8,
-- trainerId u32, then slot u8 in inbound messages only.
local PRESENCE_FORMAT = "<BBi2i2BBBI4"
M.PRESENCE_LENGTH = 13
M.PRESENCE_INBOUND_LENGTH = 14
M.REMOTE_SLOTS = 4

local function isInt(value, low, high)
	return math.type(value) == "integer" and value >= low and value <= high
end

-- presence: {mapGroup, mapNum, x, y, facing, visible, gender, trainerId, slot?}.
-- With slot (0-3, inbound only) the payload is 14 bytes, without it 13.
-- Returns the payload bytes, or nil and an error.
function M.encodePresence(presence)
	if type(presence) ~= "table" then return nil, "presence must be a table" end
	local p = presence
	if not isInt(p.mapGroup, 0, 0xFF) or not isInt(p.mapNum, 0, 0xFF) then
		return nil, "presence mapGroup/mapNum must be integers 0-255"
	end
	if not isInt(p.x, -0x8000, 0x7FFF) or not isInt(p.y, -0x8000, 0x7FFF) then
		return nil, "presence x/y must be 16-bit signed integers"
	end
	if not isInt(p.facing, 1, 4) then return nil, "presence facing must be 1-4" end
	if type(p.visible) ~= "boolean" then return nil, "presence visible must be a boolean" end
	if not isInt(p.gender, 0, 1) then return nil, "presence gender must be 0 or 1" end
	if not isInt(p.trainerId, 0, 0xFFFFFFFF) then return nil, "presence trainerId must be a 32-bit unsigned integer" end
	local bytes = string.pack(PRESENCE_FORMAT, p.mapGroup, p.mapNum, p.x, p.y, p.facing,
		p.visible and 1 or 0, p.gender, p.trainerId)
	if p.slot ~= nil then
		if not isInt(p.slot, 0, M.REMOTE_SLOTS - 1) then
			return nil, string.format("presence slot must be 0-%d", M.REMOTE_SLOTS - 1)
		end
		bytes = bytes .. string.char(p.slot)
	end
	return bytes
end

-- Returns the presence table (slot only when the payload has one), or nil and an error.
function M.decodePresence(payload)
	if type(payload) ~= "string" or #payload < M.PRESENCE_LENGTH then
		return nil, string.format("presence payload must be at least %d bytes", M.PRESENCE_LENGTH)
	end
	local mapGroup, mapNum, x, y, facing, visible, gender, trainerId = string.unpack(PRESENCE_FORMAT, payload)
	return {
		mapGroup = mapGroup,
		mapNum = mapNum,
		x = x,
		y = y,
		facing = facing,
		visible = visible ~= 0,
		gender = gender,
		trainerId = trainerId,
		slot = #payload >= M.PRESENCE_INBOUND_LENGTH and payload:byte(M.PRESENCE_INBOUND_LENGTH) or nil,
	}
end

return M
