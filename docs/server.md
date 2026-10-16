# Server development

`cmd/server` implements the connection lifecycle from
[#13](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/13). It uses the Go standard
library and the existing [protocol](protocol.md). There is one global room.

## Configuration

| Flag | Environment fallback | Default |
| --- | --- | --- |
| `-addr` | `SERVER_ADDR` | `:8765` |
| `-join-key` | `SERVER_JOIN_KEY` | Required; no default |
| `-max-players` | `SERVER_MAX_PLAYERS` | 5; allowed range 1–5 |

An explicit flag overrides its environment variable. The capacity cannot exceed
five because a protocol v1 welcome can contain at most four other players.
The key follows the protocol's 1–64 character, no-control-character rule.
Invalid settings fail before listening. Help and configuration errors do not
print the key, including when it comes from the environment.

For a local-only listener in PowerShell:

```powershell
$env:SERVER_JOIN_KEY = Read-Host "Local test join key"
go run ./cmd/server -addr localhost:8765
```

The default address binds all interfaces; actual online hosting and port
forwarding remain in [#18](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/18).
Keep keys and public addresses private. Ctrl+C closes the listener, accepted
players and connections still waiting for hello, and waits for handlers to exit.

## Connection lifecycle

1. Read a valid `hello` within five seconds of connection. Unknown message types
   are logged and ignored without extending this deadline.
2. Check the shared key before checking capacity or replacing an existing ID.
3. Reject a new ID if the configured capacity is reached. An authenticated
   duplicate replaces the old connection even when the room is full.
4. For a replacement, close the old connection and announce `leave(replaced)`.
5. Send the newcomer a `welcome` listing everyone else, sorted by `playerId`.
   Then announce `join` to the other players. The newcomer does not receive its
   own `join`.
6. On disconnect, remove that exact connection and announce `leave(disconnect)`.
   Cleanup of a replaced connection cannot remove its successor.

The room uses a mutex to serialize membership and notification order. Each
connection also serializes writes so errors and broadcasts cannot interleave
JSON lines. Writes have a five-second deadline. A failed write closes that
peer; its reader performs removal. Writes currently hold the room mutex, so a
slow reader can delay lifecycle events. Buffered queues and slow-client isolation
belong to #14; this is not yet a complete public relay.

Rejections send one `error` and close. Wrong versions produce `version_mismatch`,
wrong keys `bad_key`, and full rooms `room_full`. A valid non-hello first message,
an invalid hello field or expiry of the hello deadline produces `bad_hello`.
Malformed envelopes/JSON and oversized lines produce `bad_message`. After
admission, malformed messages and known server-only messages (or another hello)
are rejected; unknown types remain ignored. An orderly socket close produces
only the leave notification.

Logs include the event, remote address, player ID when validated, and rejection
or leave reason. Raw messages, unknown type names and decoder errors are not
logged: these could contain secrets. The join key is never logged.

## Current boundary

Presence relay, presence updates, ping/pong, rate limits and the 15-second
inactivity timeout are implemented by
[#14](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/14), not this lifecycle.
Valid presence and ping messages are currently decoded but have no effect.
New connections therefore have no last presence; welcome supports copying it
once #14 populates it. A client that remains connected after hello is not yet
evicted for silence. Client networking and fakeclient are separate issues.

## Verify with two TCP sessions

Run `go vet ./...` and `go test -race ./...` first. For a shell smoke test, start
the local server above, then run `nc localhost 8765` in two terminals. Send each
hello within five seconds of opening that connection. Replace `<local-key>`
privately with the key you entered; never post that line or your shell history.

Terminal A:

```text
{"v":1,"type":"hello","playerId":"a","joinKey":"<local-key>","trainerId":1,"gender":0,"clientVersion":"0.2.0"}
```

Expect a welcome with `players:[]`. In terminal B:

```text
{"v":1,"type":"hello","playerId":"b","joinKey":"<local-key>","trainerId":2,"gender":1,"clientVersion":"0.2.0"}
```

B receives a welcome containing A. A receives B's join. Close B: A receives
`leave` for B with reason `disconnect`. Reopen B using A's ID to check replacement:
the old A socket closes. With a third observer connected, it sees
`leave(replaced)` before the new `join`. A PowerShell `System.Net.Sockets.TcpClient`
can perform the same line exchanges when `nc` is unavailable on Windows.
