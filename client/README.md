# mGBA Lua client

The Lua 5.4 client for mGBA 0.10.5. The emulator API it relies on is described
in [mGBA scripting](../docs/mgba-scripting.md).

Milestones 0.1-0.3 read local player state using addresses generated from our
built ROM's ELF. From 0.4, the client bridges the ROM mailbox and the TCP socket.
See the [architecture](../docs/architecture.md) and
[memory map](../docs/memory-map.md).

## Running it

1. Put the Emerald Co-Op folder in a path with **only ASCII characters**, e.g.
   `C:\EmeraldCoop`. Lua in mGBA on Windows can't open files under folders
   such as `C:\Users\Usuário\...` (see
   [mGBA scripting](../docs/mgba-scripting.md#gotchas)).
2. Copy `config.example.lua` to `config.lua` and fill it in.
3. In mGBA 0.10.5, load our built ROM, then **Tools > Scripting... > File >
   Load script...** and pick `client/bridge.lua`.

At startup `bridge.lua` checks, in this order, and stops with a clear error
on the first problem. The game itself keeps running.

| Check | On failure |
| --- | --- |
| Lua can open files in the client folder | `Lua in mGBA cannot open files in this folder because its path has non-ASCII characters (...)` |
| `config.lua` exists and returns a table | `config.lua not found. Copy client/config.example.lua to client/config.lua and fill it in.` |
| `addresses.lua` loads | `addresses.lua not found. ...` |
| The loaded ROM's CRC32 equals `romCrc32` | `ROM mismatch: expected <x>, got <y>. Apply the matching .bps patch.` |

On success it logs `ROM verified (<crc32>)`. The check runs again whenever
another game is loaded with the script still running.

## Player state

Once the ROM is verified, `bridge.lua` reads the local player state once per game
loop (in mGBA's `keysRead` callback, see the
[memory map](../docs/memory-map.md#when-to-read-the-keysread-callback))
with `memory.lua` and logs it **only when it changes**:

```text
[state] no position  hidden
[state] trainerId 12345  gender 0
[state] map 0:9  pos 5,3  facing SOUTH  visible
```

`getPlayerState()` returns `mapGroup`, `mapNum`, `x`, `y` (map coordinates),
`facing` (the game's `DIR_*` value), `visible`, `gender` and `trainerId`.
`visible` is true for the whole game session and false before a game starts
(title screen, main menu, new-game intro). During map loads, battles and
full-screen menus the position keeps the last snapshot read in the field. On a
soft reset the last snapshot is reported once as `hidden` and then dropped;
position fields stay `nil` until the new session has a fresh snapshot. The
rules and every offset are in
[memory map: player state](../docs/memory-map.md#player-state).

## Networking

`net.lua` connects to the [relay server](../docs/server.md) with the settings in
`config.lua` and speaks the [protocol](../docs/protocol.md). It waits until a
game session is running, because `hello` carries the save's `trainerId` and
`gender`. Then it:

1. connects and sends `hello`;
2. after `welcome`, sends `presence` whenever the tile, map, facing or
   `visible` changes (at most once every 2 frames, below the server's rate
   limit), and a `ping` every 5 seconds;
3. logs the other players and the round-trip latency:

```text
[net] connecting to the server
[net] connected; sending hello
[net] joined as bernardo; 1 other player(s) online
[remote] leo is here (trainerId 12345, gender 1)
[remote] leo 0:9 7,5 WEST visible
[remote] davi joined (trainerId 54321, gender 0)
[remote] davi 1:4 12,8 NORTH visible
[net] latency 42 ms
[remote] davi left (disconnect)
```

Latency is logged on the first pong and then about once a minute (every pong
with `DEBUG = true`). It is measured in frames (about 16.7 ms each), because
mGBA only polls sockets once per frame; the clock stops while the game is
paused.

Socket reads and sends never wait. **Connecting does**: mGBA's `connect`
blocks the game until it succeeds or fails, which on Windows takes about 2 s
when no server is listening ([mGBA scripting](../docs/mgba-scripting.md#gotchas)).
After a lost connection or a failed attempt the client retries every 5 seconds,
so expect a short freeze every 5 s while the server is down.

| Log | Meaning and what to do |
| --- | --- |
| `network disabled: <setting> ...` | A network setting in `config.lua` is invalid. The player state is still logged. Fix it and reload the script. |
| `the server rejected this client: bad_key (...)` then `stopped` | Wrong `JOIN_KEY`. Fix `config.lua` and reload the script; it does not retry. |
| `version_mismatch`, `bad_hello` or `another protocol version`, then `stopped` | Client and server are from different revisions. Update, then reload the script. |
| `room_full` | Five players are already connected. Retried every 5 s. |
| `disconnected: ...; retrying in 5 s` | The connection was lost; it reconnects with a new `hello`. |
| `ignoring an invalid message from the server: ...` | The server sent a message that breaks the protocol rules. It is skipped; report it. |

Loading another save (a new `trainerId` or `gender`) reconnects at once with a
new `hello`; the server replaces the old connection. Logs never contain the
join key, the server address or raw messages.

To try it locally, run the server (see [server development](../docs/server.md))
with `SERVER_HOST = "127.0.0.1"` in `config.lua`, load the bridge in two mGBA
instances with different `PLAYER_ID`s, or in one plus a
[fake client](../docs/fakeclient.md).

## Local configuration

`config.example.lua` lists every setting: `SERVER_HOST`, `SERVER_PORT`,
`PLAYER_ID`, `JOIN_KEY` and `DEBUG`. Your `config.lua` is ignored by Git. Set a
unique `PLAYER_ID` and keep any real join key and server address private. The
network settings are used by the [network client](#networking); `DEBUG = true`
also logs each presence sent and every ping's latency.

## Generated addresses

[`addresses.lua`](addresses.lua) is generated and committed. It is the only
source of global memory addresses for the client; never guess addresses, edit
the generated file or copy numeric values into other modules. It also records
the ROM's `romSha1` and `romCrc32`; the client compares `romCrc32`.

See [Generating client addresses](../README.md#generating-client-addresses) for
the command, required build inputs, allowlist, validation and regeneration rules.

## Layout and tests

- `bridge.lua`: entry point loaded in mGBA.
- `memory.lua`: reads the player state through the bus it is given (`emu` in
  mGBA). The only place with struct offsets, in one table at the top.
- `net.lua`: the network client. It gets mGBA's socket, the console and a
  clock from `bridge.lua`, so tests drive it with fakes.
- `lib/`: pure modules (no `emu`, `socket` or `callbacks`), testable outside
  mGBA. `romcheck.lua` compares the ROM hash; `json.lua` and `framing.lua`
  provide the transport primitives described below; `protocol.lua` builds the
  client's messages and validates the server's.
- `tests/`: the tiny runner discovers every `*_test.lua` directly in this
  folder, sorts suites and test names, prints pass/fail and exits non-zero on
  failure. It includes ROM checks, fake-memory player-state checks, every
  JSON example in `docs/protocol.md`, message validation and the network
  client driven by a fake socket and clock.
- `spike/`: the throwaway scripting spike from
  [issue #8](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/8).

From the repository root, with plain Lua **5.4** and luacheck installed:

```sh
lua5.4 client/tests/run.lua
luacheck client/
```

On Windows, the interpreter may be named `lua54.exe`; use `luacheck client`
without the trailing slash if the Windows build rejects it. No ROM, emulator
or private configuration is needed. CI runs both checks unconditionally.
New suites return a non-empty table of named functions:

```lua
return {
    ["one plus one"] = function() assert(1 + 1 == 2) end,
}
```

The runner temporarily accepts older standalone suites that return nothing;
they must throw or exit non-zero on failure. Each is counted as one suite-level
check, while returned functions are counted individually. This keeps the player
memory tests from #11 compatible; new tests should use the table format.

## Pure JSON codec

`require("json")` exposes `encode(value)` and `decode(text)`. Each returns a
value on success, or `nil, error` on failure. Test the **error**, not the value:
decoded JSON `false` is a successful Lua `false`. Errors never echo input text.
There are no external dependencies.

- Objects have string keys. Dense, non-empty Lua sequences encode as arrays;
  an untagged empty table encodes as `{}`. Use `json.array()` for `[]` and
  `json.object()` to explicitly mark an object. Decoding preserves both shapes.
- `json.null` represents JSON `null`, retaining object fields and array slots.
  Lua `nil` also encodes as `null`; sparse or mixed-key tables are rejected.
- Numbers must be Lua integers / JSON integer tokens in Lua 5.4's signed
  64-bit range. Fractions, exponents and floating-point Lua values are rejected,
  so trainer IDs and timestamps never silently lose precision.
- Strings must be valid UTF-8. JSON escapes, including UTF-16 surrogate pairs,
  are decoded; lone surrogates, malformed escapes and raw control bytes fail.
- Duplicate object keys, cycles and more than 64 nested containers fail.
  Encoding is deterministic: `v` and `type` come first when present, then other
  keys sort lexically. `<`, `>` and `&` remain unescaped, matching the Go codec.

`encode` returns JSON text without LF; the network client must also enforce
the outgoing line limit and add the separator. The codec handles JSON
representation, not message validation. Checking version,
required fields, ranges and unknown message types is `protocol.lua`'s job (see
[Networking](#networking)).

## Pure line framing

`require("framing").new(limit)` creates a framer, or returns `nil, error` for an
invalid limit. The default is the protocol's **4096 bytes excluding LF**.

```lua
local framing = require("framing")
local framer = assert(framing.new())
assert(#framer:feed('{"v":1,') == 0)
local lines = assert(framer:feed('"type":"ping","t":1}\n'))
-- lines[1] is the complete JSON text without LF; decode it separately.
assert(framer:finish())
```

`feed(bytes)` returns all complete lines in order and keeps only the unfinished
tail. It preserves empty lines and all bytes other than the separating LF
(including CR); chunks may split a UTF-8 character or JSON escape. The tail is
bounded by the configured byte limit, even for one huge chunk. An oversized
line rejects the entire current batch, clears the tail and permanently fails
that framer. Close the rejected stream and create a new framer for a new one.
`finish()` checks EOF: it returns `true` for a clean end, or `nil, error` and
fails the framer if a partial line remains. It never emits an unterminated line.
