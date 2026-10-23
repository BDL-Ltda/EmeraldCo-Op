# Mailbox/socket bridge (#26)

`client/bridge.lua` now reads only the generated `gCoopMailbox` symbol. The
legacy `client/memory.lua` and its game-struct offsets are removed; there is
no `LEGACY_READ` fallback. `cmd/symgen/symbols.txt` exports only the mailbox.
The ROM, its pin and the mailbox layout are unchanged.

## Lifecycle and visibility

- Verify the ROM CRC before any memory access. Check magic, layout version
  and `rom_ready` at startup and every frame; wait for boot initialization.
- Drain at most 15 outbound messages per frame. Decode/validate each complete
  tuple; feed the local panel and give the network client the latest state.
  Existing socket throttling, partial writes and 10-second renewals still apply.
- Keep the established **wire v1 visibility contract**: a valid ROM snapshot
  identifies a running session, so outgoing JSON uses `visible = true` even
  when the mailbox says hidden during a menu, battle or dialogue. The local
  Me row shows the ROM's original controllable-overworld visibility. Peers see
  the last complete position while that session is busy; no struct reads or
  synthetic map coordinates are needed. Reset/ROM change closes the socket
  instead of renewing the old session. Incoming JSON visibility is unchanged.
- After `welcome`, wait for the old inbound queue to empty with `lua_connected`
  clear. The ROM discards it when the overworld resumes. Only then set the flag,
  enqueue `LEAVE` for all four slots, and replay the new welcome snapshot.
  This prevents old peers surviving a reconnect or script reload during a menu.
  Only the ROM moves `inbound.tail`; Lua never clears the ring by writing it.
- Allocate slots 0–3 in player-ID order as presence becomes available, keeping
  each assignment until leave. A full ring retains the latest state per peer.
  Send pending leaves before slot reuse; a replacement identity never inherits
  the old position. Reconnect does not require the local player to move again.
- On disconnect or stop, clear the flag and pending peer state. The ROM removes
  remote objects on its next overworld update. Socket connection and the debug
  panel may already be restored while a menu delays the ROM handoff.
- Invalid headers stop mailbox I/O and close the session. After a valid header,
  the bridge arms a [Lua-local reset marker](memory-map.md#ring-rules) in the
  unused inbound slot. Its loss detects a completed soft reset even while
  retrying, awaiting welcome or waiting for ROM handoff with the Lua bit
  already clear. Cached identity/position and socket are invalidated before
  any retry; only a fresh post-reset ROM tuple permits rejoining. Index wraps
  and ordinary disconnects do not invalidate the marker. A stopped script
  cannot reconnect from later frame callbacks. Late events from an old socket
  cannot affect its replacement.

The pure `client/lib/mailboxbridge.lua` owns conversion and slot bookkeeping.
`bridge.lua` alone binds emulator, socket and panel APIs. The panel's 30-second
display expiry remains independent of ROM slots and server membership.

## Automated coverage

Run `lua5.4 client/tests/run.lua` and `luacheck client/` from the repo root.
The integration suite uses the real mailbox codec, pipe, network client and
debug model with byte-addressed fake ROM memory and an in-process JSON-line
relay. It checks both directions, identity/facing/coordinates, no pre-session
connection, full-ring coalescing, leave, server restart while idle and stale
queues during a menu. Other suites cover header/version rejection, ROM change,
reset, stop, slot replacement, bounded draining and compatible payload extensions.
The real-entrypoint reset suite also drives the real network client and pipe
through completed valid-header resets during retry, welcome and ROM handoff,
including a reset with all ring indices already zero and fresh-state recovery.
These tests do **not** run mGBA or the actual object-event renderer. The manual
test below is still required; do not mark it done from simulated tests.

## Manual acceptance: two mGBA instances

Use mGBA **0.10.5** and the client from this branch for both players. Use the
ROM matching `client/addresses.lua` (CRC **97387731**, SHA1
`ab60e843b809acf58943b8e90b156a3554deaade`). ROM source pin:
`e4ccbcf592850b8199af0ccf22b84cfdf227aca5`. Build as described in the root
README if needed. No ROM or save may be committed or uploaded as evidence.

1. Start the server. For a localhost-only test in PowerShell:

   ```powershell
   $env:SERVER_JOIN_KEY = Read-Host "Local test join key"
   go run ./cmd/server -addr 127.0.0.1:8765
   ```

   If `go` is not on PATH, use your installed Go executable. Keep this terminal
   open. An existing hosting setup also works; share its key/host privately.
2. Each player uses their own local `client/config.lua`: same server/port/key,
   different `PLAYER_ID`, and `DEBUG = true` for evidence. On one PC, copy
   `client/` into two separate ignored directories under `bin/`, create each
   config from `config.example.lua`, and load the corresponding `bridge.lua`
   in each instance. Copies must stay in ASCII-only paths. Never load
   `debug/presence.lua` alongside the bridge: there is only one outbound reader.
3. Open the matching ROM in both instances, with separate save paths (copy a
   ROM into each ignored test folder if necessary). Do not let two running
   instances write the same save. Load the bridge once in each Scripting window.
   Continue both games and take one step to publish a fresh snapshot.
4. Put both trainers on the same map and near each other. Confirm each game
   draws the other avatar. Walk and turn both ways; compare the remote panel
   row with the other game's Me position. Test a map change and return too.
5. Leave one game idle or in a menu for at least **45 seconds**. The peer must
   remain in the panel. The remote avatar keeps the last position under v1;
   the busy player's local Me row may say hidden. Close the menu and walk:
   movement must resume. Use different trainers/genders if available.
6. Stop the server with Ctrl+C while both are in the overworld. Confirm errors
   report retrying, remote panel rows clear and avatars disappear. Restart the
   same server with the same key. Wait for both clients to rejoin (normally a
   few seconds), **without moving**: both avatars must return.
7. Repeat server restart while one game is in a full-screen menu. Keep that
   menu open through reconnect, then return to the field. Confirm only current
   peers appear and movement catches up. Close one mGBA and verify its avatar
   and panel row leave the other game; rejoin and check it appears once.
8. Soft-reset a game, then continue and walk. Confirm no crash or old-session
   avatar at title and that the session rejoins with fresh mailbox state.

Record who tested, the client commit, ROM CRC, and pass/fail for steps 4–8.
Include a screenshot of **both in-game avatars** and short sanitized logs of
join, server loss and rejoin. Remove join keys, real trainer IDs and public
addresses (including the panel host and server connection logs). The result
belongs in the PR. Until this is supplied, manual acceptance and CI/approval/
merge checklist items remain pending; no simulated result substitutes for them.
