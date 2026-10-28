# Co-op trade attendant

Issue [#82](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/82) connects the
Pokémon Center 2F Direct Corner attendant to the v2 trade controls. All towns
use the shared `CableClub_EventScript_DirectCornerAttendant` script. Choose
**Co-op trade** there; **Link services** still opens the original cable or
wireless menus. The Union Room attendant retains its original behavior.

The existing checks still apply: the Pokédex must be obtained, Bad Eggs are
rejected, the party needs at least two Pokémon, and an Enigma Berry cannot be
traded. No Pokémon or save data changes during this invitation flow.

## Waiting and invitations

The native task in `rom/src/coop/trade.c` owns one field window. The script
locks the player until the task finishes. Up/down selects a peer by their
configured `PLAYER_ID`; A invites them. Only connected peers advertising
`trade_available: true` appear, regardless of town, map or avatar visibility.
The list contains at most four IDs and retains the selected ID when refreshed.
ASCII IDs are validated and converted to Emerald glyphs, including underscores.

`client/lib/trade.lua` owns the invitation state machine. `bridge.lua` passes
it ROM commands and validated server events; it publishes complete snapshots
through the existing fragmented mailbox. Neither ROM task nor Lua module
reads game structs through hard-coded addresses. See the
[mailbox payloads](memory-map.md#trade-attendant-payloads).

| State | Availability | Inputs / exit |
| --- | --- | --- |
| Closed | false | Choose Co-op trade to enter waiting. |
| Waiting | true | A invites the selected ID; B leaves the attendant. |
| Inviting | false | Selected peer accepts/declines; B cancels and leaves. |
| Invited | false | A accepts; B declines and returns to waiting. |
| Ready | false | Both clients have the session handoff; B cancels and leaves. |

Both invitation states have a **30-second** deadline, checked before inputs
and network replies as well as each update. The bridge uses the existing
wall-clock-bounded, monotonic `netclock` so fast-forward cannot accelerate it.
Timeout/decline returns to waiting with a notice. B at the waiting list closes
the window and releases the script. A socket drop clears the mailbox connected
flag; the native task releases the script and shows the unavailable-connection
message. Reconnection requires entering the attendant again.

The relay broadcasts every trade message. The state machine accepts a reply
only from the selected partner, addressed to its own ID. A busy client replies
`trade_decline: busy` to other inviters. Duplicate partner invites are ignored.
For crossing invites, the smaller ID (Lua string ordering) remains inviter and
the other becomes invitee, with an explicit accept prompt.

The wire v2 messages have no invitation nonce. To prevent a delayed accept
from accepting a later retry, cancellation/decline drains the old conversation
before that peer becomes selectable again. A matching terminal decline/cancel
releases this barrier; an active partner acknowledges a terminal control with
one `trade_cancel: canceled`. An unmatched cancel is ignored, so acknowledgments
do not loop. Old accepts received behind the barrier are canceled. Socket FIFO
puts them before the terminal reply. A fresh advertisement after that reply
allows another invitation. Leave/replacement/reset discards the old peer state.

Waiting clients re-advertise when another peer joins, because the server stores
no availability. Leaving removes the peer immediately. The bridge keeps at
most 16 unsent controls and retries under the existing socket budget (20
messages per clock second, shared with ping/presence). Queue overflow closes
the connection so the server's leave removes stale availability. UI snapshots
coalesce while the mailbox is full; native cancel retries a full outbound ring.

## Session boundary

Acceptance sets **Ready** at both clients. `trade.getSession()` returns
`{ partnerId, initiator }` only in that state. This is the handoff for
[#83](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/83), which depends on this
issue and the virtual link in #81. The native UI currently says
“Trade partner ready. Trading is not available yet.” and allows B to cancel.
It does **not** start vanilla trading, exchange party/link data, confirm a trade
or save a Pokémon. #83 must consume the handoff, start its session on both ends,
and implement the return/cancel path. Full “accept starts a trade session”
acceptance remains pending until that integration exists.

## Validation

Automated Lua tests exercise two/three state machines behind a broadcast relay,
target filtering, all cancellation paths, the exact deadline, crossing invites,
delayed accepts, resets and bounded backpressure. Adapter tests exercise the
real `bridge.lua` entry point. ROM host tests execute the real native task and
decoder with engine doubles and ASan/UBSan, including full-ring cancellation,
disconnect cleanup, allocation failures and 16-character ID rendering. The ARM
ROM build checks the production engine headers and shared scripts.

### Multiplayer acceptance checklist

Use the ROM matching `client/addresses.lua`, protocol v2 server and current
bridge at **all** clients. Use copies of in-game saves; save states from another
ROM build are unsuitable. Record the exact ROM SHA1, commit, developer names,
screenshots/logs and results in the PR. At least two developers must test.

1. Put two players in different towns with eligible parties. Talk to the right
   Cable Club attendant on each 2F and choose Co-op trade. Confirm mutual IDs;
   a third connected player who has not entered the attendant must be absent.
2. Invite the second player. Confirm only that player gets the named accept
   prompt, while the inviter waits. Decline with B: both return to waiting with
   the inviter notified. Invite again and cancel with B on the inviter: its
   window closes, the recipient returns to waiting, and the inviter disappears.
3. Invite and leave the prompt unanswered for 30 real seconds. Both return to
   waiting and report a timeout. Try again to check cancellation/retry cleanup.
4. Accept: both show the Ready message. The third waiting player cannot select
   either busy peer. B cancels the Ready handoff; verify cleanup on both ends.
   Starting the actual vanilla trade screen remains a separate #83 test.
5. Disconnect/close one client's bridge while waiting and while invited.
   Confirm it disappears from the other list; local connection loss releases
   the script. Reconnect, re-enter the attendant and confirm no old prompt.
6. Enter the list after another player is already waiting (including joining
   the server later). Check availability replay and refresh/selection behavior.
7. Check a one-Pokémon party is rejected. Verify the original Link services
   menu remains accessible and no party/save data changed during these tests.

Human multiplayer and emulator UI results must be recorded separately from
automated tests; passing the latter does not complete this checklist.
