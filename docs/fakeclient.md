# Fake client

`cmd/fakeclient` simulates a player over the existing
[protocol](protocol.md) using Go's standard library. It lets developers exercise
the server without mGBA, a ROM or a Lua client. It does not render anything or
change game state.

## Configuration

Run commands from the repository root with the Go version pinned in `go.mod`.

| Flag | Default | Behavior |
| --- | --- | --- |
| `-addr` | `localhost:8765` | Server TCP address. |
| `-id` | Required | Player ID: 1–16 letters, digits, underscores or hyphens. Use different IDs for independent players. |
| `-key` | `FAKECLIENT_JOIN_KEY` environment fallback | Shared join key; required, 1–64 characters with no control characters. An explicit flag overrides the environment. |
| `-pattern` | `square` | `square`, `idle` or `warp`. |
| `-steps-per-sec` | `4` | Finite number greater than zero and at most 40. Controls walking speed. |

Prefer the environment fallback so the key does not appear in the command line
or shell history. In PowerShell, enter it privately:

```powershell
$env:FAKECLIENT_JOIN_KEY = Read-Host "Local test join key"
go run ./cmd/fakeclient -id bot1
```

Do not post real keys, public server addresses or raw hello messages. Logs show
human-readable events, not raw payloads or join keys. They cover welcome and its
player snapshot, joins, presence, leaves, pong, errors and unknown messages.
Unknown message types are reported and ignored without logging their payloads.

## Simulated behavior

The client sends `hello` with the chosen ID and key, `trainerId: 0`, `gender: 0`
and `clientVersion: "fakeclient"`. These are synthetic test metadata, not values
read from a save. It waits up to five seconds for `welcome` before starting the
simulation and sends an initial presence at `(5,3)` in map `0:9`.

| Pattern | After the initial presence |
| --- | --- |
| `square` | Walk four tiles east, four south, four west and four north; repeat the 16-step loop, updating facing with movement. Send presence for each step. |
| `idle` | Stay in place and send no further presence; keep the heartbeat running. |
| `warp` | Keep walking the square and switch between maps `0:9` and `1:0` every three seconds. Map switching is independent of walking speed and sends an updated presence. |

Every pattern sends `ping` every five seconds with the current Unix timestamp
in milliseconds. A server `ping` is answered with `pong` carrying the same
timestamp. Ctrl+C closes the connection; unexpected disconnects, rejected
sessions and invalid settings exit non-zero. There is no automatic reconnect.

## Verify two clients locally

The server includes the connection lifecycle from
[#13](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/13) and the presence relay
and heartbeat from [#14](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/14),
merged in [PR #52](https://github.com/BDL-Ltda/EmeraldCo-Op/pull/52). These checks
work with the server in this checkout; see
[Server development](server.md#presence-liveness-and-limits) for its behavior
and limits. The fake client does not implement server-side relay behavior.

Use three terminals in the same checkout. In the server terminal, enter a
private local test key and bind only to localhost:

```powershell
$env:SERVER_JOIN_KEY = Read-Host "Local test join key"
go run ./cmd/server -addr localhost:8765
```

In client terminal A, enter the same key:

```powershell
$env:FAKECLIENT_JOIN_KEY = Read-Host "Local test join key"
go run ./cmd/fakeclient -addr localhost:8765 -id bot1 -pattern square
```

In client terminal B, enter the same key:

```powershell
$env:FAKECLIENT_JOIN_KEY = Read-Host "Local test join key"
go run ./cmd/fakeclient -addr localhost:8765 -id bot2 -pattern warp -steps-per-sec 2
```

A receives B's join. B's welcome lists A and its last known presence, if A has
sent one. Both clients print the other player's movement; A
also shows B switching maps every three seconds. The server does not echo a
client's own presence. Wait at least five seconds to see pong responses.

Stop B with Ctrl+C and check that A prints B's leave. Restart B with
`-pattern idle`: A should receive its initial presence, then no movement while
the heartbeat keeps B connected. Stop both clients and the server after testing.
You can remove the test key from each client shell with
`Remove-Item Env:FAKECLIENT_JOIN_KEY`, and from the server shell with
`Remove-Item Env:SERVER_JOIN_KEY`.

Record joins, peer presence, map switches, heartbeat and leave results in the
pull request, including the tested revision. Older lifecycle-only checkouts
without #14 do not relay movement or answer pings; their join/leave output is
not evidence of a complete multiplayer relay test.
