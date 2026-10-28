# Virtual-link spike (#80)

**Status: prototype, emulator acceptance pending.** This is an opt-in experiment,
not the production backend from #81 or the trade-session controller from #83.
Do not mark #80 complete or unblock those issues from a successful build alone.
The initial time box is three working days, as suggested in the ticket.

## Question and decision gate

Can the vanilla `rom/src/trade.c` screens work through a block-level adapter,
without emulating the cable's serial interrupts over the internet?

The source inspection supports trying the virtual link: the screen already
waits asynchronously for received flags and link-task completion. **The go/no-go
decision is pending the two-instance results below.** A build and host doubles
cannot prove frame callbacks, rendering, flash saves or trade evolution.
If the experiment fails, record the failing screen and reason before deciding
whether to change the adapter or re-plan #81/#83 around a separate trade flow.

## Prototype boundaries

- ROM: `src/coop/link_spike.c` and `include/coop/link_spike.h`. Small opt-in hooks
  in `link.c`, `main.c`, `trade.c` and `coop/remote_players.c`.
- Lua: load `client/spike/link-a.lua` and `link-b.lua` instead of `bridge.lua`.
  They use the existing `config.lua` endpoint/key, but fixed test IDs
  `spike_a` and `spike_b`, and roles 0 and 1. The harness sends only to its
  configured partner and checks that partner's incoming sequence numbers.
- Server: the existing protocol v2 `trade_available` and `trade_link`. No server
  changes, new dependencies, protocol bump or routing rules.
- The ordinary bridge never sends the experiment's START message. Normal play
  leaves the adapter inactive and uses the existing cable/RFU behavior.
- Four ROM packets and sixteen delayed/inbound Lua packets are bounded queues.
  A full ROM queue freezes the experiment instead of silently overwriting bytes.
- No reconnect, clean cancel, production timeout, consent UI or audit
  `trade_confirm` emission. These remain #81/#82/#83. Restart both instances
  after a disconnect; never use this prototype on a valuable save.

## Link surface found in the source

References are to the checked-out decomp source; the parent PR pins the tested
fork revision. No live memory addresses are used by the harness other than
the generated `gCoopMailbox` symbol in `client/addresses.lua`.

| Surface | Caller / need | Experiment |
| --- | --- | --- |
| `SendBlock`, `SendBlockRequest` | Trade commands and `BufferTradeParties` | Queue bytes through mailbox v2; a request carries the leader's block and asks for the follower's prepared buffer. |
| `gBlockSendBuffer`, `gBlockRecvBuffer` | Party, mail, ribbons, selection / finish commands | Keep vanilla buffers; preserve local echo as well as the remote block. |
| `GetBlockReceivedStatus`, `ResetBlockReceivedFlags`, `ResetBlockReceivedFlag` | Party waits for mask `3`; menu consumes each sender separately | Two received bits, one per role. |
| `IsLinkTaskFinished` | Queued UI actions, animation send scheduling and save barriers | Wait for ROM queue / mailbox streaming and matching standby generation. |
| `GetMultiplayerId`, `IsLinkMaster` | Leader/follower menu and animation decisions | Fixed roles 0/1 for this experiment. |
| `GetLinkPlayerCount`, `GetLinkPlayerCount_2`, `GetSavedPlayerCount` | Setup and version checks | Two while active. |
| `gLinkPlayers`, `gReceivedRemoteLinkPlayers`, `IsLinkPlayerDataExchangeComplete` | Partner name, version, language and progression restrictions | Exchange actual `LinkPlayer` records; the vanilla completeness check remains. |
| `OpenLink` | Animation reopens the cable after leaving the selection menu | Reopen the virtual flags, keeping the authenticated test partner. |
| `SetLinkStandbyCallback` | Cooperative barriers, especially around save commit | Exchange a generation byte; no unconditional "finished" stub. |
| `SetCloseLinkCallbackAndType`, `SetCloseLinkCallback` | Cancel, selection-to-animation transition, final close | Exchange close generations before clearing `gReceivedRemoteLinkPlayers`. |
| `HandleLinkConnection`, `LinkVSync` | Main loop / hardware serial driver | Bypass serial handling while the virtual adapter is active. |
| `CloseLink`, `HasLinkErrorOccurred` | Error paths | Otherwise unchanged. No claim of production error recovery. |
| RFU functions / `gWirelessCommType` | Wireless branch, activity 29 | Use the cable branch (`gWirelessCommType = 0`); do not simulate RFU. |

The hook must also stay alive when a summary screen or evolution scene temporarily
owns callback2. Pumping only from `CoopOverworld_Update` would stop the transport
as soon as the player left the overworld. The experiment pumps before the game's
main callbacks and gives its own consumer exclusive ownership of inbound slots
until it returns to the field.

## Entering without Cable Club

START is accepted only in the fully running, unlocked overworld with a nonempty
party. The normal presence client cannot trigger it. The experiment:

1. Despawns remote field objects and selects the cable branch.
2. Calls vanilla `LocalLinkPlayerToBlock` to populate the local trainer identity,
   version, language and progress flags, rather than inventing those fields.
3. Exchanges each `LinkPlayer`, assigns role IDs and applies the vanilla partner
   name conversion. A role is not a protocol player ID.
4. Sets a dynamic return warp to the current map/position for vanilla save code.
5. Sets `gReceivedRemoteLinkPlayers` after the identity exchange and calls
   `CB2_StartCreateTradeMenu`. Its case 1 skips the Cable Club hardware setup;
   case 4 still checks link-player data compatibility.

`BufferTradeParties` does **not** send one 600-byte block: it sends three pairs
of Pokemon (200 bytes each), then the mail block (220 bytes) and ribbons
(40 bytes), with eleven-frame preparation delays. It waits for both self and
partner received bits, so omitting the self echo would hang immediately.
The generic mailbox still handles each complete packet by fragmentation.

## Latency and error investigation

Static findings, **not measurements**:

- Party exchange and menu waits generally wait for flags, rather than a fixed
  number of frames. The eleven-frame preparation delays are worth stressing
  under asymmetric frame rates and latency; a request must not read a stale
  follower buffer.
- `trade.c:CheckForLinkTimeout` sends the game to `CB2_LinkError` after more
  than 300 frames without progress during animation setup (about five seconds
  at normal speed). It must not be used as the production disconnect UX.
- `link.c`'s player-data exchange has a 600-frame timeout. The spike skips the
  hardware handshake, so passing the spike does not prove those serial timeouts
  tolerate network latency. The future backend replaces their transport.
- Serial-frame lag flags must be bypassed; returning success from `SendBlock`
  alone would leave `HandleLinkConnection` / `LinkVSync` running the cable driver.
- The server's 15-second inactivity timeout still applies. The harness sends
  pings every five seconds independently of game screens.

Set the fourth argument in **both** wrapper scripts to 0, 25, 50 and 100. That
delays each outgoing link-data packet by that many milliseconds: the injected
round-trip component is approximately 0, 50, 100 and 200 ms, plus scheduling and
base network latency. This does not delay ping packets; ping RTT does not measure
the injected link-data delay. Record actual elapsed time and screen progress.

## Evolution, lockstep save and return

Static path to verify:

1. `CB2_UpdateLinkTrade` runs the vanilla animation and `TradeMons`, then peers
   exchange ready/confirm-finish commands.
2. `CB2_TryLinkTradeEvolution` calls the vanilla trade evolution scene if
   `GetEvolutionTargetSpecies(..., EVO_MODE_TRADE, ...)` returns a target. After
   that scene, `gCB2_AfterEvolution` resumes `CB2_SaveAndEndTrade`.
3. `CB2_SaveAndEndTrade` waits on standby, invokes `LinkFullSave_Init`, writes
   sectors (five-frame delays between writes), and replaces the last sector.
4. A second standby barrier precedes `LinkFullSave_SetLastSectorSignature`.
   **That function commits the final signature locally.** A further standby
   and close finish the session. Stubbing standby as immediately successful
   would destroy the intended synchronization.
5. The spike's callback returns directly to the local field, rather than the
   Cable Club's multiplayer field scripts. It clears the virtual session and
   emits a trace when callback2 actually reaches `CB2_Overworld`.

The save functions in `save.c` perform local flash operations; they are not
network functions themselves. The screen supplies the synchronization around
them. This is not an atomic distributed save: a crash around the signature
commit can still leave one side saved and the other unsaved. No recovery is
implemented. Emulator testing must use **copies** and inspect both saves after
closing and reopening the ROMs. Test an evolution species and the ordinary
non-evolving path; a menu-only test does not establish save/evolution behavior.

## Temporary mailbox contract

No shared-memory layout or global address was added. The two temporary message
types are listed in [memory-map.md](memory-map.md#message-types).

Type `5`, `COOP_MSG_LINK_SPIKE`, is reassembled as an ordinary v2 message:

| First byte | Remaining bytes | Direction |
| --- | --- | --- |
| `0` START | One role byte, 0 or 1 | Lua to ROM only; not relayed. |
| `1` HELLO | `sizeof(struct LinkPlayer)` bytes, from `include/link.h` | Both ways through `trade_link`. |
| `2` BLOCK | 1–256 original block bytes | Both ways; implicit sender is the other role. |
| `3` REQUEST | Leader's block bytes; byte length requests the same size from `gBlockSendBuffer` | Role 0 to role 1; response is BLOCK. |
| `4` BARRIER | One generation byte | Both ways; short experiment only, no wrap/session recovery. |
| `5` CLOSE | One generation byte | Both ways. |

Type `6`, `COOP_MSG_SPIKE_TRACE`, is a three-byte **single-slot** debug message:
stage `u8`, value `u16` little-endian. It is printed locally, never sent over
the network. Only state changes are emitted; a full ring may drop a trace.

| Stage | Value |
| --- | --- |
| 1 | `BufferTradeParties` state; 21 means the buffers were exchanged. |
| 2 | Menu callback ID: 0 main menu, 2 summary, 3 confirmation prompt, 7 "is this okay", 9 fade to trade, 12 exit canceled, 100 idle. |
| 3 | `CB2_LinkTrade` setup state. |
| 4 | Trade evolution callback state. |
| 5 | Save callback state; 42 waits for the pre-signature barrier, 5 follows signature commit. |
| 6 | 1 return callback invoked, 2 callback2 reached the overworld. |
| 8 | Evolution target species ID, or 0 for none. |

## Reproducible emulator test

Use mGBA **0.10.5**, the same built ROM on both sides, matching generated
addresses, the protocol v2 local server, and two **independent** mGBA processes.
Do not use the emulator's native multiplayer/link-cable window: it would test
the wrong transport.

1. Copy the ROM into separate folders/names and copy a compatible `.sav` next
   to each matching basename. Keep original saves elsewhere. Each party needs
   at least two living Pokemon to pass vanilla trade restrictions. Include a
   trade-evolving Pokemon in a separate run. Do not commit or post any copies.
   To avoid preparing a party manually, the fifth argument in each wrapper can
   be set to `true` **only for disposable saves**: the ROM replaces the RAM party
   with Kadabra + Zigzagoon for role 0 and Machoke + Zigzagoon for role 1. The
   normal trade/evolution/save path then writes those fixture parties to the
   copied saves. The committed wrappers default to `false`.
2. Start the local server. Configure `client/config.lua` privately with its
   loopback endpoint/key. The same configuration works for both scripts because
   they override the player IDs. Do not share keys or raw server logs.
3. Open each copied ROM, Continue and stand in the unlocked overworld. Both
   emulators must keep running when unfocused.
4. Reset Scripting in each instance. Load `client/spike/link-a.lua` in A and
   `client/spike/link-b.lua` in B. Do not also load `bridge.lua` or echo.lua.
5. The scripts announce readiness to each other and enter the original trade
   menu. Record the last `[link-spike] frame ... stage ... state ...` lines and
   the actual screen on **both** instances. Confirm all party icons/names match
   the other party, then open and leave Summary and reach confirmation.
6. First cancel on both sides and verify return to the original field. Restart
   both instances/scripts between runs. Then use only disposable copies for
   the full animation/evolution/save path. Reload both copied ROMs afterward
   and verify the received Pokemon and position persisted.
7. Repeat with the wrapper delays above. Note hangs or native link errors,
   rather than interpreting a lack of an error as successful transfer.
8. After returning, reset Scripting and load `bridge.lua`; verify local and
   remote presence again. Keep a sanitized result per row below.

| Run | Screens reached A/B | Party bytes / summary / confirm | Evolution / save / reload | Return / presence | Error and elapsed time |
| --- | --- | --- | --- | --- | --- |
| No injected latency | Pending | Pending | Pending | Pending | Pending |
| 50 ms added RTT | Pending | Pending | Pending | Pending | Pending |
| 100 ms added RTT | Pending | Pending | Pending | Pending | Pending |
| 200 ms added RTT | Pending | Pending | Pending | Pending | Pending |

## Verification so far

- Prototype fork revision: `a468cd12d741dc657bf8b7fbbbdca5634804091f`.
  Built ROM SHA1: `453b14d4e30f1a4154841834da50384b3fc36ae6`.
- `go vet ./...` and uncached `go test -race -count=1 ./...` pass in all six
  packages on the parent base. Lua: 244 tests pass; luacheck: no warnings/errors
  in 37 tracked files. No production Go code changed.
- The instrumented ARM build succeeds; `client/addresses.lua` is regenerated
  from that exact ELF/ROM. Build identity will be recorded with emulator results.
- Lua harness tests cover guarded startup, waiting for a ready partner, filtering
  peers/targets, raw-byte preservation, injected delay and sequence failure.
- C host tests exercise the real experimental adapter with mailbox/game doubles:
  guarded entry, identity, refused sends, streaming backpressure, self echo,
  requests, barriers, close/reopen, return callback and queue/size bounds.
  The complete local suite passed with ASan/UBSan using `CC="cc -no-pie"`.
  Default-PIE suite runs here repeatedly emitted `AddressSanitizer:DEADLYSIGNAL`
  before the first presence result; isolated tests also passed. The local
  difference remains unexplained. No sanitizer was disabled
  and the runner's default compiler flags were not changed. CI's default run
  remains to be checked separately.
- **No real two-instance success is recorded yet.** The local UI automation
  attempt could not operate mGBA's modal file chooser. It did not open the
  copied ROM or establish any acceptance evidence. No production save was used.

Before recommending go, fill in the emulator matrix and record the tested
parent/fork revisions and sanitized logs. Production #81 still needs bounded
session state, trustworthy role assignment, robust request sequencing, a
10-second peer timeout, clean cancellation before save, and coordinated
handling of disconnects at save barriers. #83 owns the full consent/session
flow and `trade_confirm` audit emission.
