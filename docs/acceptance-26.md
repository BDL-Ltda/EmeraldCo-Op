# Issue #26 validation record

Branch: `feat/26-mailbox-socket-bridge`. Automated checks performed on
2026-10-23. **Manual emulator acceptance is pending.** This record is not a
claim that the issue is done; CI, human approval and merge are also pending.

## Automated checks

- Lua: **195 passed, 0 failed (13 suites)** with Lua 5.4.8.
- luacheck 1.2.0: **0 warnings, 0 errors**.
- `go vet ./...` and `go test -race ./...`: pass in `golang:1.27.2`
  with `CGO_ENABLED=1`, network disabled, against the branch's Go source.
  All six packages pass. No Go source changed after that check.
- ROM host tests: **7 groups pass** under ASan/UBSan, using the existing
  pinned ROM and cached Docker build image with a read-only source mount.
- `symgen` rerun against the existing matching ELF/GBA produces exactly the
  branch's `client/addresses.lua`: only `gCoopMailbox`, CRC `97387731`, SHA1
  `ab60e843b809acf58943b8e90b156a3554deaade`. No ROM source, pin or build
  setting changed, so a new ARM ROM rebuild is not required for this branch.

The integration tests use real client modules and byte-addressed mailbox
memory but a **simulated ROM consumer and relay**. They verify conversion,
slot/identity lifecycle, latest-state retries, debug-panel data, server loss,
idle reconnect and old-queue cleanup. They do not demonstrate rendering or
socket behavior inside mGBA; those need the test below.

## Manual result to supply before opening the PR

Follow [the two-instance procedure](mailbox-bridge.md#manual-acceptance-two-mgba-instances).
Record the tested client commit and testers here or in the PR, plus sanitized
logs/screenshots. Use separate saves and local configs; never publish keys,
public IPs, trainer IDs, saves or ROM files.

- [ ] Both players see each other move and turn on the same map; map changes work.
- [ ] Panel coordinates, identity and connection state follow both sessions.
- [ ] At least 45 seconds idle/in a menu preserves peer presence.
- [ ] Stopping the server clears avatars and rows; restart restores both without movement.
- [ ] Restart during a menu does not resurrect departed peers when returning to the field.
- [ ] Leaving/rejoining produces one avatar; soft reset/continue rejoins safely.

Testers: pending. Client commit: pending. Evidence: pending.

The ticket has no `needs:multiplayer-test` label. Its two-instance manual
test is still required; if two developers participate, record their names.
