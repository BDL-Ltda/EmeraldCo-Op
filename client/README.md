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

Once the ROM is verified, `bridge.lua` reads the local player state every frame
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

## Local configuration

`config.example.lua` lists every setting: `SERVER_HOST`, `SERVER_PORT`,
`PLAYER_ID`, `JOIN_KEY` and `DEBUG`. Your `config.lua` is ignored by Git. Set a
unique `PLAYER_ID` and keep any real join key and server address private. The
network settings are used by the network client
([issue #17](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/17)).

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
- `lib/`: pure modules (no `emu`, `socket` or `callbacks`), testable outside
  mGBA. `lib/romcheck.lua` compares the ROM hash.
- `tests/`: `romcheck_test.lua` and `memory_test.lua` (fake memory) run with
  plain Lua from the repository root (`lua5.4 client/tests/memory_test.lua`).
  The shared runner comes with
  [issue #16](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/16).
- `spike/`: the throwaway scripting spike from
  [issue #8](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/8).
