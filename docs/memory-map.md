# Memory map

Global addresses are generated. Struct field offsets are documented here, sourced
from the decompilation headers and verified against the `make modern` build; this
document never duplicates generated addresses.

## Generated globals

**[`client/addresses.lua`](../client/addresses.lua)** is the only source of global
addresses. `cmd/symgen` reads the built ELF using Go's standard-library
`debug/elf` and writes a Lua module returning:

| Field | Meaning |
| --- | --- |
| `romSha1` | Lowercase SHA1 of the supplied ROM file. |
| `symbols["NAME"].addr` | Symbol address from the ELF. |
| `symbols["NAME"].size` | Symbol size in bytes from the ELF. |

Symbol selection lives in
[`cmd/symgen/symbols.txt`](../cmd/symgen/symbols.txt). The current allowlist
contains only `gCoopMailbox` (see [Mailbox](#mailbox)). Earlier milestones also
exported game globals and functions for the direct player-state reader.

See [Generating client addresses](../README.md#generating-client-addresses) for
the command, required build inputs, validation, map verification and regeneration
rules. Never hand-write or guess global addresses, or edit the generated module.
Update this document if the memory layout changes. The current client reads
only `gCoopMailbox`; the player-state offsets below document the historical
direct reader used through milestone 0.3.

## Player state

These are the fields the client reads for `hello` and `presence` (see
[protocol.md](protocol.md)) during milestones 0.1 to 0.3. `NAME` in a path means
`symbols["NAME"].addr` from `client/addresses.lua`; `[ptr]` means "read the
32-bit pointer stored there". The GBA is **little-endian**.

Decomp links point at our fork at upstream commit
[`731ad5b`](https://github.com/BDL-Ltda/pokeemerald/tree/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881).
The submodule now pins a later commit that only adds the [mailbox](#mailbox)
(new files plus two lines in `src/main.c`); none of the structs or code cited
below changed, so the links stay on `731ad5b`. **When the submodule pointer moves, re-verify this section** (see
[How the offsets were verified](#how-the-offsets-were-verified)) and update the
links.

### Save blocks move: always dereference

`gSaveBlock1Ptr` and `gSaveBlock2Ptr` are pointers, and the blocks they point at
**move**. [`SetSaveBlocksPointers`][load_save-70] adds a random offset every time
it runs, and [`MoveSaveBlocks_ResetHeap`][load_save-84] copies both blocks to the
new place. It runs on every warp and other full map load
([`ResetMirageTowerAndSaveBlockPtrs`][overworld-2071]; seamless route-edge
crossings don't move them), at the start of every
battle ([battle_main.c][battle_main-590]), and when a game is loaded.

So read `gSaveBlock1Ptr` / `gSaveBlock2Ptr` **again on every read** and add the
field offset to the value you just read. Never cache the pointer or a derived
address across frames.

### Historical reader timing: the `keysRead` callback

The 0.1–0.3 client read player state from mGBA's **`keysRead`** callback.
The current mailbox bridge polls the completed ring slots once per frame.
A `frame` callback fires at the end of every video frame, wherever the game's
code happens to be. A heavy game loop iteration (a map load, a save block move,
a route-edge crossing) runs past the frame boundary, so a `frame` callback can
see memory half updated. This was observed in mGBA 0.10.5: crossing from
Littleroot Town (`0:9`) to Route 101 (`0:16`), one `frame` read returned map
`0:16` with the Littleroot coordinates `11,-1`, because
[`CameraUpdate`][camera-414] had run `CameraMove` (which loads the new map ID)
but not yet `UpdateObjectEventsForCameraUpdate` (which shifts the
coordinates).

The game reads the keypad (`REG_KEYINPUT`) only in [`ReadKeys`][main-252], the
first call of each [`AgbMain`][main-89] loop iteration, when the previous
iteration has finished. `keysRead` fires on that read, so every read made there
sees a consistent state. (The e-Reader code also reads the keypad, but it never
runs in normal play.) If the game lags, `keysRead` fires less than once per
frame, which is fine for presence.

### Fields

| Field | Path | Offset (from) | Size, type | Decoded value |
| --- | --- | --- | --- | --- |
| `mapGroup` | `[gSaveBlock1Ptr]` + `location.mapGroup` | `0x04` (`struct SaveBlock1`) | 1 byte, `s8` | Read as unsigned (`u8`). There are 34 groups (0–33) and at most 108 maps per group (`data/maps/map_groups.json`), so `s8` and `u8` agree for every real map. `0xFF` is `MAP_UNDEFINED`, never a loaded map. |
| `mapNum` | `[gSaveBlock1Ptr]` + `location.mapNum` | `0x05` (`struct SaveBlock1`) | 1 byte, `s8` | Read as unsigned (`u8`), same as `mapGroup`. |
| `x` | `gObjectEvents` + `id * 0x24` + `currentCoords.x` | `0x10` (`struct ObjectEvent`) | 2 bytes, `s16` | Map coordinate = value − `MAP_OFFSET` (7). |
| `y` | `gObjectEvents` + `id * 0x24` + `currentCoords.y` | `0x12` (`struct ObjectEvent`) | 2 bytes, `s16` | Map coordinate = value − `MAP_OFFSET` (7). |
| `facing` | `gObjectEvents` + `id * 0x24` + `facingDirection` | byte `0x18`, **bits 0–3** (`struct ObjectEvent`) | 4-bit unsigned bitfield | `byte & 0x0F`: `1` south, `2` north, `3` west, `4` east. |
| `gender` | `[gSaveBlock2Ptr]` + `playerGender` | `0x08` (`struct SaveBlock2`) | 1 byte, `u8` | `0` `MALE`, `1` `FEMALE`. |
| `trainerId` | `[gSaveBlock2Ptr]` + `playerTrainerId` | `0x0A` (`struct SaveBlock2`) | 4 bytes, `u8[4]` | Little-endian 32-bit value: `b0 \| b1 << 8 \| b2 << 16 \| b3 << 24`. **Not 4-byte aligned**: read two `u16` (`0x0A`, `0x0C`) or four bytes, never one 32-bit read. |
| player object `id` | `gPlayerAvatar` + `objectEventId` | `0x05` (`struct PlayerAvatar`) | 1 byte, `u8` | Index into `gObjectEvents` (0–15). Read it every time; do not cache it. |

`sizeof(struct ObjectEvent)` is `0x24` (36), and `gObjectEvents` has
`OBJECT_EVENTS_COUNT` = 16 entries (ELF size 576 = 16 × 36).

Sources:

- `mapGroup`, `mapNum`: [`struct SaveBlock1`][global-984] field
  [`location`][global-987] is a [`struct WarpData`][global-581]
  (`s8 mapGroup; s8 mapNum; s8 warpId; s16 x, y;`). Pointer declared at
  [global.h:1081][global-1081], defined at [load_save.c:41][load_save-41].
  `MAP_UNDEFINED` is in [constants/maps.h][maps-12].
- `x`, `y`: [`struct ObjectEvent`][fieldmap-194] field
  [`currentCoords`][fieldmap-235] is a [`struct Coords16`][global-174]
  (`s16 x; s16 y;`). `MAP_OFFSET` is in [fieldmap.h][fieldmap_h-18]. The game
  reads them exactly this way in [`PlayerGetDestCoords`][avatar-1141].
  `currentCoords` changes to the destination tile when a step **starts**
  (`previousCoords` keeps the origin), so it is the tile the player is on or
  walking into.
- `facing`: [`facingDirection`][fieldmap-237] is the first field of a `u16`
  bitfield unit at `0x18`, see [`GetPlayerFacingDirection`][avatar-1182].
  `DIR_*` values are in [constants/global.h][const-138]. The other bits of that
  byte belong to `movementDirection`, so always mask.
- `gender`: [`struct SaveBlock2`][global-508] field
  [`playerGender`][global-511]. `MALE` / `FEMALE` in
  [constants/global.h][const-113]. (`gPlayerAvatar.gender` also exists but is only
  the avatar state; the save block is the source of truth.)
- `trainerId`: [`playerTrainerId`][global-513], `TRAINER_ID_LENGTH` = 4
  ([constants/global.h][const-81]). The game builds the 32-bit ID the same way in
  [`InitLocalLinkPlayer`][link-326]. Pointer declared at
  [global.h:544][global-544].
- player object: [`struct PlayerAvatar`][fieldmap-342] field
  [`objectEventId`][fieldmap-349]; `gObjectEvents` / `gPlayerAvatar` declared at
  [global.fieldmap.h:371][fieldmap-371] and defined at
  [field_player_avatar.c:37][avatar-37]. `OBJECT_EVENTS_COUNT` is in
  [constants/global.h][const-46].

### Visible signal

`visible` ([protocol.md](protocol.md)) is **true for the whole time a game
session is running**. That includes battles, menus, warps, fades, cutscenes and
NPC talk. It is **false only before a game is started**: the boot screens, the
title screen, the main menu and the new-game intro (Professor Birch). One byte
gives this:

```text
visible = u8 [sPlayTimeCounterState] ~= 0   -- 0 STOPPED, 1 RUNNING, 2 MAXED_OUT
```

| Value | Offset (from) | Size, type | Source |
| --- | --- | --- | --- |
| `sPlayTimeCounterState` | the symbol itself | 1 byte, `u8` | [play_time.c:11][play_time-11] (file `static`; it is still in the ELF symbol table) |

Why it works:

- It is `STOPPED` (0) at power-on and after every soft reset, because
  [`DoSoftReset`][main-437] calls `SoftReset(RESET_ALL)`, which clears all RAM.
  The new-game setup also resets it ([new_game.c:165][new_game-165]).
- The only places that start it are [`CB2_NewGame`][overworld-1539] and
  [`CB2_ContinueSavedGame`][overworld-1735]: the first overworld load of a new
  or continued game.
- Nothing stops it during play. [`PlayTimeCounter_Stop`][play_time-31] exists
  but nothing calls it. After 999 hours it becomes `MAXED_OUT` (2), which is
  still a running session, hence `~= 0` rather than `== 1`.

#### Position validity

While a map is loading, the player's object event is torn down and rebuilt, so
`x` and `y` can briefly hold stale or meaningless values. Read the position only
when the field is running:

```text
positionValid = [gMain + 0x000] == CB1_Overworld   -- gMain.callback1, u32 function pointer
            and [gMain + 0x004] == CB2_Overworld   -- gMain.callback2, u32 function pointer
```

| Value | Offset (from) | Size, type | Source |
| --- | --- | --- | --- |
| `gMain.callback1` | `0x000` (`struct Main`) | 4 bytes, function pointer | [main.h:10][main-10] |
| `gMain.callback2` | `0x004` (`struct Main`) | 4 bytes, function pointer | [main.h:11][main-11] |

Compare the callback pointers with `symbols["CB1_Overworld"].addr` and
`symbols["CB2_Overworld"].addr` as exported, **without** clearing bit 0. Both
are Thumb functions, so the ELF value is odd, and the game stores that same odd
value: the literal `CB1_Overworld` loads to compare with `gMain.callback2` is
exactly the exported `CB2_Overworld` value, odd bit included.

`callback2` is [`CB2_Overworld`][overworld-1484] whenever the field is running
and changes for battles ([`BattleTransition_StartOnField`][transition-1026]),
full-screen menus and map loads ([`CB2_LoadMap`][overworld-1572]). `callback1`
is `NULL` during map loads ([overworld.c:1577][overworld-1577]) and
[`CB1_Overworld`][overworld-1459] once the field is back
([overworld.c:1582][overworld-1582]).

In an mGBA 0.10.5 run, `positionValid` was false for about 10 frames on each map
load, and during those frames `x`/`y` still showed the previous map's
coordinates.

#### Cached position across sessions

The client keeps one **position snapshot**: `mapGroup`, `mapNum`, `x`, `y` and
`facing`, read together in the same `keysRead` callback while `positionValid` is true. It
replaces the whole snapshot at once and never updates single fields while
`positionValid` is false, so a new map ID is never paired with the old map's
coordinates. Each read:

1. **`visible` is false and was never true** (boot, title, intro): there is no
   snapshot and nothing to publish.
2. **`visible` is true and `positionValid` is true:** take a fresh snapshot.
   Publish it if it changed.
3. **`visible` is true and `positionValid` is false** (map load, battle,
   full-screen menu): keep the last snapshot unchanged. If this session has no
   snapshot yet (the first frames after starting or continuing a game), publish
   nothing.
4. **`visible` goes from true to false** (soft or hard reset): first announce
   the player as invisible, using the last snapshot with `visible = false` (or
   disconnect), so peers don't keep drawing a player who has gone back to the
   title screen. **Then** discard the snapshot.
5. **`visible` becomes true again** (next session): case 2 or 3 applies. Publish
   nothing until the new session has a fresh snapshot.

How this goes over the wire (presence messages, disconnect) belongs to
[#17](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/17). #11 only reads the
values and must test both the snapshot during map loads and the reset to a new
session.

### How the offsets were verified

Never by eye. On the pinned commit, inside the ROM build image
(`devkitARM` GCC 16.1.0, `docker compose run --build --rm rom`):

1. **Real build.** The normal `make modern` build produced ROM SHA1
   `466dcdee6ad8e38a2cf530bec29f8a079d1106c5` (same as `client/addresses.lua`).
   Disassembly of that ELF confirms, in code the game itself runs:
   `GetPlayerFacingDirection` (`ldrb [gPlayerAvatar, #5]`, stride 36,
   `ldrb [obj, #24]`, `lsls #28; lsrs #28`), `PlayerGetDestCoords`
   (`ldrsh` at `#16` and `#18`), `GetCurrentMapType` (`ldrsb` at `#4`, byte at
   `#5` of `[gSaveBlock1Ptr]`), `InitLocalLinkPlayer` (`ldrh` at `#10` and
   `#12`, `ldrb` at `#8` of `[gSaveBlock2Ptr]`) and `CB1_Overworld` (`ldr [gMain,
   #4]` compared with the `CB2_Overworld` symbol value).
2. **`offsetof` scratch build.** A scratch C file including the decomp headers,
   compiled with the exact `make modern` flags
   (`-mthumb -mthumb-interwork -O2 -mabi=apcs-gnu -mtune=arm7tdmi -march=armv4t
   -fno-toplevel-reorder`), `_Static_assert`s every byte offset and size above.
   Bitfields were probed by initializing a constant struct with only that field
   set to all ones and dumping its bytes: `facingDirection` → byte `0x18` =
   `0x0F`.
3. **DWARF.** A `make modern DINFO=1` build (adds only `-g`) dumped with
   `readelf --debug-dump=info` gives the same layouts, e.g.
   `Main.callback2` offset 4,
   `SaveBlock2.playerTrainerId` offset 10. Note: this debug build's ROM SHA1
   differs from the normal build, so step 1, not this one, is the reference for
   the shipped ROM; struct layout does not depend on `-g`.

[load_save-41]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/load_save.c#L41
[load_save-70]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/load_save.c#L70-L82
[load_save-84]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/load_save.c#L84-L119
[battle_main-590]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/battle_main.c#L590
[overworld-2071]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L2071-L2075
[overworld-1459]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1459-L1463
[overworld-1484]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1484-L1492
[overworld-1572]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1572-L1580
[overworld-1577]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1577
[overworld-1582]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1582-L1588
[transition-1026]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/battle_transition.c#L1026-L1030
[avatar-37]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/field_player_avatar.c#L37-L38
[avatar-1141]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/field_player_avatar.c#L1141-L1145
[avatar-1182]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/field_player_avatar.c#L1182-L1185
[link-326]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/link.c#L326
[global-174]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L174-L178
[global-508]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L508
[global-511]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L511
[global-513]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L513
[global-544]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L544
[global-581]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L581-L588
[global-984]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L984
[global-987]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L987
[global-1081]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L1081
[fieldmap-194]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.fieldmap.h#L194-L255
[fieldmap-235]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.fieldmap.h#L235
[fieldmap-237]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.fieldmap.h#L237-L243
[fieldmap-342]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.fieldmap.h#L342
[fieldmap-349]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.fieldmap.h#L349
[fieldmap-371]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.fieldmap.h#L371-L374
[fieldmap_h-18]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/fieldmap.h#L18
[const-46]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/constants/global.h#L46
[const-81]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/constants/global.h#L81
[const-113]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/constants/global.h#L113-L114
[const-138]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/constants/global.h#L138-L141
[maps-12]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/constants/maps.h#L12
[play_time-11]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/play_time.c#L4-L11
[play_time-31]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/play_time.c#L31-L34
[main-437]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/main.c#L428-L438
[main-89]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/main.c#L89-L169
[main-252]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/main.c#L250-L253
[camera-414]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/field_camera.c#L360-L420
[new_game-165]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/new_game.c#L165
[overworld-1539]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1532-L1540
[overworld-1735]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1705-L1736
[main-10]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/main.h#L10
[main-11]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/main.h#L11

## Mailbox

From milestone 0.4 the ROM and the Lua client exchange messages through
**`gCoopMailbox`**, a 1034-byte (`0x40A`) struct in EWRAM. Its address is
`symbols["gCoopMailbox"].addr` from `client/addresses.lua`; the design is in
[architecture.md](architecture.md#lua-and-rom-mailbox-04-onward). The layout below
is a binary contract between the ROM and Lua. It is defined in
[`include/coop/mailbox.h`][mailbox_h] and locked by `STATIC_ASSERT`s in
[`src/coop/mailbox.c`][mailbox_c]: a ROM build fails if the struct drifts from
this table. Any change bumps `layoutVersion` and must update this section in the
same pull request.

Every field is a single byte or a byte array, so the struct has no padding and
no multi-byte integers: endianness and alignment never matter.

### Header and rings

Offsets are from `gCoopMailbox`.

| Offset | Size | Field | Written by | Meaning |
| --- | --- | --- | --- | --- |
| `0x000` | 4 | `magic` | ROM | ASCII `C` `O` `O` `P` (`43 4F 4F 50`), no terminator. Written last by `CoopMailbox_Init`, so a valid magic means the header is ready. |
| `0x004` | 1 | `layoutVersion` | ROM | `2` (v1.5 onward; `1` in v1.0). Lua must refuse to use a mailbox with another version. |
| `0x005` | 1 | `flags` | both, see below | Bit 0 `lua_connected`, bit 1 `rom_ready`, bits 2–7 reserved (0). |
| `0x006` | 1 | `outbound.head` | ROM | Next outbound slot the ROM fills (0–15). |
| `0x007` | 1 | `outbound.tail` | Lua | Next outbound slot Lua reads (0–15). |
| `0x008` | 512 | `outbound.slots[16]` | ROM | 16 slots × 32 bytes; slot `i` is at `0x008 + i * 0x20`. |
| `0x208` | 1 | `inbound.head` | Lua | Next inbound slot Lua fills (0–15). |
| `0x209` | 1 | `inbound.tail` | ROM | Next inbound slot the ROM reads (0–15). |
| `0x20A` | 512 | `inbound.slots[16]` | Lua | 16 slots × 32 bytes; slot `i` is at `0x20A + i * 0x20`. |

`flags` bits:

| Bit | Mask | Name | Owner | Meaning |
| --- | --- | --- | --- | --- |
| 0 | `0x01` | `lua_connected` | Lua | Set after a server `welcome` while the authenticated socket and mailbox are valid; cleared on disconnect or stop. Read by `CoopMailbox_IsLuaConnected()`. |
| 1 | `0x02` | `rom_ready` | ROM | Set by `CoopMailbox_Init()` at boot. |

Lua must change only its own bit, with a read-modify-write of the `flags` byte
that keeps `rom_ready` intact.

### Slot

Each slot is 32 bytes (`0x20`). Offsets are from the start of the slot.

| Offset | Size | Field | Meaning |
| --- | --- | --- | --- |
| `0x00` | 1 | `type` | Message type, see [Message types](#message-types). |
| `0x01` | 1 | `length` | Number of valid payload bytes, 0–30. |
| `0x02` | 30 | `payload` | Message bytes. The ROM zero-fills the bytes after `length` in outbound slots. |

A single-slot message carries up to 30 bytes. Larger messages are split into
several `COOP_MSG_FRAGMENT` slots; see [Multi-slot messages](#multi-slot-messages).

### Message types

[`include/constants/coop.h`][coop_constants_h] is the source of truth. The Lua
client mirrors these values; never renumber one.

| Value | Constant | Direction | Payload |
| --- | --- | --- | --- |
| `0` | `COOP_MSG_NONE` | none | Reserved: never sent. |
| `1` | `COOP_MSG_PRESENCE` | both | See [Presence payload](#presence-payload). |
| `2` | `COOP_MSG_LEAVE` | inbound | 1 byte: the remote slot (`0`–`3`) to free. See [Remote slots](#remote-slots). |
| `3` | `COOP_MSG_FRAGMENT` | both | One slot of a multi-slot message (layout v2). See [Multi-slot messages](#multi-slot-messages). |
| `4` | `COOP_MSG_DEBUG_ECHO` | both | Debug, sent as a multi-slot message: the ROM sends a received one back unchanged. Used by `client/debug/echo.lua`. |
| `5` | `COOP_MSG_LINK_SPIKE` | both | Temporary opt-in #80 virtual-link experiment; see [contract and limits](virtual-link-spike.md#temporary-mailbox-contract). The normal bridge ignores it. |
| `6` | `COOP_MSG_SPIKE_TRACE` | outbound | Temporary #80 local trace: stage `u8`, value little-endian `u16`. Never forwarded to the server. |

### Presence payload

`COOP_MSG_PRESENCE` carries one player's presence. Unlike the header, the
payload has multi-byte integers: they are **little-endian** and may be
unaligned inside the slot, so the ROM must copy them byte by byte (or with
`memcpy`), never through a `u16`/`u32` pointer. Offsets are from the start of
`payload` (slot offset `0x02`).

| Offset | Size, type | Field | Meaning |
| --- | --- | --- | --- |
| `0x00` | 1, `u8` | `mapGroup` | Same value as [`mapGroup`](#fields). |
| `0x01` | 1, `u8` | `mapNum` | Same value as [`mapNum`](#fields). |
| `0x02` | 2, `s16` | `x` | Map coordinate, `currentCoords.x − MAP_OFFSET`. |
| `0x04` | 2, `s16` | `y` | Map coordinate, `currentCoords.y − MAP_OFFSET`. |
| `0x06` | 1, `u8` | `facing` | `DIR_*`: `1` south, `2` north, `3` west, `4` east. |
| `0x07` | 1, `u8` | `visible` | `1` visible, `0` hidden. |
| `0x08` | 1, `u8` | `gender` | `0` `MALE`, `1` `FEMALE`. |
| `0x09` | 4, `u32` | `trainerId` | 32-bit trainer ID, as [`trainerId`](#fields). |
| `0x0D` | 1, `u8` | `slot` | **Inbound only.** Remote player slot `0`–`3`; Lua maps each `playerId` to a slot ([#25](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/25)). |

`length` is **13** (`0x0D`) outbound, ROM to Lua, and **14** (`0x0E`) inbound,
Lua to ROM. A reader must reject a payload shorter than 13 bytes and ignore
bytes it doesn't know past the ones above, so a later field can be appended
without breaking older readers.

The outbound C definition is `struct CoopPresence` in
`rom/include/coop/presence.h` (#24), with size and offset assertions in
`rom/src/coop/presence.c`. [Local publishing](local-presence.md) now implements
this layout: `visible` is true only in controllable overworld play. A hidden
transition retains the last complete tuple rather than reading a loading map.
The bridge consumes this mailbox payload for the local panel. Outgoing JSON
maps each valid tuple to `visible = true`, preserving protocol v1's running-
session semantics without struct reads; reset closes the socket instead.
Incoming network visibility is copied unchanged. See the explicit
[bridge mapping](mailbox-bridge.md#lifecycle-and-visibility).

### Remote slots

The ROM keeps a table of **4 remote slots** (`COOP_REMOTE_SLOTS` in
[`include/coop/remote_players.h`][remote_players_h]). Lua owns the mapping from
the server's `playerId` to a slot: it picks a free slot for a new player, writes
that slot into every inbound `PRESENCE` for the player (payload offset `0x0D`),
and sends `COOP_MSG_LEAVE` with the slot when the player leaves, so the slot can
be reused. The ROM
([`src/coop/remote_players.c`][remote_players_c], issue
[#25](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/25)):

- stores the latest `PRESENCE` per slot, and ignores an inbound `PRESENCE`
  shorter than 14 bytes or with a slot above 3, and a `LEAVE` with a slot above
  3;
- draws slot `n` as the object event with local ID `228 + n` while the slot is
  used, `visible` is `1`, the slot's map equals the local map and
  `lua_connected` is set; otherwise it removes that object;
- removes every remote object, **forgets every slot** and **discards every
  queued inbound message** (by popping them, so only the ROM's `inbound.tail`
  moves) on each overworld frame while `lua_connected` is clear. The bridge
  waits for this old queue to empty, sets `lua_connected` **before** pushing
  the new session's messages, clears all four previous slots with `LEAVE`,
  then sends `PRESENCE` for every current player. Anything pushed while the
  bit is clear may be dropped. A menu/battle delays this handoff until the
  ROM resumes its consumer;
- drains the inbound ring only while the overworld runs (`CB1_Overworld` with
  `callback2 == CB2_Overworld`). During battles, full-screen menus and map
  loads the ring is not read and can fill up, and Lua's writes are then
  dropped. Lua should keep the latest presence of each player and send it again
  once the ring has room, instead of relying on every message arriving.

Busy maps: a remote player is spawned only while at least 2 of the 16 object
event slots stay free afterwards, only when its tile is in view, and never
while a script, the start menu or battle setup holds the field. A remote that
walks out of view is removed by the ROM as soon as its step ends (the game's
own culling keeps objects whose spawn tile is still in view), and is spawned
again when its tile is back in view. When object
event or sprite slots run out it is simply not drawn and is retried every frame:
nothing crashes, and map NPCs keep priority. Full behavior and the reasons are
in [remote-player-design.md](remote-player-design.md).

### Ring rules

Each ring has **one writer and one reader**. The ROM writes only
`outbound.head` and `inbound.tail`; Lua writes only `outbound.tail` and
`inbound.head`. No locks are needed.

- **Write:** if `(head + 1) % 16 == tail` the ring is full and the message is
  dropped. Otherwise fill `slots[head]` completely, **then** set
  `head = (head + 1) % 16`.
- **Read:** if `tail == head` the ring is empty. Otherwise copy `slots[tail]`,
  **then** set `tail = (tail + 1) % 16`.
- A ring therefore holds at most **15** messages.

Lua runs between frames, but mGBA's frame callback can fire while the game is in
the middle of a mailbox call. The ordering above is what keeps that safe: the
ROM uses a compiler barrier so it never moves a slot write after its `head`
update, and Lua must keep the same order (slot first, index last). The ROM
clamps an inbound `length` above 30 to 30.

`CoopMailbox_Init()` runs once per boot, from `AgbMain` before the main loop,
including after a soft reset. It zeroes the whole mailbox (both rings empty,
`lua_connected` cleared) and then writes the header. A Lua client that sees
`rom_ready` drop or the magic disappear must treat the mailbox as reset.

The main bridge also detects an initialization that finishes entirely between
frame callbacks, including while disconnected or awaiting reconnect handoff.
It opts into a Lua-local reset watch: the final four payload bytes of the
**next unpublished inbound slot** hold `LUA!`. That slot is always free under
the existing ring rules and belongs to Lua. The marker never advances an
index, publishes a message or reserves extra capacity; the ROM cannot consume
it. Before publishing a normal push, Lua writes the actual zero-padded payload
and moves the marker to the next free slot. Full/invalid pushes do not move it.

`CoopMailbox_Init` zeroes the marker, even if the header and every observed
index already have their pre-reset values and `lua_connected` was already
clear. Losing the marker invalidates cached identity/position and the socket;
the bridge waits for a fresh ROM tuple before rejoining. This uses only
existing Lua-owned slot storage: no struct/flag/layout/version or ROM change.
Only one Lua writer/reader may attach to each ring, as before.

### Multi-slot messages

Layout **v2** ([issue #77](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/77))
adds messages longer than one slot, such as a 600-byte party for trading. The
header, rings and slot bytes are the same as in v1; v2 adds the fragment
format below, and the version bump makes a v1 client and a v2 ROM refuse each
other in `check()` (`mailbox layout version mismatch: ROM has 1, client
expects 2`).

A message of **1 to 1024 bytes** (`COOP_MAILBOX_MESSAGE_MAX`) travels as
consecutive `COOP_MSG_FRAGMENT` slots. Each fragment's payload is a 4-byte
header and up to **26** data bytes (`COOP_FRAGMENT_DATA_SIZE`). Offsets are
from the start of `payload` (slot offset `0x02`):

| Offset | Size, type | Field | Meaning |
| --- | --- | --- | --- |
| `0x00` | 1, `u8` | `type` | Type of the whole message, `COOP_MSG_*`. Never `0` or `COOP_MSG_FRAGMENT`. |
| `0x01` | 1, `u8` | `index` | Fragment index, `0` for the first. Fragment `i` carries message bytes `i × 26` onward. |
| `0x02` | 2, `u16` | `totalLength` | Length of the whole message, little-endian, `1`–`1024`. The same in every fragment. |
| `0x04` | 1–26 | `data` | Message bytes. Every fragment but the last carries exactly 26. |

The slot `length` is `4 +` the data size. A message of `n` bytes takes
`ceil(n / 26)` fragments: 600 bytes take 24, more than the 15 slots a ring
holds. Example: a 2-byte `COOP_MSG_DEBUG_ECHO` message `41 42` is one slot
with type `03`, length `06` and payload `04 00 02 00 41 42`.

**Sender** (one multi-slot message in flight per ring):

- Push fragments in index order, with the normal ring rules. When the ring is
  full, stop and push the **same** fragment again on a later frame: never drop
  a fragment. This streams a message larger than the ring while the reader
  drains it.
- Single-slot messages (`PRESENCE`, `LEAVE`) may be pushed between two
  fragments; they are unchanged from v1. Both sides push presence before the
  frame's fragments.
- To abandon a message, just stop. The ROM abandons the outbound message when
  `lua_connected` is clear; Lua drops its queue on disconnect, reset and
  `welcome`.

**Receiver:**

- Fragment `0` always starts a new message, dropping any incomplete one.
- A later fragment is accepted only if it continues the message in progress:
  the next `index`, the same `type` and `totalLength`, and the expected size.
  Anything else drops the incomplete message, and following fragments are
  dropped until the next fragment `0`.
- When the collected bytes reach `totalLength`, the message is delivered. An
  incomplete message is never delivered and never blocks later messages.
- A disconnect (ROM: `lua_connected` clear; Lua: disconnect or reset) and
  `CoopMailbox_Init` drop the incomplete message.

ROM side ([`src/coop/mailbox.c`][mailbox_c]): `CoopMailbox_SendMessage` copies
the message and pushes its first fragments; `CoopMailbox_PumpOutbound`, called
from `CoopOverworld_Update` after presence on every `CB1_Overworld` frame,
pushes the rest. `CoopMailbox_Receive` returns single-slot and reassembled
messages; `CoopRemote_Update` reads the inbound ring with it, so inbound
messages are read only while the overworld runs, as before. Code that
exchanges multi-slot messages outside the overworld (trading, #80/#81) must
call the pump and the receiver itself. The ROM keeps one 1024-byte buffer per
direction in EWRAM. Lua side: [`client/lib/fragments.lua`](../client/lib/fragments.lua).

### C API

Declared in [`include/coop/mailbox.h`][mailbox_h]:

| Function | Ring | Behavior |
| --- | --- | --- |
| `void CoopMailbox_Init(void)` | both | Zeroes the mailbox, sets `layoutVersion`, `rom_ready` and the magic, and forgets any multi-slot message. |
| `bool8 CoopMailbox_Push(u8 type, const void *payload, u8 len)` | outbound | Queues one message. Returns `FALSE` and writes nothing if the ring is full or `len > 30`. |
| `bool8 CoopMailbox_Pop(struct CoopMailboxSlot *msg)` | inbound | Copies the oldest slot to `*msg` and frees it. Returns `FALSE` if the ring is empty. |
| `bool8 CoopMailbox_IsLuaConnected(void)` | header | `TRUE` while `lua_connected` is set. |
| `bool8 CoopMailbox_SendMessage(u8 type, const void *data, u16 len)` | outbound | Starts a [multi-slot message](#multi-slot-messages) of 1–1024 bytes: copies it and pushes the first fragments. `FALSE` if one is still being sent, Lua isn't connected, or the type or length is invalid. |
| `void CoopMailbox_PumpOutbound(void)` | outbound | Pushes more fragments while the ring has room. Abandons the message if `lua_connected` is clear. Call once per frame. |
| `bool8 CoopMailbox_IsSending(void)` | outbound | `TRUE` while a multi-slot message is still being sent. |
| `bool8 CoopMailbox_Receive(struct CoopMessage *msg)` | inbound | Returns the next complete message, single-slot or reassembled, as `type`, `length` and a `data` pointer valid until the next call. Pops at most 16 slots per call; `FALSE` when no complete message is waiting. |
| `void CoopMailbox_DiscardInbound(void)` | inbound | Pops every waiting slot and drops the incomplete multi-slot message. |

### Lua API

[`client/lib/mailbox.lua`](../client/lib/mailbox.lua) is the Lua side. It only
touches memory through the object it is given (`read8` / `write8`, which is
mGBA's `emu` in the emulator and a table in tests), with the base address
`symbols["gCoopMailbox"].addr`.

| Function | Ring | Behavior |
| --- | --- | --- |
| `Mailbox.new(mem, baseAddr)` | none | Wraps the mailbox. Reads nothing. |
| `:check()` | header | Returns `true, message`, or `false, message` if the magic, `layoutVersion` or `rom_ready` is wrong. |
| `:setLuaConnected(bool)` | header | Sets or clears `lua_connected`, keeping the other bits. |
| `:isLuaConnected()` | header | Reads the Lua-owned bit, allowing the bridge to detect a mailbox reset between frame checks. |
| `:isInboundEmpty()` | inbound indices, read only | Returns whether the ROM has consumed/discarded the queue; false plus a reason on invalid indices. Used for reconnect handoff, never writes the ROM-owned tail. |
| `:watchReset()` | next unpublished inbound slot | Arms the local reset marker after a successful header check. Returns true, or false and a reason on invalid indices. Does not publish anything. |
| `:wasReset()` | watched inbound slot, read only | Returns true if an armed marker was lost, independently of connection state. Returns false before opting in. |
| `:pop()` | outbound | Returns `{type, payload}` (payload as a byte string) or `nil` when empty, then advances `outbound.tail`. |
| `:push(type, payload)` | inbound | Fills the slot (zero-padded), moves an armed local reset marker to the next free slot, then advances `inbound.head`. Returns `false, reason` if the ring is full, `type` is not 1–255 or the payload is over 30 bytes. |
| `encodePresence(t)` / `decodePresence(bytes)` | none | Convert between a [presence payload](#presence-payload) and a table; `slot` is present only in the 14-byte form. Return `nil, error` on bad input. |

Both ring calls read `head` and `tail` from memory every time and return an
error if either is above 15, so a reset mailbox is never read with stale
indices.

[`client/lib/fragments.lua`](../client/lib/fragments.lua) splits and
reassembles [multi-slot messages](#multi-slot-messages). It only builds and
reads byte strings, so it is pure.

| Function | Behavior |
| --- | --- |
| `split(type, data)` | Returns the list of fragment payloads for one message, or `nil, error` for a bad type or a length outside 1–1024. |
| `newReassembler()` | `:feed(payload)` takes one `COOP_MSG_FRAGMENT` payload and returns `type, data` when it completes a message, `nil` when more are needed, and a third value, the reason, when it dropped an incomplete message or a bad fragment. `:reset()` drops the message in progress. |
| `newSender()` | `:send(type, data)` queues a message (up to 16). `:pump(push)` calls `push(payload)` for the next fragments, in order, until it returns false (ring full; that fragment is retried next time). `:clear()` drops everything; `:isIdle()`. |

The [mailbox bridge](mailbox-bridge.md) uses both: it reassembles outbound
fragments and hands complete messages to its `onMessage` handler, and
`sendMessage(type, data)` streams one to the ROM after the frame's presence.

[mailbox_h]: https://github.com/BDL-Ltda/pokeemerald/blob/015a5a04b3fc3e0d74dff9c8e5fcdbc008d3c5e3/include/coop/mailbox.h
[mailbox_c]: https://github.com/BDL-Ltda/pokeemerald/blob/015a5a04b3fc3e0d74dff9c8e5fcdbc008d3c5e3/src/coop/mailbox.c
[coop_constants_h]: https://github.com/BDL-Ltda/pokeemerald/blob/015a5a04b3fc3e0d74dff9c8e5fcdbc008d3c5e3/include/constants/coop.h
[remote_players_h]: https://github.com/BDL-Ltda/pokeemerald/blob/ef2bb7b7808447af7536ef22d08acfbea1456a38/include/coop/remote_players.h
[remote_players_c]: https://github.com/BDL-Ltda/pokeemerald/blob/015a5a04b3fc3e0d74dff9c8e5fcdbc008d3c5e3/src/coop/remote_players.c

## Pokemon bytes in the trade log

The v2 `trade_confirm.pokemon` field is a hex-encoded, **100-byte**
`struct Pokemon`, copied as stored in GBA memory. The server decodes only enough
to label its [audit record](server.md#trade-confirmation-audit-log); it preserves
the exact original string and does not change/reject gameplay data.

Source revision: `662300386fae6899c8f4fea4504f2d9d4303c94c`, re-verified at
ROM pin `015a5a04b3fc3e0d74dff9c8e5fcdbc008d3c5e3`. The Pokemon structs,
decoding code and species sources below are unchanged between those revisions.
The contract is defined by
[`PokemonSubstruct0`, `BoxPokemon` and `Pokemon`](https://github.com/BDL-Ltda/pokeemerald/blob/662300386fae6899c8f4fea4504f2d9d4303c94c/include/pokemon.h#L110),
[`DecryptBoxMon` and `GetSubstruct`](https://github.com/BDL-Ltda/pokeemerald/blob/662300386fae6899c8f4fea4504f2d9d4303c94c/src/pokemon.c#L3536).
These are **offsets inside the supplied bytes**, not live global addresses:

| Offset | Size | Field |
| --- | --- | --- |
| `0x00` | 4 | Personality, little-endian `u32`. |
| `0x04` | 4 | Original trainer ID, little-endian `u32`. |
| `0x1C` | 2 | Checksum, little-endian `u16`. |
| `0x20` | 48 | Encrypted secure area: four 12-byte substructures. |
| `0x50` | 20 | Party stats; not needed for species. |

Decrypt every secure `u32` with XOR of personality and original trainer ID.
Sum its 24 decrypted `u16`s modulo 65536 and compare to the checksum. The
Growth substructure's physical block is selected by `GetSubstruct`'s first
column for `personality % 24`:

```text
0 0 0 0 0 0 1 1 2 3 2 3 1 1 2 3 2 3 1 1 2 3 2 3
```

The species is the first little-endian `u16` of that decrypted block. Internal
IDs are **not** national Pokedex numbers (Treecko is 277). The generated server
name table comes from
[`species.h`](https://github.com/BDL-Ltda/pokeemerald/blob/662300386fae6899c8f4fea4504f2d9d4303c94c/include/constants/species.h)
and [`species_names.h`](https://github.com/BDL-Ltda/pokeemerald/blob/662300386fae6899c8f4fea4504f2d9d4303c94c/src/data/text/species_names.h).
Placeholder names use their constant labels; `SPECIES_EGG` is labeled `EGG`.
An actual egg's Growth species still names its underlying Pokemon.

`internal/tradelog/generate.go` regenerates the static table from the pinned
submodule (`go generate ./internal/tradelog`). The server binary needs no ROM,
source checkout or external data files. Tests use synthetic encrypted records
for all 24 permutations, never extracted saves. If this byte contract changes,
update its documentation, decoder and generated names together.
