# Virtual-link spike (#80)

**Status: prototype, emulator acceptance pending.** This is an opt-in experiment,
not the production backend from #81 or the trade-session controller from #83.
Do not mark #80 complete or unblock those issues from a successful build alone.
The initial time box is three working days, as suggested in the ticket.

## Question and decision gate

Can the vanilla `rom/src/trade.c` screens work through a block-level adapter,
without emulating the cable's serial interrupts over the internet?

The source inspection and two-instance recordings support continuing with the
virtual link: the original screens exchanged parties, animated the trade,
evolved both received Pokemon and saved them. The initial build redrew the map
without restoring player input; the corrected build's 2026-10-29 retest confirms
movement, working menus and the received parties after restarting both games.
The nominal 50 ms added-RTT run also completed trade, evolution, field return and
reload on both sides. **The final go/no-go decision is pending the 100 and
200 ms latency results below.**
Host doubles cannot establish those results.
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
party (or explicit fixture opt-in, which creates a party). The normal presence
client cannot trigger it. The experiment:

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
   restores `CB1_Overworld` to process player input. The completion trace now
   requires both overworld callbacks and unlocked field controls. Still verify
   movement and the Start menu manually, not just the map or callback trace.

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
| `0` START | Role byte (0 or 1), then fixture opt-in byte (0 or 1) | Lua to ROM only; not relayed. |
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
| 6 | 1 return callback invoked, 2 both overworld callbacks restored and field controls unlocked. The initial `17ed0965` build checked only callback2. |
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
   fixture opt-in also sets `FLAG_SYS_POKEMON_GET` so early-game copies have
   the normal Pokemon menu. The trade/evolution/save path writes both the party
   and flag to the copied saves. It does not advance the rest of the story.
   The committed wrappers default to `false`; normal START does not change flags.
2. Start the local server. Configure `client/config.lua` privately with its
   loopback endpoint/key. The same configuration works for both scripts because
   they override the player IDs. Do not share keys or raw server logs.
3. Open each copied ROM, Continue and stand in the unlocked overworld. Both
   emulators must keep running when unfocused.
4. Reset Scripting in each instance. Load `client/spike/link-a.lua` in A and
   `client/spike/link-b.lua` in B. Do not also load `bridge.lua` or echo.lua.
   If it waits for a fresh overworld position after Reset, move or turn once in
   each game. Presence is change-driven; standing still may produce no new tuple.
5. The scripts announce readiness to each other and enter the original trade
   menu. Record the last `[link-spike] frame ... stage ... state ...` lines and
   the actual screen on **both** instances. Confirm all party icons/names match
   the other party, then open and leave Summary and reach confirmation.
6. First cancel on both sides and verify return to the original field: walk in
   each game, then open and close the Start menu. Restart both instances/scripts
   between runs. Then use only disposable copies for
   the full animation/evolution/save path. Reload both copied ROMs afterward
   and verify the received Pokemon and position persisted. Check walking and
   the Start menu on both sides after the full trade as well.
7. Repeat with the wrapper delays above. Note hangs or native link errors,
   rather than interpreting a lack of an error as successful transfer.
8. After returning, reset Scripting and load `bridge.lua`; verify local and
   remote presence again. Keep a sanitized result per row below.

| Run | Screens reached A/B | Party bytes / summary / confirm | Evolution / save / reload | Return / presence | Error and elapsed time |
| --- | --- | --- | --- | --- | --- |
| No injected latency, initial build (both logs: 0 ms one way) | Both original trade menus, confirmation, animation, evolution, saving, field drawn | Parties displayed reciprocally; both logs confirm Summary and return; both confirm screens | Both evolved; save path passed the signature barrier; reload was not recorded in this run | **Failed on initial build:** tester reported blocked movement after trade. Superseded by corrected-build retest below | No native link-error screen in the 2m11s video and traces; post-trade input regression reported afterward. Recording includes user input time |
| No injected latency, corrected build (2026-10-29; both local wrappers set to 0 ms one way) | Both original trade menus, confirmation, animation, evolution, saving and field | Reciprocal fixture parties, B Summary, both confirmations; post-trade party menus work | A receives Machamp, B receives Alakazam; both retain them after boot/title and Continue. Disk save inspection agrees | Menus respond on both sides; tester confirms walking in both games after trade. Production bridge presence not exercised | No native link-error screen in the supplied 2m01s trade video or 29s restart video; durations include user input time |
| 50 ms nominal added RTT (both recorded logs: 25 ms one way) | Both original menus, confirmation, animation, evolution, saving and field | Reciprocal fixture parties and both confirmation screens; Summary not repeated in this run | A receives Machamp, B receives Alakazam; both parties retained after game restart and Continue | Walking is visible on both sides; both party menus respond. Production bridge presence not exercised | No native link-error screen or unresolved stall in the 2m55.17s recording; includes startup and user input time |
| 100 ms added RTT | Pending | Pending | Pending | Pending | Pending |
| 200 ms added RTT | Pending | Pending | Pending | Pending | Pending |

## Verification so far

- Initial manual-test fork revision: `397fa13cc3a30d21743f38dd741fcf11e3c2fb48`.
  That ROM's SHA1 is `f2af69d040327ef54630baefc04332077a53cb5c`.
- Corrected fork revision: `04f4610d52f6045f5f4d59fb6c959c46564b4ee6`.
  Built ROM SHA1: `10235a0df17fd71bb987ac58882a612194a14b78`, CRC32 `fac06040`.
  It restores input after trade/cancel and enables the saved Pokemon menu only
  for explicit fixtures. ARM build, regenerated addresses and host checks pass;
  the corrected build's manual trade, evolution, field-input and reload checks
  passed on 2026-10-29 at baseline and nominal 50 ms added RTT. The 100 and
  200 ms latency rows remain pending.
- `go vet ./...` and uncached `go test -race -count=1 ./...` pass in all six
  packages on the parent base. Lua: 246 tests pass; luacheck: no warnings/errors
  in 37 tracked files. No production Go code changed.
- The instrumented ARM build succeeds; `client/addresses.lua` is regenerated
  from that exact ELF/ROM. Build identity will be recorded with emulator results.
- Lua harness tests cover guarded startup, waiting for a ready partner, filtering
  peers/targets, raw-byte preservation, injected delay and sequence failure.
- C host tests exercise the real experimental adapter with mailbox/game doubles:
  guarded entry, identity, refused sends, streaming backpressure, self echo,
  requests, barriers, close/reopen, restored input after animation/cancel,
  return tracing only after controls unlock, and queue/size bounds.
  The complete local suite passed with ASan/UBSan using `CC="cc -no-pie"`.
  Default-PIE suite runs here repeatedly emitted `AddressSanitizer:DEADLYSIGNAL`
  before the first presence result; isolated tests also passed. The local
  difference remains unexplained. No sanitizer was disabled
  and the runner's default compiler flags were not changed. CI's default run
  remains to be checked separately.
- **Two-instance trade and reload recorded:** see the observations below. The
  initial input regression was corrected and retested. Functional field return
  and persistence passed on the corrected build at baseline and nominal 50 ms
  added RTT; the 100 and 200 ms latency rows remain pending.
  Production-bridge presence and the non-evolving/cancel paths have not been
  exercised in the supplied recordings. Only disposable ROM/save copies are used.

### Nominal 50 ms added RTT: 2026-10-29

`leomayca` supplied a private 2m55.17s recording of the prepared 50 ms profiles,
using the same corrected ROM and two independent mGBA 0.10.5 instances. Around
0:48, **both** scripting consoles show ROM verification CRC32 `fac06040` and
their respective roles with `injected one-way delay 25 ms`. The local wrapper
settings match those recorded logs. This establishes the configured nominal
50 ms added-RTT condition; it is not an independent measurement of exact wall
clock packet latency. Frame scheduling and base latency also apply, and pings
are not delayed by these profiles.

| Approximate video offset | Observation |
| --- | --- |
| 0:38–0:48 | Both scripts verify the corrected ROM, join as `spike_a` / `spike_b`, and start roles 0 / 1 with 25 ms added one-way delay. |
| 0:49–0:56 | Party exchange completes and both original menus display the reciprocal Kadabra/Machoke fixture parties. |
| 0:57–1:03 | Both reach the vanilla confirmation and communication-standby screens. |
| 1:04–1:36 | Both run the original animation and show the received Pokemon. |
| 1:37–2:02 | Machoke evolves into Machamp on A; Kadabra evolves into Alakazam on B. |
| 2:03–2:12 | Both display saving and finish the field transition. |
| 2:13–2:26 | Both are back on the map; changes in position relative to map landmarks show walking in both games. |
| 2:29–2:35 | Both party menus show the evolved received Pokemon and the remaining Zigzagoon. |
| 2:36–2:55 | Both restart through boot/title and Continue. At about 2:54 both party menus again show Machamp + Zigzagoon on A and Alakazam + Zigzagoon on B. |

No native link-error screen or unresolved stall is visible. The full recording
includes emulator startup, script loading, menu input and the final restarts;
its duration is not a measured trade-transfer time. The remaining latency
investigation is the nominal 100 and 200 ms profiles. Raw video and extracted
desktop frames remain local; this document records the sanitized observations.

### Corrected-build retest: 2026-10-29

`leomayca` supplied two private recordings (2m01.42s and 28.88s), using two
independent mGBA 0.10.5 instances. Prepared parent revision: `e8f6e5a`; ROM fork,
SHA1 and CRC32 are the corrected build listed above. Both copied ROM hashes were
checked locally, and the isolated wrappers used fixture opt-in with 0 ms added
one-way delay. ROM verification/startup logs are not visible in these recordings.
The raw desktop videos and extracted frames are kept local, not published.

| Recording / approximate offset | Observation |
| --- | --- |
| Trade, 0:00–0:20 | Reciprocal Kadabra/Machoke fixture parties; B opens Summary and returns; both reach the vanilla confirmation and standby screens. |
| Trade, 0:22–0:51 | Both run the vanilla trade animation and show the received Pokemon. |
| Trade, 0:53–1:20 | A's Machoke evolves into Machamp; B's Kadabra evolves into Alakazam. Both completion messages appear. |
| Trade, 1:22–1:31 | Both show the vanilla saving message. |
| Trade, about 1:32–1:40 | Both return to the field; A opens Start and its party, showing Machamp + Zigzagoon. |
| Trade, about 1:46–2:01 | B opens its party, showing Alakazam + Zigzagoon; A opens Machamp's Summary. |
| Restart, about 0:05–0:22 | Both games go through boot/title and Continue, then return to the saved map. This is a game restart, not a demonstrated closure/relaunch of the emulator processes. |
| Restart, about 0:24–0:26 | Both party menus are visible again: Machamp + Zigzagoon on A, Alakazam + Zigzagoon on B. |

The menus demonstrate responsive field input. Walking is not clearly shown in
the recordings; the tester separately confirmed walking in **both** instances
after the trade. This completes the functional field-return regression retest.

A separate read-only inspection of the two updated disposable save files found
both flash save slots valid, `FLAG_SYS_POKEMON_GET` set, and two party members in
each latest save: Machamp level 25 + Zigzagoon level 10 on A, Alakazam level 25 +
Zigzagoon level 10 on B. All four Pokemon checksums were valid. The inspection
used the pinned `save.h`, `global.h`, `pokemon.h` and `pokemon.c` layouts,
checksum, decryption and substructure-order rules; it did not modify any save.
This supplements the restart video with evidence that the received parties and
menu flag reached the disk saves, rather than only the current RAM party.

No injected-delay acceptance, normal bridge presence, crash recovery or atomic
distributed-save guarantee is inferred from this successful baseline.

### Initial two-instance flow: user-supplied video

`leomayca` supplied a private 2m11s recording on 2026-10-28 using two mGBA
0.10.5 instances and the disposable fixture parties. The prepared client was
`a0158c4`, ROM revision/hash are listed above, and both local wrapper files
were checked with zero added delay. The raw desktop recording is not published.
Observed offsets are approximate:

| Video offset | Observation |
| --- | --- |
| 0:00–0:50 | A displays Kadabra + Zigzagoon locally and Machoke + Zigzagoon remotely; B shows the inverse. A Summary screen for Machoke is opened on B and returns to the trade menu. |
| About 0:52 | Both instances reach the vanilla "Is this trade okay?" screen. |
| About 0:58–1:28 | Both proceed through the cable-style animation and show the received Pokemon. |
| About 1:32–1:54 | A's received Machoke evolves into Machamp; B's received Kadabra evolves into Alakazam. Both completion messages are visible. |
| About 1:57–2:04 | Both display "SAVING... DON'T TURN OFF THE POWER." |
| About 2:07–2:11 | Both display the Littleroot overworld; the recording does not establish working player input. |

This demonstrates the original party/confirmation/animation/evolution/save-screen
path and field rendering for this run. The tester subsequently reported blocked
movement; functional field return did not pass. The video also does not prove
every party byte or persistent data after reopening either ROM. The recording
contains no restart/reload check and does not establish the delayed RTT cases.
Reopen the copied ROMs **without loading the spike scripts** for the persistence
check: fixture opt-in deliberately replaces the RAM parties on each new START.

### Accompanying A/B traces

`leomayca` also supplied both console traces for this run. Each verifies ROM
CRC32 `17ed0965`; A uses role 0, B role 1, and both explicitly report injected
one-way delay **0 ms**. The traces supplement what is visible in the video:

| Milestone | A | B | Interpretation |
| --- | --- | --- | --- |
| Party exchange | Stage 1 state 0 at frame 925, state 21 at 1022 | Stage 1 state 0 at 32, state 21 at 127 | Both finish `BufferTradeParties`; local spans are 97 and 95 frames. |
| Summary round trip | Stage 2 state 2 at 6651, state 0 at 6918 | Stage 2 state 2 at 6233, state 0 at 6452 | Both enter Summary and resume the trade menu. |
| Evolution | Stage 8 value 68 | Stage 8 value 65 | `SPECIES_MACHAMP` and `SPECIES_ALAKAZAM`, confirmed against the pinned `species.h`. |
| Initial save barrier | Stage 5 state 100 at 13075, state 2 at 13176 | Stage 5 state 100 at 12279, state 2 at 12280 | Observed local spans: 101 frames on A, 1 on B. |
| Incremental writes | Fourteen entries into stage 5 state 52, then state 4 | Fourteen entries into stage 5 state 52, then state 4 | The repeated 51/52 alternation is the vanilla sector-delay/write loop, not a stuck screen. |
| Pre-signature barrier | Stage 5 state 42 at 13569, state 5 at 13570 | Stage 5 state 42 at 12658, state 5 at 12679 | Both advance past `LinkFullSave_SetLastSectorSignature`; local spans are 1 and 21 frames. |
| Return | Stage 6 state 1 at 13711, state 2 at 13720 | Stage 6 state 1 at 12817, state 2 at 12826 | Return callback runs and callback2 reaches `CB2_Overworld` in both instances. This initial trace did not check callback1 or input controls. |

Frame counters start when each script is loaded; do not subtract an A frame
number from a B number or interpret these waits as measured network RTT.
The differing barrier spans are consistent with waiting for the slower peer,
including differing evolution-scene durations and the vanilla randomized
leader delay before the second standby. This is evidence for the exercised
synchronization path, not atomic saving or persistence after a restart.

### Post-trade input regression

After reviewing the recording and traces, `leomayca` reported that the character
could not move after the trade. `CoopLinkSpike_ReturnToField` had cleared
`gMain.callback1`, while vanilla `ReturnToFieldLocal` only rebuilds the field and
restores callback2. With no `CB1_Overworld`, player input was never processed.
The same return callback also needed to replace the link callback left by cancel.

The adapter now explicitly installs `CB1_Overworld` before returning locally.
Stage 6 state 2 additionally waits for both overworld callbacks and unlocked
field controls, so rendering the field alone no longer produces that trace.
A regression against the real adapter fails on the old code and passes after
the fix for both the animation's null callback and cancel's link callback.
The complete host suite passes with ASan/UBSan using `CC="cc -no-pie"`.

The 2026-10-29 corrected-build retest above confirms the party menus, both saved
received parties after restarting, and walking in both instances (tester
confirmation). Count that retest as the correction's manual result, rather
than the original video or host regression alone. Cancel remains unexercised.

### Missing Pokemon menu on early-game fixture saves

The tester also reported that the Start menu had no Pokemon option, preventing
the party check after closing and reopening the games. `BuildNormalStartMenu`
checks `FLAG_SYS_POKEMON_GET`, not the party count. The original fixture setup
created Pokemon before the save's starter event without setting that flag.
The missing menu alone is not evidence that the trade failed to save.

Explicit fixture opt-in now also sets `FLAG_SYS_POKEMON_GET` through vanilla
`FlagSet`. The full trade save includes that flag along with the received party.
Normal START leaves flags unchanged. The host regression fails before this fix
and passes afterward, including the guard against flag changes without opt-in.
The corrected-build restart video shows Start > Pokemon retaining the received
species on both sides; read-only disk-save inspection also finds the menu flag
set and the expected parties. The fixture-menu and persistence retest passed.

### First manual attempt: wire rejection corrected

The user's two-instance attempt verified ROM CRC32 `17ed0965` and authenticated
both `spike_a` and `spike_b`, but the server immediately rejected their first
post-welcome message with `bad_message`. The harness omitted required `playerId`
on `trade_available` and `trade_link`. The server validates the field before
replacing it with the authenticated sender ID.

Both sends now use the existing protocol builders, and the harness validates
trade fields before encoding. A regression on the real entry script failed
before the fix and passes afterward. Messages captured from that script were
also sent through an actual isolated server: availability and exact link bytes
relayed both ways, and both clients continued receiving pongs. This verifies
wire compatibility, not the pending vanilla trade-screen acceptance. The user
must reset/reload both scripting instances to exercise the corrected harness.

### Fresh-position wait and readiness race

A later screenshot stopped at ROM verification, before either client joined.
The harness intentionally waits for a fresh visible presence tuple to obtain
the game identity. The ROM publishes only changed tuples, so a Scripting Reset
while standing still may wait until the player moves or turns. The script now
prints that instruction explicitly.

Inspection also found a readiness race: a player could join after the first
availability broadcast and never receive another one once its partner started.
The harness now re-announces readiness before START. A delayed-peer regression
failed before the correction and passes afterward. Restart both copied ROMs
and reload the scripts after updating an attempted session: this throwaway
adapter does not reset/reconnect an already active virtual link in place.

Before recommending go, fill in the emulator matrix and record the tested
parent/fork revisions and sanitized logs. Production #81 still needs bounded
session state, trustworthy role assignment, robust request sequencing, a
10-second peer timeout, clean cancellation before save, and coordinated
handling of disconnects at save barriers. #83 owns the full consent/session
flow and `trade_confirm` audit emission.
