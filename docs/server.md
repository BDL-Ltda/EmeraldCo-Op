# Server development

`cmd/server` implements the connection lifecycle from
[#13](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/13) and presence/liveness
from [#14](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/14). It uses the Go
standard library and the existing [protocol](protocol.md). There is one room.

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

The default address binds all interfaces. For IPv4 hosting, TCP-only port
forwarding, a scoped Windows firewall rule and an external fakeclient test,
follow [Playing online](playing-online.md). The real-network validation status
is tracked in [#18](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/18).
Keep keys and public addresses private. Ctrl+C (or SIGTERM on a service host)
closes the listener, accepted players and connections still waiting for hello,
and waits for handlers to exit.

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

Replacement is keyed by `playerId`, as specified in #13, even if a new save
changes `trainerId`. The trainer ID is self-reported metadata, not proof that
a client owns a player ID. Requiring matching trainer IDs would change that
contract and needs a separate identity-policy decision.

The room uses a mutex to serialize membership, snapshots and notification order.
Each authenticated client has a FIFO queue of **64 encoded lines** and its own
writer goroutine. Enqueuing never waits for a socket or queue space. Welcome is
queued before admission and later messages, so it remains the newcomer's first
message. No socket writes run under the room mutex.

If a queue is full, the server logs `drop` with `send_queue_full`, removes that
client, closes its socket and announces `leave(disconnect)`. Other players keep
receiving messages. Writes also have a five-second deadline; failed writes close
that socket and its reader removes the connection. Terminal protocol errors
detach the player, stop queued output and attempt to send one error before
closing. Only that client's handler can wait on its writer deadline; other
clients continue. Cancellation closes sockets and waits for readers and writers.

Temporary listener accept failures retry after 5 ms, doubling up to one second,
without removing existing players. A successful accept resets the delay;
cancellation interrupts the wait. Permanent listener errors still stop the
server. Join keys use the shared protocol validator and a constant-time content
comparison for equal-length keys (unequal lengths are rejected immediately).

Rejections send one `error` and close. Wrong versions produce `version_mismatch`,
wrong keys `bad_key`, and full rooms `room_full`. A valid non-hello first message,
an invalid hello field or expiry of the hello deadline produces `bad_hello`.
Malformed envelopes/JSON and oversized lines produce `bad_message`. After
admission, malformed messages and known server-only messages (or another hello)
are rejected; unknown types remain ignored. An orderly socket close produces
only the leave notification.

A reset or closed socket during hello is a transport failure, not a
`bad_message` rejection; no error response is attempted. The five-second hello
timeout still produces `bad_hello`. Unknown messages are ignored in both phases,
with only the first one logged per connection. This bounds unknown-message logs;
the pending-handshake cap below bounds the sockets themselves.

## Pending handshakes

At most **16 connections** can be waiting for a hello with the correct join key
at the same time ([#50](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/50)).
That is about three times the room capacity, so a whole room can reconnect at
once. The cap is a server constant, like the send queue and timeouts.

- A connection holds a slot from accept until its join key matches. A
  rejection (`bad_key`, `bad_hello`, `bad_message`, `version_mismatch`), a
  closed or reset socket, the five-second hello timeout, and shutdown also free
  it. A key-matched hello that then gets `room_full` has already freed its slot.
- When all 16 slots are in use, the server accepts each new connection and
  closes it at once: no read, no `error` reply (the protocol has no code for
  it) and no handler goroutine. A client sees a plain disconnect and should
  retry later. The log gets one `event=pending_full` line per overload episode;
  the next connection that gets a slot ends the episode.
- Authenticated players are not counted. An idle-connection flood can delay new
  joins by up to the hello timeout, but established players keep relaying,
  pinging and timing out normally.

These limits stack. The pending-handshake cap bounds unauthenticated
descriptors and handlers. The configured room capacity (`-max-players`) bounds
authenticated players and is checked only after the key matches. The
per-connection message rate (50 per rolling second) and line-size limits apply
to each socket in both phases.

Logs include the event, remote address, player ID when validated, and rejection
or leave reason. Raw messages, unknown type names and decoder errors are not
logged: these could contain secrets. The join key is never logged.

## Presence, liveness and limits

- A valid `presence` has its `playerId` overwritten with the authenticated
  connection's ID before it is stored and queued to every other room member.
  It is never echoed to the sender. Welcome includes each existing player's
  last presence, if available. A replaced reader cannot update its successor.
- `ping` replies with `pong`, preserving the exact integer `t`. Clients should
  send one every five seconds, including when they have not moved.
- After hello, **15 seconds without a complete message** closes that connection
  and broadcasts `leave(timeout)`. Receiving a partial line does not extend the
  deadline. Complete unknown messages count as activity but still share the
  message-rate limit; the pre-hello five-second deadline remains fixed.
- Each connection can send **50 complete messages in any rolling one-second
  window**. Hello, ping, presence and unknown types all count, before and after
  authentication. The 51st message sends `error bad_message` and closes; known
  malformed messages already reject immediately. This is per connection, not a
  room-wide cap.
- Protocol line-size, configured room-capacity and
  [pending-handshake](#pending-handshakes) limits still apply. The send queue,
  timeouts and pending cap are server constants; only address, key and capacity
  have CLI configuration.

Use the [fake client](fakeclient.md) to exercise the relay without an emulator.
The mGBA client connects with [`client/net.lua`](../client/README.md#networking).
Interpolation and ROM rendering remain separate work. The relay does not synchronize saves or battles.

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

While both clients are connected, send a ping from A:

```json
{"v":1,"type":"ping","t":1712345678901}
```

A receives a pong with the same `t`. Then send presence from B (using A's ID
deliberately tests that the server overrides it):

```json
{"v":1,"type":"presence","playerId":"a","mapGroup":0,"mapNum":9,"x":5,"y":3,"facing":1,"visible":true}
```

A receives that presence with `playerId` set to `b`; B gets no echo. A new client
gets this state in welcome. To test timeout, keep A pinging every five seconds
and let B stop sending: A sees `leave(timeout)` after about 15 seconds. Automated
tests cover flooding and deterministic socket backpressure. For the same smoke
scenario with simulated walking players, follow the [fake client guide](fakeclient.md#verify-two-clients-locally).
