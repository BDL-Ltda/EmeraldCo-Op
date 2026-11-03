# Connection options

Findings from the spike in
[issue #70](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/70): can joining a
session get simpler, and can it work without the Lua bridge? This is research.
It changes nothing in the ROM, the mailbox, the protocol, the server or the
production Lua client. The architecture in [architecture.md](architecture.md)
still applies. Any migration needs its own reviewed issue.

## Summary

| Option | What it is | Verdict |
| --- | --- | --- |
| **A. ROM-only** on unmodified mGBA | The ROM opens network connections by itself | **No-go.** The emulated GBA has no network device, and nothing in mGBA 0.10.5 exposes host sockets to ROM code. |
| **B1. JOY Bus link + local helper** on unmodified mGBA | The ROM talks to a local Go helper through mGBA's built-in *Connect to Dolphin* link. The helper talks to the relay. | **Unproven candidate.** The source supports it, but nobody has run it, throughput is unmeasured, and it needs new ROM code. The [probe](#evidence-the-joy-bus-probe) is the next step. |
| **B2. Custom frontend or mGBA fork** | Our own build of mGBA (or a program built on libmgba) with a native bridge | **Feasible but no-go for now.** The public core API supports it, but we would have to maintain an emulator build. |
| **C. Launcher that keeps Lua** | An installer/launcher that sets up config, folders and the ROM, then starts stock mGBA | **Go, as a UX improvement only.** It is **not** Lua removal. On 0.10.5 the player still loads the script by hand (about three clicks). |

**Recommendation:** keep the Lua bridge. Improve installation with a launcher
(C) after the v1 release ([#27](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/27)),
without blocking it. Run the JOY Bus probe before spending anything more on
B1. Do not fork mGBA. See [Recommendation](#recommendation) and the
[draft follow-ups](#draft-follow-up-issues).

### Terms used here

- **ROM-native UX:** joining feels like part of the game, for example a
  *Connect* entry in an in-game menu. It says nothing about where the sockets
  live. Every option below needs a host program for the network. Only the
  in-game controls can live in the ROM.
- **Host-native transport:** the TCP connection to the relay is owned by
  compiled host code (a helper process or the emulator), not by a Lua script.
- **Lua-free implementation:** no Lua script runs at all. B1 and B2 are
  Lua-free; C is not.
- **Simpler UX:** fewer manual setup steps. Option C delivers only this.

## Sources

Every emulator claim is checked against the **mGBA 0.10.5** source tag (the
pinned version; see [mgba-scripting.md](mgba-scripting.md)). Links point at
<https://github.com/mgba-emu/mgba/tree/0.10.5>. Short names used below:

| Short name | File at tag `0.10.5` |
| --- | --- |
| `dolphin.c` | [`src/gba/sio/dolphin.c`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/gba/sio/dolphin.c) |
| `joybus.c` | [`src/gba/sio/joybus.c`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/gba/sio/joybus.c) |
| `sio.c` | [`src/gba/sio.c`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/gba/sio.c) |
| `sio.h` | [`include/mgba/internal/gba/sio.h`](https://github.com/mgba-emu/mgba/blob/0.10.5/include/mgba/internal/gba/sio.h) |
| `interface.h` | [`include/mgba/gba/interface.h`](https://github.com/mgba-emu/mgba/blob/0.10.5/include/mgba/gba/interface.h) |
| `io.c` / `io.h` | [`src/gba/io.c`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/gba/io.c), [`include/mgba/internal/gba/io.h`](https://github.com/mgba-emu/mgba/blob/0.10.5/include/mgba/internal/gba/io.h) |
| `core.h` | [`include/mgba/core/core.h`](https://github.com/mgba-emu/mgba/blob/0.10.5/include/mgba/core/core.h) |
| `socket.h` | [`include/mgba-util/socket.h`](https://github.com/mgba-emu/mgba/blob/0.10.5/include/mgba-util/socket.h) |
| `commandline.c` | [`src/feature/commandline.c`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/feature/commandline.c) |
| `config.c` | [`src/core/config.c`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/core/config.c) |
| `core.c` | [`src/core/core.c`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/core/core.c) |
| `Window.cpp` | [`src/platform/qt/Window.cpp`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/platform/qt/Window.cpp) |
| `CoreController.cpp` | [`src/platform/qt/CoreController.cpp`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/platform/qt/CoreController.cpp) |
| `DolphinConnector.cpp` / `.ui` | [`src/platform/qt/DolphinConnector.cpp`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/platform/qt/DolphinConnector.cpp), [`DolphinConnector.ui`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/platform/qt/DolphinConnector.ui) |
| `ScriptingController.cpp` | [`src/platform/qt/scripting/ScriptingController.cpp`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/platform/qt/scripting/ScriptingController.cpp) |
| `sdl/main.c` | [`src/platform/sdl/main.c`](https://github.com/mgba-emu/mgba/blob/0.10.5/src/platform/sdl/main.c) |
| `LICENSE` | [`LICENSE`](https://github.com/mgba-emu/mgba/blob/0.10.5/LICENSE) (MPL-2.0) |

**Local observations** (mGBA 0.10.5 Qt on Windows 11, `mGBA.exe`, recorded
for this spike and in [#8](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/8)):

- `mGBA.exe --help` lists no `--script` option, only `-b`, `-c`, `-C`, `-l`,
  `-t`, `-p`, `-s`, `-g`, the scale and fullscreen options, `--ecard` and
  `--mb`.
- Scripts are loaded through **Tools > Scripting**. Its console also accepts
  Lua such as `dofile(...)`.
- Lua's `dofile` could not open a path containing a non-ASCII user name
  (`Usuário`). 8.3 short paths were needed (see also
  [mgba-scripting.md](mgba-scripting.md#gotchas)).
- The Windows installer also installs `mgba-sdl.exe` next to `mGBA.exe`.

One fact comes from upstream development and is **not** in any release:
[commit `9005770`](https://github.com/mgba-emu/mgba/commit/90057703b53f40aa355d5e331f771bf7914107ba)
(2025-04-28, "Qt: Add support for running scripts at startup") adds an
autorun script list stored in the Qt config (`autorunSettings`). The latest
release is still 0.10.5 (2025-03-09), so we can't rely on it yet.

## 1. Capability boundary

### What ROM code can reach

ROM code runs on the emulated ARM7. It can read and write the GBA memory map
and I/O registers. That's all it can touch. A real GBA has no network
hardware, so a ROM can only reach the host through a device that the emulator
backs with host code. In mGBA 0.10.5 these are:

| Emulated device | Host backing in 0.10.5 | Useful as a relay transport? |
| --- | --- | --- |
| Serial port, multiplayer/normal mode | `lockstep.c`: link cable between emulator windows **in the same process** (**File > New multiplayer window**), at most `MAX_GBAS = 4` (`sio.h` L17) | No. It's local only, there's no network link cable in 0.10.5, and it can't hold five players. |
| Serial port, JOY Bus mode | `dolphin.c`: two TCP sockets to a GameCube emulator (Dolphin). Started from **File > Connect to Dolphin...** (`Window.cpp` L1412) | **Maybe**, but only through a local helper that speaks this link protocol (option B1) |
| Serial port, normal mode (Game Boy Player) | `gbp.c`: in-process rumble/handshake emulation | No |
| Cartridge GPIO and add-ons | `cart/gpio.c` (RTC, rumble, gyro, tilt, light sensor), `cart/ereader.c`, Battle Chip Gate | No. Fixed in-process devices. |
| mGBA debug registers | `REG_DEBUG_STRING` / `REG_DEBUG_ENABLE` (`io.h` L164–166, `io.c` L608–635) | No. One-way ROM-to-log output. |

So **no ROM-only path exists on stock 0.10.5** (option A). The Dolphin link
carries bytes to a TCP peer, but that peer must speak mGBA's Dolphin link
protocol, and the link only starts from a menu dialog. A helper process is
still needed. This is not "the ROM calls host sockets".

### What host code can reach

- **Lua scripts** (today's bridge): `emu` memory access, frame callbacks and
  the `socket` API. Connect and DNS resolution block the emulation thread
  ([mgba-scripting.md](mgba-scripting.md#gotchas)).
- **The Qt frontend's built-in features**, including the Dolphin connector.
  There is no plugin API. Qt features are compiled in.
- **The libmgba core API** (`core.h`): `runFrame` (L98), `busRead32` (L122),
  `rawWrite8` (L132), `setPeripheral` (L118) and `addCoreCallbacks` (L80). The
  serial driver struct `GBASIODriver` is public (`interface.h` L71). A program
  that embeds the core can read and write `gCoopMailbox` between frames, just
  as Lua does, or install its own serial driver. Doing so means building our
  own frontend (option B2).
- **The SDL frontend** (`mgba-sdl.exe`) creates only the legacy script bridge
  (Python/debugger, `sdl/main.c` L234–242). It has no Lua loading and no
  Dolphin connector.

### Where each concern lives

| Concern | Today (Lua) | A | B1 (JOY Bus + helper) | B2 (custom build) | C (launcher + Lua) |
| --- | --- | --- | --- | --- | --- |
| DNS, TCP to the relay | Lua, **on the emulation thread** (blocking) | n/a | Go helper, its own goroutines | Our host code, its own thread | Lua, as today |
| Join key, endpoint | `client/config.lua` | n/a | Helper config | Frontend config | Written into `config.lua` by the launcher |
| Retry and backoff | Lua, a hitch on every attempt | n/a | Helper, without hitching the game | Host code | Lua, as today |
| Backpressure | Lua send buffer, 15 slots/frame | n/a | JOY Bus status flags plus helper queues | Host code | As today |
| Mailbox ↔ JSON | `client/lib/mailboxbridge.lua`, `fragments.lua` | n/a | Ported to Go, plus a new ROM JOY Bus pump | Ported to C or Go | As today |
| In-game behavior | ROM (`rom/src/coop/`) | n/a | ROM | ROM | ROM |

Changing the transport doesn't change hosting. The relay stays on leomayca's
PC with IPv4 port forwarding ([playing-online.md](playing-online.md)). Every
option still needs a host without CGNAT, and none adds NAT traversal.

### Link modes are not the presence relay

mGBA's link cable emulation (lockstep) synchronizes emulator *instances*
cycle by cycle for in-game link features. It is local to one process and
limited to four. The Dolphin link pairs **one** GBA with **one** GameCube peer.
Neither is a room. In every option the five-player room (four remote slots
per client, [architecture.md](architecture.md#networking-identity-and-hosting))
stays in the relay: each player runs their own transport to the same server.
No option reduces capacity.

## 2. Options

### A. ROM-only on unmodified mGBA: no-go

**Missing capability:** a ROM-visible device whose host side is a general TCP
client. 0.10.5 has none (table above). Supporting it would need, at minimum, a
new emulated device and an emulator change, which is option B2. The ROM would
also need its own TCP/IP, DNS and JSON stack, which nobody should build in GBA
C code when the host can do it.

### B1. JOY Bus link to a local helper: unproven candidate

**How it would work.** The ROM switches the serial port to JOY Bus mode
(`RCNT` bits 14–15; mode selection in `sio.c` L52–73). The player opens
**File > Connect to Dolphin...**, leaves **Local computer** selected (the
default, `DolphinConnector.ui`) and presses **Connect**. mGBA then connects to
`127.0.0.1` on data port 54970 and clock port 49420 (`dolphin.c` L16–17,
L60–93). A local Go helper plays the GameCube side:

- It sends 4-byte big-endian **clock slices** (emulated cycles the GBA may
  run) on the clock socket. It sends commands on the data socket: `0x00` poll,
  `0xFF` reset, `0x15` RECV plus 4 bytes, `0x14` TRANS (`interface.h` L31–34).
- RECV stores 32 bits in `JOY_RECV` and sets `JOYSTAT_RECV`. The ROM reads the
  word, which clears the flag (`joybus.c` L59–73, `io.c` L946–948). TRANS
  returns the ROM's `JOY_TRANS` word and clears `JOYSTAT_TRANS`, which the ROM
  set by writing `JOY_TRANS` (`joybus.c` L74–89, `io.c` L544–546). Polling
  `JOYSTAT` gives flow control in both directions.
- The helper turns these words into mailbox slots and runs the existing JSON
  protocol to the relay, doing the work `mailboxbridge.lua`, `fragments.lua`
  and `net.lua` do today.

**What it reuses.** The relay, the protocol and the ROM's in-game logic stay
as they are. The **mailbox layout** could stay too, but its consumer changes:
a new ROM module would pump slots between `gCoopMailbox` and the JOY Bus
registers (8 words per 32-byte slot), and the Lua bridge logic would be ported
to Go. That is new ROM code plus a duplicate of the tested Lua bridge
(about 1,900 lines of Lua including libraries). It needs its own reviewed
decision.

**Source observations that matter** (from reading the source, not tested):

- **The helper paces emulation.** When the GBA uses up its clock credit, mGBA
  calls `SocketPoll` with `CLOCK_WAIT = 500` ms on the emulation thread
  (`dolphin.c` L14, L134–150; units in `socket.h` L383–435). A slow or stalled
  helper therefore stutters or freezes the game. mGBA's `clockSlice` is a
  signed 32-bit counter, so credit has to track real time (the probe credits
  elapsed wall time).
- **No reconnection.** The link connects only when the player presses
  **Connect** (`DolphinConnector.cpp` L29–67). Nothing in `dolphin.c` retries.
  If the helper restarts, the player must press Disconnect and Connect again.
  The helper can still reconnect to the *relay* in the background without
  touching the link. That is the main responsiveness gain over today's
  blocking Lua `connect`.
- **Connecting pauses emulation.** `attach` holds a
  `CoreController::Interrupter` while connecting (`DolphinConnector.cpp`
  L51–54). On loopback that is quick when the helper is listening. When it
  isn't, expect a Windows refused-connect stall like the 2 s one measured for
  Lua ([mgba-scripting.md](mgba-scripting.md#gotchas)). This is not verified
  for this path.
- **Framing is fragile.** mGBA reads a command byte, then its 4 data bytes,
  with separate non-blocking `recv` calls. If the data bytes haven't arrived
  yet, the command byte is consumed and lost (`dolphin.c` L168–186). The helper
  must send each command in one write. Loopback normally delivers that as one
  segment, but TCP doesn't guarantee it.
- **The driver may be active outside JOY Bus mode.** After boot `RCNT` is
  `0x8000` (`RCNT_INITIAL`, `sio.h` L24), which selects a mode with no driver.
  `GBASIOSetDriver` makes the new JOY Bus driver active whenever the active
  driver equals the old one, and NULL equals NULL here (`sio.c` L157–162). So
  connecting may route *all* serial register writes to the JOY Bus driver
  until the ROM changes mode. In-game link-cable features would likely not
  work while connected. That fits v1, which has no link features, but it is
  a conflict for any later cable-based feature.
- **Throughput is unknown.** mGBA handles at most one command per
  `CLOCK_GRAIN` (1,160 cycles, about 14,000 per emulated second; `dolphin.c`
  L11–13, L151–154). In practice a request/response helper waits on mGBA's
  frame pacing, so real throughput may be a few words per frame. One presence
  slot is 8 words. **This is the main open question**; the probe measures it.

**Platform:** the connector is part of the Qt frontend on every platform
(`Window.cpp` L1411–1414, built with `M_CORE_GBA`). Windows: unverified
(the probe hasn't been run). Linux and macOS: unknown. The SDL frontend has no
connector.

### B2. Custom frontend or mGBA fork: feasible, no-go for now

There is no plugin or extension API in 0.10.5. Qt features are compiled in.
The real extension points are:

1. **Embed libmgba** in a new program that uses the `core.h` API: load the
   ROM, run frames, read and write `gCoopMailbox` between frames, and run the
   network on its own thread. The mailbox and the relay stay unchanged, and
   the Lua bridge logic moves into the host program. This also needs our own
   video, audio, input, save and settings handling.
2. **Fork mGBA's Qt frontend** and add a co-op bridge (and a *Connect* menu)
   next to the existing features.

Either way works with the public API, and it gives the best UX: one program,
non-blocking networking, an in-app connection screen, and headless CI tests
of the whole bridge. The costs:

- We'd build and sign an emulator for every platform, and follow upstream
  security and bug fixes.
- **MPL-2.0** (`LICENSE`): if we distribute a modified build, we must publish
  the source of the MPL-covered files we change and keep the notices. Qt is
  LGPL, and other bundled libraries bring their own terms.
- The Go server's "standard library only" rule doesn't stretch to a C/C++
  frontend. Go via cgo would also need a C toolchain and a new dependency
  decision.
- The pinned-version policy in [mgba-scripting.md](mgba-scripting.md#pinned-version)
  would become "our own build".

For three developers that's more maintenance than user benefit, so **no-go**
until B1 or C prove insufficient.

### C. Launcher that keeps Lua: go (simpler UX, not Lua removal)

**What 0.10.5 can't do:** start a Lua script automatically.

- The command line has no script option (`commandline.c` L26–42 and the
  short options at L73–74; also the local `--help` observation).
- The Qt scripting context is only created when the player opens
  **Tools > Scripting...** (`Window.cpp` L667–676). Its `init` attaches the
  stdlib, sockets and engines but loads nothing (`ScriptingController.cpp`
  L124–141). The only stored script state is the recent-scripts list
  (`recentScripts`, used by **File > Load recent script**).
- The autorun list exists only on upstream master (commit `9005770`). It is
  unreleased.

**What a launcher can do on 0.10.5:**

- Install the client into an **ASCII-only folder** (for example
  `C:\EmeraldCoop`), which avoids the `Usuário` path failure.
- Ask for `PLAYER_ID`, the server endpoint and the join key, and write
  `client/config.lua`. Validate the ID with the existing rules.
- Patch the ROM and check both SHA1s, as [installing.md](installing.md)
  describes, so the player doesn't need Flips. mGBA can also soft-patch: `-p`
  (`commandline.c` L39, `Window.cpp` L193–194) or a `.bps` with the same name
  next to the ROM (`mCoreAutoloadPatch`, `core.c` L236). How soft patching
  interacts with the bridge's ROM CRC check and with save naming is
  **unverified**, so hard patching stays the safe default.
- Start `mGBA.exe <patched ROM>`, which takes the ROM as a positional argument
  (`Window.cpp` L225–226).
- Optionally use a **portable** mGBA: a `portable.ini` next to the executable
  keeps mGBA's config in that folder (`config.c` L201–321). This gives the
  launcher a predictable config file. When the autorun release ships, the
  launcher could write `autorunSettings` there. That is unverified until such
  a release exists.

**What stays manual on 0.10.5:** Tools > Scripting... > File > Load recent
script > `bridge.lua`. The first time it's File > Load script... instead.
Driving those menus with Windows UI automation is possible but fragile, and
it would act on the player's desktop. It's rejected.

## 3. User journeys

Baseline is Windows. Players supply their own ROM in every option; the
project never distributes it.

### Today (baseline)

1. Install mGBA 0.10.5.
2. Download the patch and client zip from the same release.
3. Install Flips, check the ROM's SHA1, patch it, and check the patched SHA1.
4. Unzip the client to an ASCII-only folder.
5. Copy `config.example.lua` to `config.lua` and edit it by hand (ID,
   endpoint, key).
6. Each session: open the ROM, then Tools > Scripting > File > Load
   (recent) script.

Files: the patched ROM and save, the `client/` folder with `config.lua`.
Processes: mGBA. Updates: download both files again and redo steps 3–5.

### C. Launcher (Lua retained)

1. Install mGBA 0.10.5, or let the launcher use a portable copy.
2. Run the Emerald Co-Op installer. It installs to an ASCII folder, asks for
   the ROM, checks and patches it, and asks for ID, endpoint and key.
3. Each session: start **Emerald Co-Op**. mGBA opens with the ROM, then the
   player does Tools > Scripting > File > Load recent script.

Files: as today, plus the launcher and its settings. Processes: launcher
(exits after start) and mGBA. Updates: the launcher checks the release
version, downloads the patch and client over HTTPS, verifies their SHA256
against the release notes, and re-patches from the kept original ROM. It
never runs downloaded code without the player confirming. Windows: launch
mechanism supported by source; launcher not built. Linux/macOS: unknown.

### B1. JOY Bus helper (if the probe and a ROM proof succeed)

1. Install mGBA 0.10.5 and the Emerald Co-Op package (patch plus helper, no
   Lua).
2. Patch the ROM (or let the installer do it). Enter ID, endpoint and key in
   the helper's first-run prompt.
3. Each session: start the helper, then open the ROM in mGBA and choose
   File > Connect to Dolphin... > Connect. If the helper restarts, choose
   Disconnect, then Connect.

Files: the patched ROM and save, the helper and its config. Processes: helper
and mGBA. Updates: the patch and helper versions must match. The helper can
check the ROM's identity through the mailbox, like `romCrc32` today. Windows:
unverified. Linux/macOS: unknown.

### B2. Custom build

1. Install the Emerald Co-Op emulator build.
2. Pick the ROM; the program patches it.
3. Each session: open the program and choose **Connect** in its menu, or
   later in an in-ROM menu. It enters ID, endpoint and key once.

Files: the program, its config, the ROM and save. Processes: one. Updates: we
ship whole emulator builds. All platforms: unknown (not built).

### A possible in-ROM connection menu

In any option, the ROM could show connection state and *Connect*/*Disconnect*
choices and pass requests over the mailbox (a new flag or message type, which
is a mailbox change). Typing an endpoint or key on a GBA keyboard is clumsy,
and a key kept in the save would travel with every shared `.sav`. So entry and
storage belong to the host side, and the ROM only shows state and choices.
The UI itself is outside this spike.

## 4. Compatibility and costs

| | Today | C. Launcher + Lua | B1. JOY Bus + helper | B2. Custom build |
| --- | --- | --- | --- | --- |
| Lua-free | No | No | Yes | Yes |
| Manual steps per session | Open ROM + 3 script clicks | Start launcher + 3 script clicks | Start helper + open ROM + Connect dialog | Start program (+ Connect) |
| One-time setup | Flips, SHA1 checks, folder, hand-edited config | Installer wizard | Installer/patch + helper prompt | Installer |
| Emulator | Stock 0.10.5 | Stock 0.10.5 | Stock 0.10.5 (Qt) | Our build |
| Platforms | Windows verified; others per #8 | Windows by source; others unknown | Unknown everywhere until probed | Unknown |
| ROM / mailbox change | None | None | New ROM JOY Bus pump; mailbox layout may stay | None needed |
| Relay / protocol change | None | None | None | None |
| Five-player room | Kept (relay) | Kept | Kept: one link per player | Kept |
| Maintenance | Lua client | + launcher | + ROM pump, Go port of the bridge, helper | + emulator build per platform |
| License duties | None beyond today | Notices if we bundle mGBA (MPL-2.0) | None extra | Publish modified MPL source, Qt LGPL |
| Testability | Lua unit tests; emulator manual | Same + launcher unit tests | Go tests vs. a model; ROM tests; emulator manual | Headless end-to-end possible |
| Observability | Scripting console, debug panel | Same | Helper log; mGBA SIO log; no panel unless the ROM shows one | Our own UI and logs |
| Emulation stalls | Every connect attempt (≈2 s on Windows when refused) | Same | None for relay retries; risk if the helper's clock stalls (≤500 ms polls) | None if threaded |
| Save/reset | Bridge reset handling ([mailbox-bridge.md](mailbox-bridge.md)) | Same | *Reset on connect* is off by default; reset/stop behavior unverified | Ours to define |
| Failure recovery | Automatic retry | Same | Relay: automatic. Link: manual reconnect. | Ours to define |
| NAT/CGNAT, hosting | Host with port forwarding | Unchanged | Unchanged | Unchanged |

## 5. Security and responsiveness

- **Endpoint and key entry.** Entered once on the host side (launcher wizard,
  helper prompt or frontend dialog). Stored only in a per-user, git-ignored
  file such as `client/config.lua` or the helper's config, with the key
  masked on screen. Never put it in the ROM, the `.bps`, the save, an example
  file, an issue or a log. Public examples use placeholders, as
  `config.example.lua` does with `127.0.0.1` and an empty key.
- **Redacted diagnostics.** Logs and debug panels print the endpoint and key
  as redacted (`<host>`, `<key set>`), never their values. A "copy
  diagnostics" action should do the same, so players can paste it into
  issues.
- **Safe version checks.** Compare the ROM identity (`romCrc32`, from the
  generated `client/addresses.lua`) and the protocol `v` before joining, as
  today. A launcher checks releases over HTTPS only, verifies SHA256 before
  using a download and asks before running anything new. It never updates
  silently.
- **Not freezing emulation.** Today's freezes come from Lua's blocking
  `connect` and DNS on the emulation thread
  ([mgba-scripting.md](mgba-scripting.md#gotchas)). Lua can't avoid them on
  0.10.5. Options that move the TCP connection off that thread (B1's helper,
  B2's network thread) remove them. B1 adds its own risk: the helper must keep
  granting clock credit on time, or mGBA waits up to 500 ms per poll. A
  smaller step for C: let Lua connect only to a local helper on loopback,
  which then does DNS, the remote connection and retries. That still stalls
  about 2 s when the helper is down on Windows, and it adds a process, so it
  needs an architecture decision ([draft F4](#draft-follow-up-issues)).
- **Listen on loopback only.** The B1 helper and any local proxy listen on
  `127.0.0.1` and never on a LAN or public interface. The Dolphin data and
  clock ports carry no authentication.

## Evidence: the JOY Bus probe

Option C needs no proof beyond the source: it keeps today's verified path and
only moves setup. The open question is B1, so the disposable proof targets
its first unknown.

[`cmd/joybusprobe`](../cmd/joybusprobe/main.go) is a throwaway Go program
(standard library only, like `cmd/echoserver` from the #8 spike). It plays
the GameCube side of mGBA's Dolphin link on `127.0.0.1:54970` and `:49420`:

- grants clock credit that tracks wall time;
- sends RESET, then POLL, and every 30 exchanges a RECV with a counter word
  (`0xC0DExxxx`) followed by TRANS;
- logs the device ID and `JOYSTAT`, any change in `JOY_TRANS`, and every 5 s
  the exchange count and round-trip times;
- reports a session that ends or times out, and waits for a new Connect.

**What has been demonstrated:** `go test ./cmd/joybusprobe` passes. It runs
the probe against a Go model of mGBA's side that was transcribed from
`dolphin.c` and `joybus.c`. That checks the probe's framing **against the
source as read**. It says nothing about real mGBA behavior.

**What has not been demonstrated:** the probe has **not** been run against
mGBA. The Connect dialog needs a person at the GUI. Nothing has shown a
ROM/mailbox payload reaching the relay through this path, an inbound
response reaching the mailbox, two-client presence or reconnection. That
would need a ROM-side JOY Bus pump, which this spike may not add to the ROM.

### Reproduce

From a clean checkout, with no ROM or config committed:

```sh
go run ./cmd/joybusprobe
```

1. Open any ROM you own in mGBA 0.10.5 (stock Emerald or our patched build).
   Leave it in the overworld.
2. **File > Connect to Dolphin...**, keep **Local computer**, leave **Reset on
   connect** unchecked, press **Connect**.
3. Record, with no IPs or keys:
   - whether a `RESET reply: device 0x0004 ...` line appears. If it does, the
     driver is active even though the ROM never selected JOY Bus mode (the
     `sio.c` L157 observation). If nothing appears and the session times out,
     the ROM must select JOY Bus mode first.
   - the exchanges per 5 s and the round-trip times. This bounds throughput.
   - the game's fps while connected (shown in the window title).
   - with **Tools > Game state views > View I/O registers...**, whether
     `JOY_RECV` shows the probe's `0xC0DExxxx` counter;
   - what happens when you stop the probe with Ctrl+C: does the game keep
     running, and does mGBA recover after Disconnect, restarting the probe
     and Connect?
4. Post the sanitized result in issue #70.

## Recommendation

1. **No-go on removing Lua now.** A is impossible on stock 0.10.5. B2 costs
   more than it gives a three-person project. B1 is unproven and would add
   ROM code and a Go copy of the bridge.
2. **Go for a launcher/installer (C)** after v1. It removes Flips, the
   hand-edited config and the non-ASCII path trap. It keeps the tested Lua
   bridge, the mailbox and the relay. It is UX work, not Lua removal, and it
   doesn't block or change #27.
3. **Probe B1 cheaply** before any further work on it ([F1](#draft-follow-up-issues)).
   Only a positive probe justifies a disposable ROM proof.
4. **Re-evaluate** when mGBA ships a release containing script autorun. Then
   C could start the bridge with no clicks, and Lua's remaining UX cost would
   mostly disappear.

This recommendation still needs review by another developer (issue #70
acceptance).

## Draft follow-up issues

These are drafts for the team to file after review. None is approved work.

- **F1. Run the JOY Bus probe on mGBA 0.10.5** (spike, ~1 h, human with the
  GUI). Follow [Reproduce](#reproduce) on Windows and record the results.
  Gate for F2.
- **F2. Disposable ROM JOY Bus echo proof** (spike, only if F1 is positive;
  needs a reviewed decision because it touches the ROM). A throwaway ROM
  build moves outbound mailbox slots to the helper and inbound slots back.
  Measure slots per second, fps and recovery when the helper stops and
  restarts. Check what the connection does to the serial registers in the
  overworld.
- **F3. Windows launcher/installer prototype that keeps Lua** (feature, after
  #27). ASCII install folder, ROM SHA1 check and hard patch, a config wizard
  that writes `client/config.lua` with a masked key, then start mGBA with the
  patched ROM. Document the remaining script-load clicks. Out of scope: Lua
  removal, emulator changes, auto-update.
- **F4. Decide whether Lua should connect only to a local proxy** (decision).
  It would take DNS and remote-connect stalls off the emulation thread.
  Weigh the extra process against the hitches measured in #8.
- **F5. Track an mGBA release with script autorun** (chore). When a stable
  release contains commit `9005770`, evaluate re-pinning and launcher-managed
  autorun.

## What could not be verified

- Anything about the Dolphin link at runtime: whether it activates without
  JOY Bus mode, its throughput, fps impact, behavior on helper stop, reset or
  game stop. All of it comes from reading the source.
- Whether soft patching (`-p` or a same-name `.bps`) keeps the bridge's CRC
  check and save naming correct.
- Any non-Windows behavior of C, B1 or B2.
- The upstream autorun feature's behavior. It's unreleased, and only its
  source was read.
