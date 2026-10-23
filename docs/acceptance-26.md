# Issue #26 validation record

Branch: `feat/26-mailbox-socket-bridge`. Automated checks performed on
2026-10-23. On the same date, **leomayca confirmed the manual cases below
passed with DaviAlencastro and bernardosevero**. This is the testers' report,
not an independent agent observation. Screenshot/log evidence is still being
collected; CI, human approval and merge are also pending.

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

## Reported manual result

Testers: **leomayca, DaviAlencastro and bernardosevero**. The test handoff was
client commit `c72a31c`, using the matching ROM identified above. No source
code has changed since that handoff. In response to the requested checklist,
leomayca reported: "All of that worked" (translated from Portuguese).

- [x] Both players see each other move and turn on the same map; map changes work.
- [x] Panel positions and connection state follow both sessions.
- [x] At least 45 seconds idle/in a menu preserves peer presence.
- [x] Stopping the server clears avatars and rows; restart restores both without movement.
- [x] Leaving/rejoining produces one avatar, without duplication.

Evidence: tester attestation received in the implementation chat on
2026-10-23. A sanitized emulator screenshot or connection/reconnect log has
been requested for the PR; it has not yet been supplied.

### Additional robustness checks not yet reported

These are recommended by the longer [procedure](mailbox-bridge.md#manual-acceptance-two-mgba-instances),
not additional ticket acceptance criteria. Do not infer them from the report
above: they were not in the shorter checklist the tester confirmed.

- [ ] Restart during a menu does not resurrect departed peers when returning to the field.
- [ ] Soft reset/continue rejoins safely.

The ticket has no `needs:multiplayer-test` label. Its two-instance manual
test is still required; if two developers participate, record their names.
