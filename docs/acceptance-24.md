# Local ROM presence acceptance (#24)

## Human test report

Reported on **2026-10-23** by **leomayca**, using mGBA 0.10.5 and
`client/debug/presence.lua`, with no network client or server.

- Tested publisher revision: `BDL-Ltda/pokeemerald@4bbfc3637`.
- ROM SHA1: `781fd14f3135d0e366ecb4f8204fbaf5f884666e`.
- Verified ROM CRC32 in the supplied log: `9f2e4509`.
- The tester confirmed menu/Bag, NPC dialogue and entering/leaving a battle,
  in addition to the walking, facing and map transitions visible in the log.
- The tester reported no perceived hangs. This is a human observation, not
  frame-time profiling or an automated visual comparison.

The supplied log demonstrates long zero-message intervals before the first
snapshot and while idle, updates to all four facing directions, hidden/visible
transitions, house/floor warps and a route-edge crossing. It also includes a
restart, an empty mailbox interval, and a fresh first visible snapshot.
The busy transitions are not labeled by activity; their attribution to menu,
dialogue and battle comes from the tester's explicit confirmation.

## Selected evidence

These are selected lines from the human-supplied log. Identity suffixes
(`gender` and `trainerId`) are omitted; no ROM, save or full raw log is included.

```text
[presence-check] ROM verified (9f2e4509); mailbox only, no network
[presence-check] last 300 frames: 0 messages; total=0
[presence #1] 0:9 12,12 EAST visible
[presence-check] last 300 frames: 0 messages; total=1
[presence #2] 0:9 12,12 NORTH visible
[presence #3] 0:9 12,11 NORTH visible
[presence #6] 0:9 12,9 SOUTH visible
[presence #10] 0:9 12,12 WEST visible
[presence #32] 0:9 12,15 EAST hidden
[presence #33] 0:9 12,15 EAST visible
[presence #64] 0:9 14,9 EAST hidden
[presence #65] 1:2 2,8 EAST visible
[presence #75] 1:2 2,2 NORTH hidden
[presence #76] 1:3 1,2 SOUTH visible
[presence #98] 1:2 2,8 SOUTH hidden
[presence #99] 0:9 14,9 SOUTH visible
[presence #116] 0:9 11,0 NORTH hidden
[presence #117] 0:16 11,19 NORTH visible
[presence #125] 0:16 8,14 WEST hidden
[presence-check] last 300 frames: 0 messages; total=125
[presence #126] 1:4 6,5 NORTH visible
```

The original debug script printed an error when it briefly observed an all-zero
mailbox header during boot/reset, then recovered. The diagnostic now logs a
one-time initialization wait and only reports an error if the header remains
unavailable for 300 frames. Unit tests cover transient waits, recovery and
persistent failures. This is a Lua diagnostic change; it does not change ROM
publishing behavior or the tested ROM hash above.

## Integration boundary

After this human test, #25's remote renderer merged into `master`. The #24
branch integrates it by running `CoopPresence_Update` before the existing
`callback2 == CB2_Overworld` guard around `CoopRemote_Update`. The publisher
implementation is unchanged from the human-tested revision. An additional
sanitized test checks both shared-hook paths.

The final combined ROM and regenerated addresses have their own hashes. Do
not describe the human report above as a playthrough of that later combined
build. Build reproduction, automated tests and CI are recorded separately in
the PR; the multiplayer rendering acceptance remains with #25/#26.
