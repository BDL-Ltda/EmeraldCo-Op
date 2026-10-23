# ROM local presence (#24)

The ROM publishes local state through `COOP_MSG_PRESENCE` in the outbound
mailbox. It does not connect to the server or draw remote players; the Lua
bridge handles the socket and the ROM remote-player module handles rendering.

## Publishing rules

`CB1_Overworld` calls `CoopOverworld_Update` after input processing, outside
the `callback2 == CB2_Overworld` guard. This follows the approved
[remote-player design](remote-player-design.md#detecting-local-changes-24).
`CoopPresence_Update`:

- Does nothing before `rom_ready`, at the title screen, or before the first
  valid controllable-overworld snapshot.
- Reads a complete snapshot only with `callback2 == CB2_Overworld` and field
  controls unlocked. Map coordinates come from the player's active object
  event minus `MAP_OFFSET`; trainer ID is all four save bytes.
- Pushes only changes to the last **successfully queued** snapshot. Standing
  still has no heartbeat and produces no new ROM messages.
- When controls lock (menu, NPC talk, cutscene, warp fade, battle), queues
  the last tuple with `visible = 0` once. It does not sample changing script
  coordinates or half-loaded maps. On return, queues a fresh visible tuple.
- Retries the latest change while the field hook runs if the ring is full;
  it never advances its snapshot on a rejected push. Lua must drain the ring
  continuously: a full ring cannot deliver a hidden transition while the
  game is in a battle/menu with no field hook. This is not a reliable event
  queue; the latest state is reconciled on the next overworld update.
- RAM clearing on boot/soft reset forgets the snapshot with the mailbox.
  `CoopPresence_Reset` also explicitly forgets it for future session hooks.

The [13-byte layout](memory-map.md#presence-payload) is shared with
`client/lib/mailbox.lua`. Packed C structs and compile-time size/offset
assertions prevent accidental padding. No mailbox layout version bump is
needed: the existing `PRESENCE` contract is being implemented.

This ROM visibility means **controllable overworld**, unlike the older direct
memory reader's "game session running" semantics. The bridge now consumes the
mailbox stream. The network client's 10-second presence renewal remains
separate from this change-only ROM stream.

## Automated tests

The fork contains `tests/coop/run.sh`. It compiles the actual mailbox,
presence publisher and co-op hook with small game-field doubles, then runs
seven test groups with AddressSanitizer and UndefinedBehaviorSanitizer. These
are logic tests, not a substitute for the normal ARM build or emulator play.

With the pinned build image available, from the repository root:

```sh
docker run --rm --network none --mount type=bind,source="$PWD/rom",target=/source,readonly --entrypoint sh emerald-coop-rom:ci -c 'cd /source && sh tests/coop/run.sh'
```

Use your locally built ROM image tag in place of `emerald-coop-rom:ci` if
different. CI runs the same tests before building the ROM and checking the
regenerated addresses. Coverage includes readiness/title/intro suppression,
all payload fields, 3,600 idle updates, hidden-once transitions, fresh
post-warp tuples, invalid objects, full-ring retries and snapshot resets.
The shared-hook test also checks that outbound hiding still runs while the
#25 renderer is gated off by a non-overworld `callback2`.
The exact byte fixture also matches the existing Lua codec test, including
negative coordinates and a trainer ID with its high bit set.

## Manual mGBA test (no server or second player)

1. Build the ROM and regenerate `client/addresses.lua` from that exact ELF
   and ROM, following the root README. Back up your save before testing.
2. Open that ROM in mGBA **0.10.5**. Use **Tools > Scripting > File > Reset**
   to unload `bridge.lua` and any previous scripts. Only one script may consume
   the outbound ring.
3. Load `client/debug/presence.lua`. It verifies the ROM checksum before
   touching the mailbox. It reads no private config and opens no sockets.
   A short `waiting for mailbox initialization` notice during boot/reset is
   normal; a header still unavailable after 300 frames is reported as an error.
4. Stay at the title screen: there must be no `[presence #...]` lines. The
   `[presence-check]` summaries are diagnostics, not presence messages.
5. Continue or start a game, wait for controls, then stay still for at least
   ten seconds. After the initial visible snapshot, the summaries must show
   `0 messages` for complete idle intervals.
6. Walk in each direction and turn against a wall. Check map, tiles and facing.
   Open the start menu and Bag, stay there, then return: expect one hidden
   transition, no repeats while busy, then one fresh visible snapshot.
7. Talk to an NPC or run a cutscene. The last tuple becomes hidden once; no
   scripted positions are published. Close the dialogue and confirm visible.
8. Enter/exit a house and cross a route edge. Each warp hides the old tuple,
   then publishes the new map and coordinates together, with no mixed tuple.
9. Enter a wild or trainer battle, play/exit it, and confirm hidden before
   the transition and visible again on return. The game must remain normal:
   no visual glitches, stalls or slowdowns.
10. Soft reset to title. The mailbox resets; no old snapshot
    is published at title. Continue and confirm a fresh visible tuple.

Record which cases passed and a short selected log in the PR. Do not upload
the ROM, save, join key, IP addresses or raw logs from a network session.

The [recorded human test](acceptance-24.md) identifies the tested revision,
selected evidence and the boundary between that playthrough and later merges.
