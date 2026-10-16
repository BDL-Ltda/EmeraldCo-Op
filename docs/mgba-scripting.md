# mGBA scripting

Findings from the scripting spike in
[issue #8](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/8). The spike script is
[client/spike/hello.lua](../client/spike/hello.lua); it is throwaway code, not the
client.

## Pinned version

Everyone uses **mGBA 0.10.5**, the latest stable release
([GitHub release](https://github.com/mgba-emu/mgba/releases/tag/0.10.5),
published 2025-03-09; also the latest stable on
[mgba.io/downloads](https://mgba.io/downloads.html)). Scripting first shipped in
0.10, and the API keeps changing in development builds, so do not use a
development build or an older 0.10.x.

Every API fact below was checked against the 0.10.5 source, not only the
[official scripting docs](https://mgba.io/docs/scripting.html), because those docs
are generated from 0.10.2. Source links point at the `0.10.5` tag:

- [`src/core/scripting.c`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/core/scripting.c):
  `emu`, memory domains, `console`.
- [`src/script/stdlib.c`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/script/stdlib.c):
  `callbacks` and the list of callback names.
- [`src/script/socket.c`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/script/socket.c):
  native socket implementation.
- [`src/script/engines/lua.c`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/script/engines/lua.c):
  the Lua `socket` wrapper (`_socketLuaSource`) and the `require` shim.
- [`res/scripts/sockettest.lua`](https://github.com/mgba-emu/mgba/blob/0.10.5/res/scripts/sockettest.lua):
  mGBA's own socket client example.

## Loading a script

1. Open a ROM in mGBA (Qt frontend).
2. **Tools > Scripting...** opens the scripting window, which has a console.
3. **File > Load script...** in that window and pick the `.lua` file.
   **File > Load recent script** reloads it.

Scripts can also be loaded before a ROM: `emu` is then `nil` until a game starts,
and the **start** callback fires when it does.

Loading a script runs it in the window's shared context. Loading the same script
twice registers its callbacks twice. **File > Reset** in the scripting window
throws the whole context away (all scripts and callbacks); do that before
reloading an edited script. The 0.10.5 Qt frontend has no command-line flag to
load a script.

`require` searches the loaded script's own directory first (`dir/?.lua` and
`dir/?/init.lua`), so the client can `require` modules from `client/lib/`
relative to its entry script.

## API used by the spike

| Call | What it does |
| --- | --- |
| `console:log(msg)`, `console:error(msg)` | Print to the scripting window. `print` output does not go there; use `console`. |
| `callbacks:add(name, fn)` | Register a callback; returns an id for `callbacks:remove(id)`. |
| `emu:read8/16/32(addr)` | Read from the GBA bus at an absolute address. |
| `emu.memory.<domain>:base()` / `:name()` | Base address and display name of a memory domain. GBA domains include `wram` (EWRAM), `iwram`, `io`, `palette`, `vram`, `oam`, `cart0` (ROM) and the save type. |
| `emu.memory.<domain>:read8/16/32(offset)` | Read relative to the domain base (not used by the spike, an alternative). |
| `emu:currentFrame()` | The core's frame counter. |
| `emu:getGameTitle()` | Title from the ROM header. |
| `socket.tcp()` | New TCP socket object. |
| `sock:connect(host, port)` | Connect. Returns `1`, or `nil, err`. **Blocking.** |
| `sock:add("received", fn)`, `sock:add("error", fn)` | Socket events, polled by mGBA once per frame. `fn` gets the socket as first argument; `error` also gets the message. |
| `sock:send(data)` | Non-blocking send. Returns bytes written (may be fewer than `#data`), or `nil, err`. |
| `sock:receive(maxBytes)` | Non-blocking receive. Returns a string, or `nil, err`. |
| `sock:hasdata()` | `select()` with a zero timeout: `true`/`false`, or `nil, err`. |
| `sock:close()` | Close and unhook the socket. |
| `socket.ERRORS.AGAIN` | The error string meaning "would block, try again". |

Callback names available in 0.10.5: `alarm`, `crashed`, `frame`, `keysRead`,
`reset`, `savedataUpdated`, `sleep`, `shutdown`, `start`, `stop`.

The spike reads memory at the **base of the `wram` and `cart0` domains**, taken
from `emu.memory` at runtime. It needs no address literal and reads no game
variables; real addresses come from `client/addresses.lua`.

## Gotchas

- **Scripts run on the emulation thread.** Anything slow in a callback slows the
  game down. All per-frame work must be short and must never wait on I/O.
- **`connect` blocks.** The docstring in 0.10.5 says so: the emulator does not
  respond until the connection succeeds or fails. Against `127.0.0.1` it returns
  at once (connected or refused). Against a remote host that drops packets it can
  freeze the game for the OS connect timeout. There is no non-blocking connect in
  0.10.5. The real client should keep reconnect attempts rare (back off) and
  expect a short hitch on each attempt against an unreachable remote server.
- **Everything after `connect` is non-blocking.** mGBA puts the socket into
  non-blocking mode after `connect`. `receive` returns `nil, socket.ERRORS.AGAIN`
  when there is nothing to read; `send` can write only part of the data.
- **Socket events only fire on frames.** A connected socket registers its own
  **frame** callback that runs `select()` with a zero timeout and dispatches
  `received` or `error`. Nothing is polled while the game is paused or before a
  ROM is running.
- **Server going away.** When the peer closes the connection, `receive` returns
  `nil, "disconnected"`. A reset connection or a `select` failure gives other
  error strings (`"unknown error"` for codes mGBA does not map). On Windows the
  error read after a zero-byte `recv` may be stale, so the spike also treats
  "readable, but the first read would block" as a closed connection.
- **`receive` is not LuaSocket's `receive`.** It takes a byte count only, has no
  line mode and returns whatever is available. The caller does its own framing.
- **`emu` is `nil` without a game.** Guard reads and use the **start** callback.
- **`print` is not the scripting console.** Use `console:log`.

## Framing

The protocol is JSON lines over TCP ([protocol.md](protocol.md)), and mGBA's socket
gives raw byte chunks. The spike shows the pattern the client needs:

- **Receive:** append each chunk to a buffer, emit every complete line ending in
  `\n`, keep the trailing partial line for the next chunk. A chunk can contain
  several lines or part of one.
- **Send:** append the line plus `\n` to an outgoing buffer, call `send` once per
  frame, drop the bytes it accepted and keep the rest.
- Drain `receive` in a loop until it returns `AGAIN`, so a burst does not wait a
  frame per chunk.

This logic is pure and belongs in `client/lib/` with unit tests; the
mGBA-specific part only moves bytes.

## On-screen drawing (canvas)

**mGBA 0.10.5 has no on-screen drawing or canvas API.** Its scripting API has no
way to draw over the game picture. The only display surface is
`console:createBuffer(name)`, a text buffer shown in the scripting window, not on
the game screen.

A canvas API (`include/mgba/script/canvas.h`, `src/script/canvas.c`,
`src/script/image.c`) exists on mGBA's `master` branch, but not in any stable
release up to 0.10.5. Using it would mean pinning a development build. For v1
this does not matter: remote players are drawn by the ROM from milestone 0.4
([architecture.md](architecture.md)).

## The spike script

[client/spike/hello.lua](../client/spike/hello.lua):

1. Prints `Emerald Co-Op bridge started` once, when loaded.
2. Registers a **frame** callback that prints a counter every 60 frames.
3. Prints `emu:read8/16/32` at the base of EWRAM and of the ROM, plus the header
   title.
4. Connects to `127.0.0.1:8765`, sends `hello from Emerald Co-Op at frame N`, then
   `ping N` every 300 frames, and logs each echoed line. Receiving is driven by
   the per-frame `select()` poll, so the game never waits for the network.
5. When the server goes away it logs the error, keeps running and tries to
   reconnect every 300 frames (about 5 seconds).

### Test it

Run the echo server from the repository root (`nc -l 8765` also works for one
connection):

```sh
go run ./cmd/echoserver
```

Then open any ROM in mGBA 0.10.5, load `client/spike/hello.lua` as described
above and play. The console should show the start line, a frame counter every
second, the memory dump and the echoed lines. Stop the server: the console logs
the disconnect and the reconnect attempts, and the game keeps running at full
speed. Start the server again: the script reconnects.
