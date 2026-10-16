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
[`cmd/symgen/symbols.txt`](../cmd/symgen/symbols.txt). The allowlist names global
data objects, plus the few functions the client compares with function pointers
stored in RAM (see [Visible signal](#visible-signal)). Later issues can extend it
as needed, for example when `gCoopMailbox` is introduced.

See [Generating client addresses](../README.md#generating-client-addresses) for
the command, required build inputs, validation, map verification and regeneration
rules. Never hand-write or guess global addresses, or edit the generated module.
Update this document if the memory layout changes. Client runtime integration is
still planned in
[issue #10](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/10).

## Player state

These are the fields the client reads for `hello` and `presence` (see
[protocol.md](protocol.md)) during milestones 0.1 to 0.3. `NAME` in a path means
`symbols["NAME"].addr` from `client/addresses.lua`; `[ptr]` means "read the
32-bit pointer stored there". The GBA is **little-endian**.

Decomp links point at our fork at the pinned submodule commit
[`731ad5b`](https://github.com/DaviAlencastro/pokeemerald/tree/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881).
**When the submodule pointer moves, re-verify this section** (see
[How the offsets were verified](#how-the-offsets-were-verified)) and update the
links.

### Save blocks move: always dereference

`gSaveBlock1Ptr` and `gSaveBlock2Ptr` are pointers, and the blocks they point at
**move**. [`SetSaveBlocksPointers`][load_save-70] adds a random offset every time
it runs, and [`MoveSaveBlocks_ResetHeap`][load_save-84] copies both blocks to the
new place. It runs on every map load
([`ResetMirageTowerAndSaveBlockPtrs`][overworld-2071]), at the start of every
battle ([battle_main.c][battle_main-590]), and when a game is loaded.

So read `gSaveBlock1Ptr` / `gSaveBlock2Ptr` **again on every read** and add the
field offset to the value you just read. Never cache the pointer or a derived
address across frames. The move happens inside a single frame, so a read done
from a frame callback always sees a consistent pointer and block.

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

`visible` ([protocol.md](protocol.md)) must be true only while the player is in
the overworld **and controllable**: false in battles, menus, warps and fades
([issue #11](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/11)). Proposed
signal, all four conditions read every frame:

```text
visible = [gMain + 0x000] == CB1_Overworld   -- gMain.callback1, u32 function pointer
      and [gMain + 0x004] == CB2_Overworld   -- gMain.callback2, u32 function pointer
      and u8 [sLockFieldControls] == 0       -- bool8
      and (u8 [gPaletteFade + 0x07] & 0x80) == 0   -- gPaletteFade.active, bit 7 of byte 7
```

| Value | Offset (from) | Size, type | Source |
| --- | --- | --- | --- |
| `gMain.callback1` | `0x000` (`struct Main`) | 4 bytes, function pointer | [main.h:10][main-10] |
| `gMain.callback2` | `0x004` (`struct Main`) | 4 bytes, function pointer | [main.h:11][main-11] |
| `sLockFieldControls` | the symbol itself | 1 byte, `bool8` | [script.c:28][script-28] (file `static`; it is still in the ELF symbol table) |
| `gPaletteFade.active` | byte `0x07`, **bit 7** (`struct PaletteFadeControl`) | 1-bit bitfield | [palette.h:42][palette-42] |

Compare the callback pointers with `symbols["CB1_Overworld"].addr` and
`symbols["CB2_Overworld"].addr` as exported, **without** clearing bit 0. Both
are Thumb functions, so the ELF value is odd, and the game stores that same odd
value: the literal `CB1_Overworld` loads to compare with `gMain.callback2` is
exactly the exported `CB2_Overworld` value, odd bit included.

Why each condition:

1. **`callback2 == CB2_Overworld`**: the field's main loop
   ([overworld.c:1484][overworld-1484]). Every full-screen mode replaces it:
   battles ([`BattleTransition_StartOnField`][transition-1026] switches to
   `CB2_OverworldBasic` as soon as the battle transition starts, then the battle
   sets its own), the bag, party, Pokédex and other start-menu screens, map loads
   ([`CB2_LoadMap`][overworld-1572] switches to `CB2_DoChangeMap`), and the title
   screen and intro.
2. **`callback1 == CB1_Overworld`**: the field input handler
   ([overworld.c:1459][overworld-1459]), restored together with `callback2` when
   the overworld is entered ([overworld.c:1582][overworld-1582]). It is `NULL`
   during map loads ([overworld.c:1577][overworld-1577]) and `CB1_OverworldLink`
   in link/cable-club rooms, where the player is driven by the link and not by us.
3. **`sLockFieldControls == 0`**: [`DoCB1_Overworld`][overworld-1438] only
   processes player input when controls are unlocked. The game locks them for the
   start menu ([start_menu.c:590][start_menu-590]), for every warp
   ([`DoWarp`][screen_effect-484] and the warp-exit fade-in,
   [`FieldCB_DefaultWarpExit`][screen_effect-273]), at the start of wild battles
   ([battle_setup.c:404][battle_setup-404]), and for every script (NPC talk,
   signs, cutscenes). This catches menus and warps that keep `CB2_Overworld`
   running. Lock / unlock: [script.c:182][script-182].
4. **`gPaletteFade.active == 0`**: a safety net for fades that happen without a
   control lock. `CB2_Overworld` itself checks this flag
   ([overworld.c:1486][overworld-1486]).

Consequence to keep in mind: `visible` also goes false while the player talks to
an NPC or reads a sign (controls are locked). That matches "controllable"; if
#11 finds it too flickery, drop condition 3 and rely on 1, 2 and 4, at the cost of
the start menu staying visible.

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
   `0x0F`; `gPaletteFade.active` → byte `0x07` = `0x80`.
3. **DWARF.** A `make modern DINFO=1` build (adds only `-g`) dumped with
   `readelf --debug-dump=info` gives the same layouts, e.g.
   `PaletteFadeControl.active` `data_bit_offset=63`, `Main.callback2` offset 4,
   `SaveBlock2.playerTrainerId` offset 10. Note: this debug build's ROM SHA1
   differs from the normal build, so step 1, not this one, is the reference for
   the shipped ROM; struct layout does not depend on `-g`.

[load_save-41]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/load_save.c#L41
[load_save-70]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/load_save.c#L70-L82
[load_save-84]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/load_save.c#L84-L119
[battle_main-590]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/battle_main.c#L590
[overworld-2071]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L2071-L2075
[overworld-1438]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1438-L1457
[overworld-1459]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1459-L1463
[overworld-1484]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1484-L1492
[overworld-1486]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1486
[overworld-1572]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1572-L1580
[overworld-1577]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1577
[overworld-1582]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c#L1582-L1588
[script-28]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/script.c#L28
[script-182]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/script.c#L182-L195
[start_menu-590]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/start_menu.c#L590
[screen_effect-273]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/field_screen_effect.c#L273-L279
[screen_effect-484]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/field_screen_effect.c#L484-L488
[battle_setup-404]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/battle_setup.c#L402-L404
[transition-1026]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/battle_transition.c#L1026-L1030
[avatar-37]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/field_player_avatar.c#L37-L38
[avatar-1141]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/field_player_avatar.c#L1141-L1145
[avatar-1182]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/field_player_avatar.c#L1182-L1185
[link-326]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/link.c#L326
[global-174]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L174-L178
[global-508]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L508
[global-511]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L511
[global-513]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L513
[global-544]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L544
[global-581]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L581-L588
[global-984]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L984
[global-987]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L987
[global-1081]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.h#L1081
[fieldmap-194]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.fieldmap.h#L194-L255
[fieldmap-235]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.fieldmap.h#L235
[fieldmap-237]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.fieldmap.h#L237-L243
[fieldmap-342]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.fieldmap.h#L342
[fieldmap-349]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.fieldmap.h#L349
[fieldmap-371]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/global.fieldmap.h#L371-L374
[fieldmap_h-18]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/fieldmap.h#L18
[const-46]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/constants/global.h#L46
[const-81]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/constants/global.h#L81
[const-113]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/constants/global.h#L113-L114
[const-138]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/constants/global.h#L138-L141
[maps-12]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/constants/maps.h#L12
[main-10]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/main.h#L10
[main-11]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/main.h#L11
[palette-42]: https://github.com/DaviAlencastro/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/palette.h#L35-L55

## Future layouts

The 0.4+ **`gCoopMailbox`** design is recorded in [architecture.md](architecture.md). Its exact memory layout will be documented here when implemented; the planned header and two 16-slot rings do not establish offsets or a binary contract yet.
