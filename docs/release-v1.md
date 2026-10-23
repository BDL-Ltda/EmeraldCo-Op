# v1.0 release preparation (#27)

This checklist tracks [issue #27](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/27).
v1 synchronizes overworld presence for up to five players. Battles, trades,
items and saves remain local. Follow [Releasing](releasing.md) for commands.

## Preparation and publication

- [ ] Merge the preparation PR with human approval; select the resulting
  `master` commit and verify Go, Lua and ROM CI are green at that commit.
- [ ] Build its pinned ROM in Docker, regenerate addresses and confirm no diff.
- [ ] Verify the privately supplied retail base ROM's SHA1, create the BPS with
  Flips, apply it to a fresh output and compare with the built ROM.
- [ ] Archive the committed client, inspect the ZIP for runtime files and the
  absence of private settings, and extract it to a clean ASCII-only path.
- [ ] Fill the notes below with the exact commit, ROM pin and measured SHA1.
- [ ] Create and inspect the draft, then publish `v1.0` with both assets.
- [ ] Download the published assets and verify installation and patched SHA1.

Do not check these boxes from earlier builds. The ROM hash in generated
`client/addresses.lua` identifies the expected ROM; measure the release build
and compare it before copying that hash into release notes. No retail base
ROM, generated patch, private config or ROM build output belongs in Git.

The final docs pass covers README, architecture, protocol, memory map,
installation and online play. Protocol v1 and mailbox layout v1 are unchanged.
The protocol examples remain covered by Go and Lua tests; C size/offset
assertions and Lua mailbox tests cover the documented binary contract.

## Preparation evidence (2026-10-23)

The client archive preflight used merged `master` commit
`265eaab904d07e1c4f583a498117094898b9dbd9` and ROM pin
`e4ccbcf592850b8199af0ccf22b84cfdf227aca5`. The existing local ROM measured
SHA1 `ab60e843b809acf58943b8e90b156a3554deaade`; regenerating addresses from
its existing ELF produced the committed file exactly. This was **not** a fresh
Docker build or a patch round-trip.

- The committed-client ZIP extracted successfully and contained the required
  runtime files and matching addresses, with no private config or forbidden
  artifacts. It is a local packaging preflight, not a published asset.
- All 83 local file-link targets across the eight reviewed docs resolved.
- README/architecture match the implemented presence boundary; installation
  and online play now describe rendered avatars and the mailbox startup.
  Releasing now documents the existing CI freshness check and draft inspection.
- Protocol v1 examples and mailbox layout match the current Go/Lua codecs and
  ROM headers; their contracts required no changes.
- [CI on the base commit](https://github.com/BDL-Ltda/EmeraldCo-Op/actions/runs/39966359462)
  passed Go, Lua and ROM. This records that commit, not a future release build.

Publication still requires the selected merged release commit, a fresh Docker
build, the privately supplied retail base ROM and a verified Flips round-trip.
The release-only session, retrospective and planning date remain pending.

## Release notes template

Copy this block into a local notes file and replace every placeholder before
creating the draft. Use links pinned to the selected release commit.

```markdown
## What's new

Emerald Co-Op v1.0 shares overworld presence for up to five players through
the Go relay and mGBA Lua mailbox bridge. Nearby players on the same map see
Brendan/May avatars, walking and facing updates, map changes and reconnects.
Remote avatars do not block players; busy maps give NPCs priority.

Saves, battles and items stay local. PvP and trading are future work.

## Install

Use mGBA 0.10.5 and your own legally dumped Pokémon Emerald (USA).
[Installation](https://github.com/BDL-Ltda/EmeraldCo-Op/blob/<release-commit>/docs/installing.md)
and [online setup](https://github.com/BDL-Ltda/EmeraldCo-Op/blob/<release-commit>/docs/playing-online.md).
Download both emerald-coop-v1.0.bps and emerald-coop-v1.0-client.zip.
The host shares the server address and join key privately.

| File | SHA1 |
| --- | --- |
| Base ROM (Pokémon Emerald USA) | `f3ae088181bf583e55daf962a92bb46f4f1d07b7` |
| Patched ROM (emerald-coop-v1.0.gba) | `<measured-release-ROM-SHA1>` |

- Release commit: `<full-release-commit>`
- ROM submodule: `<full-ROM-commit>`
- Wire protocol: 1; mailbox layout: 1
- Emulator: mGBA 0.10.5

## Validation and known limits

- Automated checks: <links to green Go, Lua and ROM CI at the release commit>.
- Release-only three-developer session: pending; tracked in issue #27.
- Only presence is shared. Avatars appear on the same map and in view when
  object/sprite slots are available. Menus/battles keep the last peer position;
  local menus can delay mailbox handoff until the overworld resumes.
- mGBA's socket connect can briefly freeze the game during connection retries.
- The shared-key TCP connection is unencrypted and intended for trusted friends.
```

## Release-only acceptance session

**Pending.** Prior development validation is recorded in
[acceptance-26.md](acceptance-26.md); it does not satisfy this release test.
The three testers are bernardosevero, leomayca and DaviAlencastro. Arrange the
time privately. Each installs the published BPS and client into a fresh
ASCII-only folder, with a unique player ID and separate ROM/save path. No
locally built ROM or development client may substitute for the release assets.
The host uses the server built from the release tag; record its revision.

Record the tag, release URL, commit, ROM SHA1, each tester's installation/hash
result, server revision, date, start/end times with timezone, and duration.
Play together across different networks for at least **20 minutes**. Record
pass/fail and tester names for every case:

| Case | Expected result | Result |
| --- | --- | --- |
| Littleroot, all three trainers nearby | Each sees the other two real avatars. | Pending |
| Walk and turn in every direction | Adjacent steps animate; facing matches; larger moves teleport. | Pending |
| Route 101, house entry, warp and return | Different-map avatars disappear and return on the same map. | Pending |
| Walk through each other's tiles | No blocking or unintended interaction. | Pending |
| Busy map/object pressure | NPCs retain priority; unavailable remotes retry without crashing. Record the map and how pressure was reached. | Pending |
| Idle/menu/dialogue for 45+ seconds | Peer rows remain; the last field position persists; movement resumes. | Pending |
| Stop/restart server, including during a menu | Peers hide in the overworld, reconnect without moving and return once, with current state. | Pending |
| Leave/rejoin | Peer row and avatar disappear; one avatar returns, without duplicates. | Pending |
| Soft reset, continue and move | Old session closes; fresh ROM state permits rejoin, with no stale avatar. | Pending |
| Debug panel | Positions, maps and connection state agree with the games. | Pending |

Keep a short video or screenshots plus sanitized observations. Redact the
panel's host, join keys, real trainer IDs and desktop content. Never upload
ROMs, saves or raw server logs. Open an issue for each bug with the release
tag, reproduction, expected/actual result and sanitized evidence; link it
from #27. Leave untested cases pending.

## Retrospective and v1.5 planning

Complete in #27 after the release session; do not infer outcomes in advance:

- Session evidence and remaining bugs: <links>.
- What worked: <observed results>.
- What to change before v1.5: <actions, owners and linked issues>.
- v1.5 re-planning: <agreed date, time, timezone and participants>.

Keep #27 open until publication, the released-artifact session, retrospective
and scheduling are complete. A preparation PR only references #27; it must
not auto-close it.
