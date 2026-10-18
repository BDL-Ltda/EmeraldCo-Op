-- Reads the local player's state from game memory (milestones 0.1-0.3).
-- From 0.4 the ROM publishes its own state through the mailbox and this module
-- is retired (#26).
--
-- Pure apart from the bus it is given: no emu, socket or callbacks globals, so
-- tests can drive it with fake memory. Global addresses come only from
-- addresses.lua; struct offsets come only from the table below.

local M = {}

-- Struct offsets and sizes. Every value is documented, with its decomp source,
-- in docs/memory-map.md#player-state. Re-verify there before changing any.
local OFFSETS = {
	-- docs/memory-map.md#fields: struct SaveBlock1 location.mapGroup / mapNum (u8)
	saveBlock1MapGroup = 0x04,
	saveBlock1MapNum = 0x05,
	-- docs/memory-map.md#fields: struct SaveBlock2 playerGender (u8)
	saveBlock2Gender = 0x08,
	-- docs/memory-map.md#fields: struct SaveBlock2 playerTrainerId (u8[4], read as two u16)
	saveBlock2TrainerIdLow = 0x0A,
	saveBlock2TrainerIdHigh = 0x0C,
	-- docs/memory-map.md#fields: struct PlayerAvatar objectEventId (u8)
	playerAvatarObjectEventId = 0x05,
	-- docs/memory-map.md#fields: sizeof(struct ObjectEvent) and OBJECT_EVENTS_COUNT
	objectEventSize = 0x24,
	objectEventsCount = 16,
	-- docs/memory-map.md#fields: struct ObjectEvent currentCoords.x / .y (s16)
	objectEventX = 0x10,
	objectEventY = 0x12,
	-- docs/memory-map.md#fields: struct ObjectEvent facingDirection, bits 0-3 of this byte
	objectEventFacing = 0x18,
	facingMask = 0x0F,
	-- docs/memory-map.md#fields: MAP_OFFSET, removed from currentCoords
	mapOffset = 7,
	-- docs/memory-map.md#fields: MAP_UNDEFINED, never a loaded map
	mapUndefined = 0xFF,
	-- docs/memory-map.md#position-validity: struct Main callback1 / callback2
	mainCallback1 = 0x000,
	mainCallback2 = 0x004,
}

-- Symbols this module reads; all must be in addresses.lua.
local SYMBOLS = {
	"CB1_Overworld", "CB2_Overworld", "gMain", "gObjectEvents", "gPlayerAvatar",
	"gSaveBlock1Ptr", "gSaveBlock2Ptr", "sPlayTimeCounterState",
}

-- The game's DIR_* values (docs/memory-map.md#fields).
local FACING_NAMES = { [1] = "SOUTH", [2] = "NORTH", [3] = "WEST", [4] = "EAST" }

local function signed16(value)
	if value >= 0x8000 then
		return value - 0x10000
	end
	return value
end

-- bus: anything with read8/read16/read32(address), e.g. mGBA's emu.
-- symbols: addresses.symbols from client/addresses.lua.
-- Returns a reader whose getPlayerState() is called once per frame, or nil and
-- an error if a symbol is missing.
function M.new(bus, symbols)
	local addr = {}
	for _, name in ipairs(SYMBOLS) do
		local symbol = symbols and symbols[name]
		if type(symbol) ~= "table" or type(symbol.addr) ~= "number" then
			return nil, "addresses.lua has no symbol " .. name .. ". Regenerate it with cmd/symgen (see README.md)."
		end
		addr[name] = symbol.addr
	end

	-- One position snapshot, replaced as a whole (docs/memory-map.md#cached-position-across-sessions).
	local snapshot = nil
	local wasVisible = false

	local function positionValid()
		return bus:read32(addr.gMain + OFFSETS.mainCallback1) == addr.CB1_Overworld
			and bus:read32(addr.gMain + OFFSETS.mainCallback2) == addr.CB2_Overworld
	end

	-- Reads mapGroup, mapNum, x, y and facing in one go. Save block pointers and
	-- the player object id are read again every time: they move.
	local function readPosition()
		local id = bus:read8(addr.gPlayerAvatar + OFFSETS.playerAvatarObjectEventId)
		if id >= OFFSETS.objectEventsCount then
			return nil
		end
		local saveBlock1 = bus:read32(addr.gSaveBlock1Ptr)
		local mapGroup = bus:read8(saveBlock1 + OFFSETS.saveBlock1MapGroup)
		local mapNum = bus:read8(saveBlock1 + OFFSETS.saveBlock1MapNum)
		if mapGroup == OFFSETS.mapUndefined or mapNum == OFFSETS.mapUndefined then
			return nil
		end
		local object = addr.gObjectEvents + id * OFFSETS.objectEventSize
		return {
			mapGroup = mapGroup,
			mapNum = mapNum,
			x = signed16(bus:read16(object + OFFSETS.objectEventX)) - OFFSETS.mapOffset,
			y = signed16(bus:read16(object + OFFSETS.objectEventY)) - OFFSETS.mapOffset,
			facing = bus:read8(object + OFFSETS.objectEventFacing) & OFFSETS.facingMask,
		}
	end

	local function state(position, visible)
		local result = { visible = visible }
		if position then
			result.mapGroup, result.mapNum = position.mapGroup, position.mapNum
			result.x, result.y, result.facing = position.x, position.y, position.facing
		end
		if visible then
			local saveBlock2 = bus:read32(addr.gSaveBlock2Ptr)
			result.gender = bus:read8(saveBlock2 + OFFSETS.saveBlock2Gender)
			result.trainerId = bus:read16(saveBlock2 + OFFSETS.saveBlock2TrainerIdLow)
				| bus:read16(saveBlock2 + OFFSETS.saveBlock2TrainerIdHigh) << 16
		end
		return result
	end

	local reader = {}

	-- Returns { mapGroup, mapNum, x, y, facing, visible, gender, trainerId }.
	-- Position fields are nil while this session has no valid snapshot yet;
	-- gender and trainerId are nil while no game is running.
	function reader.getPlayerState()
		local visible = bus:read8(addr.sPlayTimeCounterState) ~= 0
		if not visible then
			-- Back to the title screen: report the last snapshot as hidden once,
			-- then drop it so the next session starts clean.
			local last = wasVisible and snapshot or nil
			snapshot, wasVisible = nil, false
			return state(last, false)
		end
		wasVisible = true
		if positionValid() then
			snapshot = readPosition() or snapshot
		end
		return state(snapshot, true)
	end

	return reader
end

function M.facingName(facing)
	return FACING_NAMES[facing] or ("UNKNOWN(" .. tostring(facing) .. ")")
end

-- One console line, e.g. "[state] map 0:9  pos 5,3  facing SOUTH  visible".
function M.format(s)
	local visibility = s.visible and "visible" or "hidden"
	if s.mapGroup == nil then
		return "[state] no position  " .. visibility
	end
	return string.format("[state] map %d:%d  pos %d,%d  facing %s  %s",
		s.mapGroup, s.mapNum, s.x, s.y, M.facingName(s.facing), visibility)
end

return M
