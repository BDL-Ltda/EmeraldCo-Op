# Milestone 0.2 networking acceptance

This records the three-developer session for
[issue #19](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/19).
On **2026-10-22 (America/Sao_Paulo)**, leomayca confirmed that the checked
acceptance criteria mean the team performed and verified those tests. The
results below preserve that human acceptance, supplemented by the console
excerpts supplied by leomayca. The excerpts are selected samples, not a full
session transcript or an agent-observed emulator run.

## Participants and setup

- **leomayca:** server host and mGBA player.
- **bernardosevero** and **DaviAlencastro:** remote mGBA players.
- The team confirmed all three connected over the Internet with distinct player
  IDs and observed each other's state. Host addresses and join keys are omitted.
- Emulator used for the test handoff: **mGBA 0.10.5**; host platform: Windows.
- Prepared test build: client revision
  `eea5354add0db75ccc82dce1fe626c95f95dc842`, ROM submodule
  `731ad5bfd6e6f265508d0efcca0ba42f9dcf5881`.
- Verified handoff ROM SHA1: `466dcdee6ad8e38a2cf530bec29f8a079d1106c5`;
  CRC32: `453202b6`. The ROM, saves and private configuration are not attached.

The supplied logs do not embed a client commit ID. The revision above identifies
the prepared test build; this report does not relabel the manual session as a
test of later fixes. Follow-up client fixes were reviewed and merged in
[PR #59](https://github.com/BDL-Ltda/EmeraldCo-Op/pull/59), closing dependency
#17. Hosting dependency #18 was also closed before this report was prepared.

## Acceptance results

All seven results were confirmed by the team through #19's checked acceptance
criteria and leomayca's explicit confirmation. A partial log excerpt does not
replace that confirmation or imply that unshown checks were skipped.

| Criterion | Result | Recorded evidence |
| --- | --- | --- |
| All three connect and the server shows three players | Passed | Team-confirmed three-player session. |
| Each developer sees the other two's movement | Passed | Team confirmation; supplied remote movement sample below. |
| Map changes are transmitted | Passed | Team confirmation in the checked issue criterion. |
| A player quits and the other two receive `leave` | Passed | Team confirmation and supplied `left (disconnect)` sample. |
| The same player rejoins after forced mGBA termination | Passed | Team confirmation and the same player ID/trainer ID appearing again in the supplied sample; see the replacement distinction below. |
| Fifteen minutes without unintended disconnects or stutter | Passed | Team-confirmed stable-play interval. Interruption/retry observations are recorded separately below. |
| Measured latency is recorded | Passed | Supplied client latency samples: **17 ms, 16 ms, 16 ms**. |

## Supplied console samples

### Remote movement and latency

```text
[remote] leomayca 0:9 13,10 NORTH visible

[net] latency 17 ms
[net] latency 16 ms
[net] latency 16 ms
```

These are the values in the supplied sample, not a minimum/maximum for every
player or for the whole session. The originating client was not identified in
this excerpt; do not treat the values as a three-player Internet benchmark.
They are the client's reported round-trip measurements to the relay, not
player-to-player latency.

### Leave and rejoin

```text
[remote] leomayca is here (trainerId 2873277965, gender 0)
[remote] leomayca left (disconnect)
[remote] leomayca joined (trainerId 2873277965, gender 0)
```

This records removal of the old connection followed by admission of the same
player. The manual sample does **not** contain `left (replaced)` and therefore
does not demonstrate replacement of an old connection that is still active.
An OS can close the socket when mGBA is force-terminated, allowing the server
to remove it before the player returns; `disconnect` is not evidence that the
emulator was closed cleanly.

Active duplicate-ID replacement has separate automated coverage in
`TestDuplicateReplacesAtCapacity`, `TestReplacementCanUseANewTrainerID` and
`TestReplacedReaderCannotPublishPresence` in the
[room tests](../internal/room). This distinction preserves the reported manual
crash/rejoin result without claiming a `replaced` event that was not observed.

### Connection-loss and retry observation

```text
[ERROR] [net] disconnected: the server closed the connection; retrying in 5 s
[net] connecting to the server
[ERROR] [net] connect failed: unknown error; retrying in 5 s
```

This supplementary excerpt shows detection of a closed connection and retry
behavior. It does not show a later successful connection, nor establish why
the server became unavailable. It is kept separate from the stable-play result
and from the successful same-ID rejoin sample above.

Connection attempts can block mGBA 0.10.5, particularly while the server is
unavailable. The pinned emulator's connect behavior and native error-message
limitations are documented in [mGBA scripting](mgba-scripting.md#gotchas) and
the [client networking guide](../client/README.md#networking). This acceptance
does not claim that those documented limitations were eliminated.

## Validation scope

This issue delivers a test record, not new runtime behavior. No new automated
test is necessary solely to store the session report; the existing Go and Lua
suites are re-run for the documentation PR. The ROM submodule, generated
addresses, server, protocol and Lua implementation are unchanged by this
report. ROM rebuilding/address regeneration is therefore not applicable to
this documentation change.

The session validates **network presence in the scripting console**, not remote
avatars in the game. Text debug UI and in-game rendering remain later milestone
work. CI, one human approval and merge with `Closes #19` are tracked on the
delivery PR rather than inferred from the manual acceptance checkboxes.
