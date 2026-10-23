# Remote player design (0.4)

This is the result of the spike in [#21](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/21).
It explains how the ROM shows remote players as real overworld characters and
fixes the plan for [#24](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/24)
(publish local presence) and [#25](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/25)
(render remote players). The decisions it builds on are in
[architecture.md](architecture.md) and #21: up to 4 remote slots, the real
Brendan/May avatar, a walk for a one-tile step and a teleport for anything
bigger, no collision, and shown only when the remote player is on the same map,
`visible`, and Lua is connected.

Decomp references point at our fork at the pinned submodule commit
[`731ad5b`][tree]. Function names are given with their file so they can be found
again when the submodule moves.

**Proof:** branch [`spike/21-remote-object-event`][spike] on the fork (throwaway,
never merge it). It spawns one Brendan at tile (10, 12) in Littleroot Town that
paces one tile east and west, and you can walk through it. See
[Proof branch](#proof-branch).

## Summary

- A remote player is a **normal object event** created with
  `SpawnSpecialObjectEventParameterized`, using **reserved local IDs 228–231**
  (one per remote slot) and `MOVEMENT_TYPE_NONE`.
- The co-op module does not trust any cached state. **Every frame it reconciles**
  `gObjectEvents` with the wanted remote state: find each slot's object by local
  ID, spawn it if it is missing and wanted, move it, or remove it. This one rule
  handles camera culling, warps, battles, saves and continue.
- It runs from **`CB1_Overworld`**, right after the player's own input step
  (one line in `src/overworld.c`).
- No collision and no interaction come from **two one-line checks** in
  `src/event_object_movement.c`: `DoesObjectCollideWithObjectAt` and
  `GetObjectEventIdByPosition` skip co-op objects.
- One tile away: `ObjectEventSetHeldMovement(GetWalkNormalMovementAction(dir))`.
  Further: `MoveObjectEventToMapCoords`.
- **Same gender as the local player** uses the player graphics
  (`OBJ_EVENT_GFX_BRENDAN_NORMAL` / `OBJ_EVENT_GFX_MAY_NORMAL`). **Opposite
  gender** must use the rival graphics (`OBJ_EVENT_GFX_RIVAL_*_NORMAL`), or it
  repaints the local player (see [Palettes](#palettes)).

## 1. Spawning at runtime

### The call

[`SpawnSpecialObjectEventParameterized(graphicsId, movementBehavior, localId, x, y, elevation)`][spawn-param]
(`src/event_object_movement.c`) builds an `ObjectEventTemplate` on the stack and
calls `SpawnSpecialObjectEvent` → `TrySpawnObjectEventTemplate` →
`TrySetupObjectEventSprite`. The game uses the same call for the player
(`InitPlayerAvatar` in `src/field_player_avatar.c`), the camera object
(`SpawnCameraObject` in `src/field_specials.c`) and the Berry Blender players.

- `x`, `y` are **`MAP_OFFSET`-adjusted** coordinates (map coordinate + 7), the
  same space as `ObjectEvent.currentCoords`. The function subtracts
  `MAP_OFFSET` itself and `InitObjectEventStateFromTemplate` adds it back.
- The new object gets `mapNum`/`mapGroup` from `gSaveBlock1Ptr->location`.
- `movementBehavior`: use **`MOVEMENT_TYPE_NONE`**. Its callback is empty
  (`movement_type_empty_callback(MovementType_None)`), but the sprite callback
  still runs `UpdateObjectEventCurrentMovement`, so held movements work.
- `elevation`: pass `ELEVATION_DEFAULT` (3). On the first frame,
  `DoGroundEffects_OnSpawn` → `UpdateObjectEventElevationAndPriority` replaces it
  with the tile's elevation, except on multi-level tiles (see
  [Risks](#6-risks)).
- It returns the `gObjectEvents` index, or `OBJECT_EVENTS_COUNT` (16) if there is
  no free object slot or no free sprite (`CreateSprite` returned `MAX_SPRITES`).
  Both cases are safe: the module tries again on a later frame.
- After spawning, call `ObjectEventTurn(obj, facing)` to apply the facing.

### Safe local IDs: 228–231

A local ID identifies an object event for scripts. The values in use
([`include/constants/event_objects.h`][localids] and the `#error` check at the
top of `src/event_object_movement.c`):

| Local ID | Used by |
| --- | --- |
| 0 | `LOCALID_NONE`, "empty" |
| 1–64 | Map object templates: local ID = template index + 1, and `OBJECT_EVENT_TEMPLATES_COUNT` is 64 |
| 127 | `LOCALID_CAMERA` |
| 236–240 | `LOCALID_BERRY_BLENDER_PLAYER_END` minus `MAX_RFU_PLAYERS` (5) Berry Blender players |
| 255 | `LOCALID_PLAYER` |

No other overworld code assigns local IDs (searched: every `localId =`
assignment in `src/` and every `#define LOCALID_* <number>` above 64). Remote
slot `n` (0–3) uses local ID **`228 + n`**: well above the templates, away from
the camera and the Berry Blender range. #25 must keep `#error` checks like the
proof's, so a future change to those constants breaks the build instead of the
game.

Don't use the map-aware lookups (`GetObjectEventIdByLocalIdAndMap`) to find a
remote object. After a seamless route-edge crossing, objects keep the old map's
`mapNum`/`mapGroup`, so those lookups miss and the module would spawn a
duplicate. Search `gObjectEvents` for `active && localId == 228 + n`.

### Why not the link player objects

The game already has remote players for the Cable Club: `gLinkPlayerObjectEvents[4]`
in `src/overworld.c` (`SpawnLinkPlayerObjectEvent`, `CreateLinkPlayerSprite`).
`RemoveObjectEventsOutsideView` and `SpawnObjectEventOnReturnToField` skip
them. They are tied to link mode: they move from `CB1_OverworldLink` key
exchanges, reuse `range` and `singleMovementActive` as gender and direction
fields, and `ResetObjectEvents` clears them on every map load. Reusing them
outside link mode would mean faking link state. Normal object events need less
code and fewer hooks.

## 2. Despawns, map loads and warps

The game removes or rebuilds object events in these places. None of them needs
a hook, as long as the module reconciles every frame.

| Event | What the game does | Decomp | What the module does |
| --- | --- | --- | --- |
| Camera moves one tile | `UpdateObjectEventsForCameraUpdate` → `RemoveObjectEventsOutsideView` removes every non-player object whose `currentCoords` **and** `initialCoords` are outside the view rectangle (camera −2…+17 in x, 0…+16 in y) | `src/event_object_movement.c` | Next frame the slot's object is missing. Respawn it when its target tile is back in view (same rectangle). While it is out of view it uses no object slot, which helps on busy maps. |
| Warp / full map load | `LoadMapInStepsLocal` → `InitObjectEventsLocal` → `ResetObjectEvents` → `ClearAllObjectEvents` wipes all 16 slots | `src/overworld.c` | `CB1_Overworld` doesn't run during the load (it isn't installed). When the field runs again, the module spawns any remote player that is on the new map. |
| Route-edge crossing | Nothing is cleared. `gSaveBlock1Ptr->location` changes, objects keep their old `mapNum`/`mapGroup` and shift by the camera | `CameraMove` in `src/fieldmap.c`, `UpdateObjectEventCoordsForCameraUpdate` | Remote players reported on the old map are no longer "same map", so they are removed. |
| Battle, full-screen menu, return to field | `gObjectEvents` stays in EWRAM. Sprites are destroyed with the field and rebuilt by `ReturnToFieldLocal` → `SpawnObjectEventsOnReturnToField` for every active object | `src/overworld.c`, `src/event_object_movement.c` | Remote objects come back on their own, with their palette reloaded. Movement state is reset (`ResetObjectEventFldEffData`), and the next update continues from there. |
| Save | `CopyPartyAndObjectsToSave` → `SaveObjectEvents` copies all 16 `gObjectEvents` into `gSaveBlock1Ptr->objectEvents`, **including remote players** | `src/save.c`, `src/load_save.c` | Nothing at save time. |
| Continue a saved game | `CB2_ContinueSavedGame` restores the saved objects and the field returns through `SpawnObjectEventsOnReturnToField`, so a **remote player from the saved session reappears** | `src/overworld.c` | On the first overworld frame, every object with a co-op local ID that has no live remote behind it is removed. This is why the module checks `gObjectEvents` every frame and keeps no "spawned" flag. |

Removal: the game's `RemoveObjectEvent` is `static`. **Never call
`RemoveObjectEventByLocalIdAndMap` on a remote object.** It calls
`GetObjectEventFlagIdByObjectEventId`, which looks up the map template, and a
remote player has none: `GetObjectEventTemplateByLocalIdAndMap` returns `NULL`
and the code reads `->flagId` through it, then calls `FlagSet` with that
garbage. The proof copies the two lines of `RemoveObjectEventInternal`
(`active = FALSE`, then `DestroySprite` with a `SpriteFrameImage` sized from the
graphics info). #25 can do the same or add a public wrapper.

## 3. No collision

There is no "ghost" flag on `struct ObjectEvent`. All object-to-object blocking
goes through [`DoesObjectCollideWithObjectAt`][collide], called by
`GetCollisionAtCoords` and `GetCollisionFlagsAtCoords`. Those are used by the
player (`CheckForObjectEventCollision` in `src/field_player_avatar.c`, the bike
in `src/bike.c`), wandering NPCs (the `MovementType_*` step functions) and
trainer sight (`src/trainer_see.c`). The proof adds one condition there:

```c
if (curObject->active && curObject != objectEvent && !CoopSpike_IsRemoteObjectEvent(curObject))
```

Result: the local player, NPCs and trainers' line of sight all pass through
remote players. A remote player's own movement doesn't check collision at all:
held movements (`ObjectEventSetHeldMovement`) and `MoveObjectEventToMapCoords`
don't call `GetCollisionAtCoords`.

**Interaction must be blocked too.** Pressing A in front of an object calls
`GetInteractedObjectEventScript` (`src/field_control_avatar.c`) →
`GetObjectEventScriptPointerByObjectEventId` →
`GetObjectEventScriptPointerByLocalIdAndMap`, which reads `->script` from the
template lookup without checking it. For a remote player that is a `NULL`
dereference, so the game would run a garbage script. The proof skips co-op
objects in [`GetObjectEventIdByPosition`][by-position], the lookup used by the
interaction code, Rock Smash (`src/fldeff_rocksmash.c`), item use
(`src/item_use.c`) and decoration placement (`src/decoration.c`).

Not patched, follow-ups for #25:

- `GetObjectEventIdByXY` (Strength boulder push in `src/field_player_avatar.c`,
  ground effects, `src/shop.c`). Puzzle state is per save, so a remote player
  can stand where the local game has a boulder. Pushing it could then find the
  remote object instead of the boulder. Skip co-op objects there as well.
- `LinkPlayerGetCollision` in `src/overworld.c` reads `gObjectEvents` directly,
  but it only runs in Cable Club link mode, where co-op objects aren't spawned.

These hooks are the only changes outside `src/coop/` and `include/coop/`: one
line each, each calling a function from `coop/`.

## 4. Walking and teleporting

Object coordinates are `MAP_OFFSET`-adjusted. The remote position is in map
coordinates, so add `MAP_OFFSET` to it.

**Walk one tile** (the target is 4-adjacent to `currentCoords`):

```c
ObjectEventClearHeldMovementIfFinished(obj);      // clears a finished step
if (!ObjectEventIsMovementOverridden(obj))        // no step in progress
    ObjectEventSetHeldMovement(obj, GetWalkNormalMovementAction(dir));
```

The walk action (`MOVEMENT_ACTION_WALK_NORMAL_*`, `src/event_object_movement.c`
and `src/data/object_events/movement_action_func_tables.h`) plays the walking
animation, moves the sprite 16 pixels over 16 frames, and updates
`currentCoords` (with `previousCoords` kept as the origin) when the step starts.
It also sets elevation and priority from the map and triggers ground effects
(grass, footprints, puddles). `ObjectEventSetHeldMovement` returns `TRUE` and
does nothing while another movement is active, so check first.
`GetWalkFastMovementAction` (8 frames per tile) and `GetPlayerRunMovementAction`
exist for later.

**Teleport** (any other distance):

```c
MoveObjectEventToMapCoords(obj, x + MAP_OFFSET, y + MAP_OFFSET);
```

It sets current and previous coordinates, places the sprite and calls
`ResetObjectEventFldEffData`, which clears the held movement and re-triggers
ground effects (so elevation updates on the next frame). If the target is out
of view, removing the object is better: it comes back through the respawn path
when the tile is visible.

**Facing:** `ObjectEventTurn(obj, dir)` when not walking (a walk already faces
its direction). Directions are the same `DIR_*` values that `presence` uses
([protocol.md](protocol.md)).

**Backlog:** a walk takes 16 frames and presence arrives whenever the remote
player moves. If they run (8 frames per tile), the next target arrives before
the step ends, is 2 tiles away by the time it can be applied, and becomes a
teleport. For #25 this is fine (running is out of scope). A later version can
queue targets and use `GetWalkFastMovementAction` or the run action.

## 5. Where the code runs

### Per-frame update (#25)

The game loop (`AgbMain` in `src/main.c`) calls `gMain.callback1`, then
`gMain.callback2`, every frame. In the field these are `CB1_Overworld` and
`CB2_Overworld` (`src/overworld.c`):

```c
void CB1_Overworld(void)
{
    if (gMain.callback2 == CB2_Overworld)
        DoCB1_Overworld(gMain.newKeys, gMain.heldKeys);
    CoopOverworld_Update();          // the one added line
}
```

`CoopOverworld_Update` runs the presence part every time and the remote-player
part only when `gMain.callback2 == CB2_Overworld`. (The proof calls its update
inside the `if`, since it has no presence part.)

Why there:

- It runs **only when the field is fully running**: `callback1` is `NULL` during
  map loads and not `CB1_Overworld` in battles and full-screen menus. That is the
  same condition as `positionValid` in [memory-map.md](memory-map.md). Object
  events are never half built when the module touches them.
- It runs **before `CB2_Overworld` → `OverworldBasic` → `AnimateSprites`**, like
  `PlayerStep`. A held movement set here starts on the same frame.
- It still runs while a script holds the controls (`ArePlayerFieldControlsLocked`),
  because `DoCB1_Overworld` only skips input then. The module decides what to do
  during scripts (see [Risks](#6-risks)).
- Cable Club link mode uses `CB1_OverworldLink`, so co-op code never runs there.

### Detecting local changes (#24)

Use the same hook. Each frame, `CoopOverworld_Update` first builds the local
presence snapshot and compares it with the last one pushed:

| Field | Source in the ROM |
| --- | --- |
| `mapGroup`, `mapNum` | `gSaveBlock1Ptr->location` |
| `x`, `y` | `gObjectEvents[gPlayerAvatar.objectEventId].currentCoords` − `MAP_OFFSET` |
| `facing` | `GetPlayerFacingDirection()` (`src/field_player_avatar.c`) |
| `gender` | `gSaveBlock2Ptr->playerGender` |
| `trainerId` | `gSaveBlock2Ptr->playerTrainerId` |

`currentCoords` changes when a step starts, so a remote player starts walking
toward the new tile at about the same time. The update sees the step one frame
late (`AnimateSprites` runs after CB1), which doesn't matter.

**`visible = false`:** every way out of controllable play first passes through
a frame where `CB1_Overworld` still runs but the player can't move:

- Battles: `BattleSetup_*` in `src/battle_setup.c` call
  `LockPlayerFieldControls` and `FreezeObjectEvents` before the transition, and
  `BattleTransition_StartOnField` (`src/battle_transition.c`) then sets
  `callback2 = CB2_OverworldBasic` while `callback1` stays `CB1_Overworld`.
- The start menu (`src/start_menu.c`) locks the controls before it opens.
- Warps, scripts, NPC talk and cutscenes run with the controls locked.

So #24 needs no extra hook. Call the presence part of the update from
`CB1_Overworld` **outside** the `callback2` check (the remote part stays inside
it), and treat the player as visible only when
`gMain.callback2 == CB2_Overworld && !ArePlayerFieldControlsLocked()`. Push
`visible = false` once when that turns false, and the full snapshot again when it
turns true. Map loads set `callback1 = NULL`, but the warp fade before them is
already locked, so the `false` has been sent by then.

This hides a player during NPC talk and menus too. That matches #24's scope
("battle, menu, warp fade, cutscene").

## 6. Risks

### Object slots on busy maps

`gObjectEvents` has 16 entries shared by the player, the camera object (some
cutscenes), every map NPC within the view rectangle, and remote players.
`TrySpawnObjectEvents` gives up silently when slots run out, so a remote player
can take the slot of an NPC that a script then can't find. Most script commands
on a missing object just do nothing, but a cutscene that waits for an NPC's
movement could hang.

Mitigation for #25:

- **Reserve:** spawn a remote player only if at least **2** object slots stay
  free afterwards (`GetFirstInactiveObjectEventId` and a count). Remote players
  are the first thing to go.
- **No spawns while a script runs** (`ArePlayerFieldControlsLocked()`): existing
  remote objects stay and get no new steps (a step already in progress finishes,
  see [Scripted cutscenes](#scripted-cutscenes)). New ones wait.
- Culling helps: a remote player out of view uses no slot.
- `CreateSprite` can also fail (`MAX_SPRITES` = 64, shared with field effects).
  The spawn returns `OBJECT_EVENTS_COUNT` and the module retries.

Graceful degradation, then: some remote players aren't drawn on crowded maps,
and nothing crashes.

### Scripted cutscenes

- `FreezeObjectEvents` (`src/event_object_movement.c`) runs `FreezeObjectEvent`
  on every object except the player when a script, battle or the start menu
  locks the field. It does **not** freeze everything:
  - `FreezeObjectEvent` returns early when `heldMovementActive` is set, without
    setting `frozen` or pausing the sprite animation. A remote player with a
    held movement is skipped, and so is one whose step has finished but not
    been cleared yet (`heldMovementActive` stays set until
    `ObjectEventClearHeldMovementIfFinished`).
  - `UpdateObjectEventCurrentMovement` runs the held action **before** it checks
    `frozen`. So a walk already in progress when the lock starts keeps playing:
    it finishes its 16 frames and ends on the target tile. (`currentCoords`
    already holds that tile, since it changes when the step starts.)
  - Only an idle remote object with no held movement is really frozen.
  - `ObjectEventSetHeldMovement` calls `UnfreezeObjectEvent`, so starting a step
    would also unfreeze a frozen remote player during the scene.

  Rule for #25: **while `ArePlayerFieldControlsLocked()` is true, start no new
  step, turn or teleport, and let a step in progress finish.** Don't cancel it:
  `ObjectEventClearHeldMovement` stops the sprite between two tiles while
  `currentCoords` already names the target, and the next teleport would snap
  it. Call `ObjectEventClearHeldMovementIfFinished` only once the lock ends,
  then apply the latest position as usual (walk if one tile away, otherwise
  teleport). Vanilla NPCs behave the same way: an NPC caught mid-step when a
  script starts also finishes its step. At most 15 frames of remote movement
  play after the lock, which is accepted for v1.
- Validation cases for #25: the lock starts **mid-step** (talk to an NPC, open
  the start menu, and trigger a trainer battle, each while a remote player is
  walking). The step must finish on its target tile, the remote player must not
  move again until the lock ends, and must then catch up to its latest position.
- Scripted movement of the player (`applymovement`) doesn't check collision, so
  remote players never block a cutscene.
- Scripts address objects by local ID 1–64, 127 or 255, never 228–231.
- The camera object (`LOCALID_CAMERA`) shares the player's tile; it is
  invisible and unaffected.

### Palettes

Brendan and May use **different palettes** (`graphics/object_events/palettes/brendan.pal`
and `may.pal` differ) but the same **palette slot**, `PALSLOT_PLAYER` (0).
Spawning `OBJ_EVENT_GFX_MAY_NORMAL` next to a local Brendan loads May's palette
into slot 0 (`LoadPlayerObjectReflectionPalette` in `TrySetupObjectEventSprite`)
and repaints the local player. The game avoids this with the rival graphics,
which use `PALSLOT_NPC_SPECIAL` (10):

| Local player | Remote Brendan | Remote May |
| --- | --- | --- |
| Brendan | `OBJ_EVENT_GFX_BRENDAN_NORMAL` | `OBJ_EVENT_GFX_RIVAL_MAY_NORMAL` |
| May | `OBJ_EVENT_GFX_RIVAL_BRENDAN_NORMAL` | `OBJ_EVENT_GFX_MAY_NORMAL` |

`GetPlayerAvatarGraphicsIdByStateIdAndGender` and
`GetRivalAvatarGraphicsIdByStateIdAndGender` (`src/field_player_avatar.c`) give
these IDs. The rival pictures are the same Brendan/May pictures.

Remaining risk: `PALSLOT_NPC_SPECIAL` holds one palette at a time and 36
graphics use it (the rival, Steven, Wally, ...). When such an NPC is on screen
with an opposite-gender remote player, whichever spawned last sets the colours
of both. Accepted for v1 and worth one manual check in #25 (Littleroot with the
rival present). The real fix belongs with custom sprites.

### Elevation and bridges

Elevation comes from the map tile under the object
(`ObjectEventUpdateElevation`). On multi-level tiles (`ELEVATION_MULTI_LEVEL`,
bridges such as Route 119 and Fortree) the previous elevation is kept, so a
remote player teleported onto a bridge keeps `ELEVATION_DEFAULT` and may draw
over or under it incorrectly. Walking onto the bridge works like it does for
NPCs. Fix later by sending the elevation in `presence`.

### Surfing, biking, diving

Out of scope for v1. What breaks if nothing is done:

- A surfing remote player is drawn as a walking avatar standing on water, with
  no surf blob.
- Biking is faster than a walk, so movement turns into a series of teleports
  (see the backlog note above).
- Underwater maps are separate maps, so that only works when both players dive.
- Later: send the avatar state and pick the graphics from the
  `sPlayerAvatarGfxIds` / `sRivalAvatarGfxIds` tables, which already have
  Mach Bike, Acro Bike and Surfing entries for both genders.

### Other

- Remote players are saved with the game (section 2) and removed on the first
  frame after Continue. The save file then has a co-op object for that one
  frame: harmless, since vanilla code skips objects without templates when it
  loads them.
- Seamless connections: a remote player on a **connected** map in view (for
  example, across the Littleroot / Route 101 edge) is not drawn, since v1 only
  draws same-map players. Showing them needs the map connection offsets.
- The view rectangle used to decide when to respawn must match
  `RemoveObjectEventIfOutsideView`, or a remote player at the edge of the view
  gets spawned and removed again every frame.

## 7. Module layout and functions

All new code lives in `rom/src/coop/` and `rom/include/coop/`. The mailbox
files belong to #22 and aren't touched here.

```text
rom/include/coop/
  mailbox.h            #22: gCoopMailbox, CoopMailbox_Init/Push/Pop/IsLuaConnected
  overworld.h          #24/#25: the hook entry points below
  remote_players.h     #25: remote slot table and object event control
  presence.h           #24: local snapshot and publishing
rom/include/constants/coop.h   #22: COOP_MSG_* (#25 adds COOP_MSG_LEAVE)
rom/src/coop/
  mailbox.c            #22
  overworld.c          #24/#25: CoopOverworld_Update, the vanilla hook targets
  presence.c           #24
  remote_players.c     #25
```

### Hooks in vanilla files (the only edits outside `coop/`)

| File | Function | Line added | Issue |
| --- | --- | --- | --- |
| `src/overworld.c` | `CB1_Overworld` | `CoopOverworld_Update();` (the presence part runs on every call, the remote part only when `callback2 == CB2_Overworld`, see section 5) | #24 (creates it), #25 |
| `src/event_object_movement.c` | `DoesObjectCollideWithObjectAt` | `&& !CoopRemote_IsRemoteObjectEvent(curObject)` | #25 |
| `src/event_object_movement.c` | `GetObjectEventIdByPosition` | `&& !CoopRemote_IsRemoteObjectEvent(&gObjectEvents[i])` | #25 |
| `src/event_object_movement.c` | `GetObjectEventIdByXY` | same | #25 |

### `coop/overworld.h` (#24 creates it, #25 extends it)

```c
// Called from CB1_Overworld every frame while the field is running.
void CoopOverworld_Update(void);
```

`CoopOverworld_Update` calls `CoopPresence_Update()` and then
`CoopRemote_Update()`. Both do nothing until the mailbox is initialized.

### `coop/presence.h` (#24)

```c
void CoopPresence_Update(void);   // build snapshot, push COOP_MSG_PRESENCE if changed
void CoopPresence_Reset(void);    // forget the last pushed snapshot (new session)
```

Internal (`static` in `presence.c`): `BuildLocalPresence(struct CoopPresence *)`,
`PresenceEquals(a, b)`. The payload layout belongs in `memory-map.md` (#22's
"Mailbox" section), not here.

### `coop/remote_players.h` (#25)

```c
#define COOP_REMOTE_SLOTS   4
#define COOP_LOCALID_FIRST  228
#define COOP_LOCALID_LAST   (COOP_LOCALID_FIRST + COOP_REMOTE_SLOTS - 1)

bool8 CoopRemote_IsRemoteObjectEvent(const struct ObjectEvent *objectEvent);
void CoopRemote_Update(void);       // drain inbound ring, then reconcile every slot
void CoopRemote_DespawnAll(void);   // Lua disconnected, new session
```

Internal (`static` in `remote_players.c`):

| Function | Job |
| --- | --- |
| `ApplyMessage(const struct CoopMessage *)` | `COOP_MSG_PRESENCE` → update `sRemotes[slot]`; `COOP_MSG_LEAVE` → clear the slot |
| `IsWanted(slot)` | slot used, `visible`, same `mapGroup`/`mapNum` as `gSaveBlock1Ptr->location`, Lua connected |
| `FindObjectEvent(slot)` | search `gObjectEvents` for `active && localId == COOP_LOCALID_FIRST + slot` |
| `GetGraphicsId(gender)` | player graphics if same gender as local, rival graphics otherwise |
| `TrySpawn(slot)` | target in view, at least 2 free object slots, not in a script → `SpawnSpecialObjectEventParameterized(..., MOVEMENT_TYPE_NONE, localId, x + MAP_OFFSET, y + MAP_OFFSET, ELEVATION_DEFAULT)`, then `ObjectEventTurn` |
| `Despawn(slot)` | `active = FALSE` + `DestroySprite`, never `RemoveObjectEventByLocalIdAndMap` |
| `StepToward(slot, obj)` | skip while a script runs; clear a finished step; adjacent → walk, same tile → turn, else → teleport |
| `IsTileInView(x, y)` | same rectangle as `RemoveObjectEventIfOutsideView` |

Order inside `CoopRemote_Update`: if Lua isn't connected, `CoopRemote_DespawnAll`
and return. Otherwise pop every inbound message, then for each slot:
`IsWanted` → spawn or step; not wanted → despawn. Also remove any object with a
co-op local ID whose slot isn't wanted (that is what cleans up after Continue).

### What #25 needs from the mailbox (#22)

Nothing beyond #22's scope: `CoopMailbox_IsLuaConnected()` (the `lua_connected`
flag) and `CoopMailbox_Pop`. The `PRESENCE` payload Lua writes into the inbound
ring needs a **slot index** (0–3). #25 documents it in `memory-map.md`.

## Open questions

For the reviewers before #24 and #25 start:

1. **Hidden during NPC talk and menus.** Section 5 sends `visible = false`
   whenever the controls are locked, so a player vanishes for others while
   reading a sign or using the start menu. The alternative is to send `false`
   only for battles and warps, which needs per-exit hooks. Is "hidden while
   busy" acceptable for v1?
2. **Held during cutscenes.** Section 6 lets a step in progress finish, then
   starts no new movement while a script runs and catches them up afterwards.
   OK, or should they be hidden during scripts?
3. **Slot reserve of 2.** Is two free object slots the right margin, or should
   #25 measure the busiest maps first?
4. **`PALSLOT_NPC_SPECIAL` clash** with an opposite-gender remote player and a
   special NPC on screen: accept for v1?

## Proof branch

Branch [`spike/21-remote-object-event`][spike] on the fork, based on the pinned
commit `731ad5b`. Throwaway: don't merge it, and don't move the submodule
pointer to it. It adds:

- `include/coop/coop_spike.h`, `src/coop/coop_spike.c`: one remote slot, fixed
  at Littleroot Town (10, 12), Brendan (rival graphics when the local player is
  May), pacing one tile east and west every 48 frames. Out of Littleroot it is
  removed; out of view it is culled by the game and respawned when back in view.
- The three one-line hooks from section 7 (`CB1_Overworld`,
  `DoesObjectCollideWithObjectAt`, `GetObjectEventIdByPosition`).

Build it like the normal ROM: check out the branch inside `rom/`, then run
`docker compose run --build --rm rom`.

Tested on 2026-10-22 with mGBA 0.10.5 (proof commit `ee2462f`, ROM SHA1
`0b535e50d5d045ec2741e3516ed9e66c72f75d74`), starting from a save with a male
player. The run was scripted through mGBA's GDB stub (`-g`): one key-injection
breakpoint per frame, plus reads of `gObjectEvents`. Results:

| Check | Result |
| --- | --- |
| Spawn | Object 228 appears at (11, 12) facing east, player palette intact |
| Walk | Paces 9 → 10 → 11 with the walk animation, `facing` follows the step |
| No collision | The player walked east along row 12 from x = 7 to 13 and stood on the remote's tile (10, 12) |
| Leave by the map edge | On Route 101 the object is gone |
| Come back | Out of view at Littleroot (10, 0): no object (culled). At (10, 10) it is respawned |
| Door warp | Gone inside May's house. Respawned after walking out |
| A on the remote | No script ran, the field kept running and the player could still move |

[tree]: https://github.com/BDL-Ltda/pokeemerald/tree/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881
[spike]: https://github.com/BDL-Ltda/pokeemerald/tree/spike/21-remote-object-event
[spawn-param]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/event_object_movement.c#L1510-L1528
[localids]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/constants/event_objects.h#L297-L305
[collide]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/event_object_movement.c#L4706-L4723
[by-position]: https://github.com/BDL-Ltda/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/event_object_movement.c#L2192-L2206
