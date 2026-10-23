# Emerald Co-Op

A co-op mod for Pokémon Emerald, with a Go presence server and an mGBA Lua
client. The first release aims to let up to five players see each other in the
overworld. Saves, battles and items stay local in v1.

The ROM build, ELF symbol generator and single-room presence server are
available. The server authenticates players, relays presence, answers pings
and removes inactive, flooding or slow connections. A terminal fake client
simulates walking players for server tests. The Lua client bridges the ROM
mailbox and relay, while the ROM renders remote avatars. A text-panel debug
view remains available in mGBA. Follow progress
in the [milestones](https://github.com/BDL-Ltda/EmeraldCo-Op/milestones).

Players should follow [Installing](docs/installing.md) and use the patch and
client from the same release. The [v1 release checklist](docs/release-v1.md)
records published v1.0 packaging and the pending release-only, three-developer
acceptance session in [#74](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/74);
earlier development playtests do not complete that session.

## Repository layout

```text
EmeraldCo-Op/
├── go.mod                    # one Go module for the server and tools
├── cmd/
│   ├── server/               # authenticated single-room presence relay
│   ├── fakeclient/           # simulated walking player for server tests
│   ├── echoserver/           # line echo server for client socket tests
│   └── symgen/               # ELF symbol generator and symbol allowlist
├── internal/                 # shared Go packages
├── client/                   # mGBA Lua client and example configuration
├── rom/                      # pokeemerald sources (git submodule)
├── docs/                     # design decisions and planned interfaces
└── .github/                  # issue and pull request templates
```

## Cloning

```sh
git clone --recurse-submodules https://github.com/BDL-Ltda/EmeraldCo-Op.git
cd EmeraldCo-Op
```

For an existing checkout, run `git submodule sync --recursive` and then
`git submodule update --init --recursive` after pulling changes (`sync` picks up
submodule URL changes, such as the fork's move to `BDL-Ltda`). `rom/` tracks our fork at
[BDL-Ltda/pokeemerald](https://github.com/BDL-Ltda/pokeemerald) as a
Git submodule.

### Changing the ROM

ROM work happens on a feature branch of the fork with the same name as the
parent branch (for example `feat/24-local-presence`), and the parent PR pins a
commit from that branch. When the parent PR merges, fast-forward the fork's
`master` to the pinned commit so it stays reachable after the feature branch is
deleted:

```sh
git -C rom fetch origin
git -C rom merge-base --is-ancestor origin/master <pinned-sha>   # must succeed
git -C rom push origin <pinned-sha>:refs/heads/master             # fast-forward only
```

Never force-push the fork's `master`. If the pinned commit does not descend
from it, rebase the ROM branch onto the fork's `master` and re-pin before
merging the parent PR.

## Go development

Install [Go 1.27.2](https://go.dev/dl/), the stable version pinned in `go.mod`.
Run these commands from the repository root:

```sh
go build ./...
go vet ./...
go test -race ./...
go run ./cmd/server
```

The server requires a private join key before opening its TCP listener. In
PowerShell, set it locally and start the server:

```powershell
$env:SERVER_JOIN_KEY = Read-Host "Join key"
go run ./cmd/server
```

Flags override the environment: `-addr` / `SERVER_ADDR` (default `:8765`),
`-join-key` / `SERVER_JOIN_KEY` (required), and `-max-players` /
`SERVER_MAX_PLAYERS` (default 5, allowed 1–5). See [Server development](docs/server.md)
for lifecycle behavior, limitations and a two-client smoke test. Ctrl+C closes
the listener and its connections.

Use [the fake client](docs/fakeclient.md) to test without mGBA: set the private
`FAKECLIENT_JOIN_KEY` environment variable, then run
`go run ./cmd/fakeclient -id bot1 -pattern square`. Run a second client with a
different ID to check peer movement, heartbeat and leave events against the
server. `symgen` generates the client's global addresses from a ROM build, as
described below. No external Go dependencies are required.

The race check requires a supported C compiler with cgo enabled. The symbol
generator's tests create synthetic ELF data in memory and compare Lua output with
a golden file under `cmd/symgen/testdata/`; no ELF or ROM fixture is committed.

## Building the ROM

Install Docker Desktop on Windows or macOS, start it, and select the **Linux
container engine**. On Linux, use Docker Engine with the Docker Compose v2
plugin, or Docker Desktop. The `docker` and `docker compose` commands must be
available in your terminal. No local GBA toolchain is needed.

Initialize the ROM submodule, then build from the repository root:

```sh
git submodule update --init --recursive
docker compose run --build --rm rom
```

This command also builds the Docker image on its first run. The image uses
`devkitpro/devkitarm:20260610`, pinned by digest
`sha256:15b79ce75822c289538d8153da5fa7aafe5e6adc32ad8a575a197beca0f0761b`,
with `libpng-dev` installed from the immutable Debian snapshot
`20260610T000000Z`. Compose fixes the platform to `linux/amd64` on every host so
all developers use the same compiler and host tools. ARM hosts need Docker's
AMD64 emulation, which can make builds slower.

The first run takes longer because it downloads the image and installs its host
dependency. Compilation time depends on the machine and the CPU and memory
allocated to Docker. Later runs reuse the Docker image layers, but still compile
the ROM from a clean state.

As a local reference, a clean build on Windows with Docker Desktop and eight
jobs took about 2 minutes 15 seconds after the base image was downloaded. Expect
several minutes for the initial download and image setup; ARM emulation or lower
CPU/memory limits can take longer.

The wrappers run the same Compose command and locate the repository themselves,
so they work regardless of the current working directory. From the repository
root, use either:

```powershell
.\scripts\build-rom.ps1
# Optional: limit parallel compilation to four jobs.
.\scripts\build-rom.ps1 -Jobs 4
```

```sh
sh scripts/build-rom.sh
# Optional: limit parallel compilation to four jobs.
sh scripts/build-rom.sh 4
```

From another directory, pass the wrapper's full path instead. By default the
build uses `nproc` inside the container. A supplied job count must be an integer
from 1 to 256; lower it if Docker runs out of memory.

The build copies the sources to a temporary Linux filesystem inside the
container, runs `make clean` followed by `make modern -jJOBS`, and copies only
these three outputs back to the checkout:

| Output | Purpose |
| --- | --- |
| `rom/pokeemerald_modern.gba` | ROM to open in mGBA. |
| `rom/pokeemerald_modern.elf` | Build symbols for the address generator. |
| `rom/pokeemerald_modern.map` | Linker map. |

ROM source files are not modified. There is no persistent incremental build
cache; the temporary build directory is removed with the container. The build
container runs without network access; pulling and building its Docker image
requires network access. The command prints the ROM's SHA1 after a successful
build.

### Verify the build with another developer

Use two independent checkouts on different machines, at the same main-repository
commit and pinned ROM submodule commit, without local ROM source changes. Both
developers should initialize the submodule and run the build command above.
Record the commits and the image tag/digest when comparing results:

```sh
git rev-parse HEAD
git -C rom rev-parse HEAD
```

Calculate the ROM SHA1 in PowerShell:

```powershell
Get-FileHash -Algorithm SHA1 .\rom\pokeemerald_modern.gba
```

Or in a POSIX shell:

```sh
sha1sum rom/pokeemerald_modern.gba
```

The two hashes must match, ignoring letter case. `make modern` is not expected
to match a retail Emerald ROM; compare our builds with each other. Each developer
should also open `rom/pokeemerald_modern.gba` in mGBA, start a new game, and leave
the truck. Record both developers' hashes and emulator results in the pull
request; a build on one machine alone does not establish cross-machine
reproducibility.

Address generation is a separate step below. All players will use our built ROM
from milestone 0.1 onward, distributed as a `.bps` patch applied locally (see
[releasing.md](docs/releasing.md) and [installing.md](docs/installing.md)). Do not
commit ROMs, saves, BIOS files, patches or build outputs.

## Generating client addresses

After [building the ROM](#building-the-rom), use the Go version pinned in
`go.mod` and run this command from the repository root:

```sh
go run ./cmd/symgen -elf rom/pokeemerald_modern.elf -rom rom/pokeemerald_modern.gba -out client/addresses.lua
```

All three flags are required. Supply the ELF and ROM from the **same build**.
`symgen` uses Go's standard-library `debug/elf`, so no extra symbol tools are
required. It writes the allowlisted symbol addresses and sizes from the ELF,
plus the supplied ROM's lowercase SHA1 as `romSha1` and its CRC32 (IEEE, 8 hex
digits) as `romCrc32`. These hashes identify the ROM input; they cannot
establish whether a separately supplied ELF belongs to it. The client checks
`romCrc32` at startup, because a CRC32 is the only ROM hash mGBA 0.10.5 gives
scripts (see [client/README.md](client/README.md)).

The default allowlist is [cmd/symgen/symbols.txt](cmd/symgen/symbols.txt):
only `gCoopMailbox`, the client’s shared-memory interface with the ROM (see
the [memory map](docs/memory-map.md)).
The file is embedded when the tool is compiled. `go run` picks up edits
automatically; rebuild any existing `symgen` binary after changing the list.
For diagnostics, add `-symbols PATH` to read a different allowlist, for example
one containing a fake symbol to verify the missing-symbol error.

The generated Lua module returns a table with `romSha1`, `romCrc32` and `symbols`.
Each `symbols["NAME"]` entry contains `addr` and `size`. Entries are sorted by
symbol name, with LF line endings, a generated-file header and no timestamps,
so identical inputs produce byte-identical output. Missing allowlisted symbols,
malformed inputs and empty or invalid allowlists cause a non-zero exit; a
missing-symbol error names the symbol. Validation failures preserve an existing
output file. Successful writes use a temporary file in the output directory
followed by replacement of the target file.

Spot-check the generated mailbox symbol against its entry in
`rom/pokeemerald_modern.map`. Then rerun the command and check that
`git diff -- client/addresses.lua` shows no unexpected changes. Never edit
`client/addresses.lua` by hand or copy its numeric addresses elsewhere.

**Rebuild and regenerate after every ROM source, submodule, toolchain or build
configuration change. Commit `client/addresses.lua` in the same pull request.**
Keep the ELF, ROM and map local. The historical game-struct offsets are in the
[memory map](docs/memory-map.md); the client no longer reads them.

## Client development

Install **[mGBA 0.10.5](https://github.com/mgba-emu/mgba/releases/tag/0.10.5)**,
the pinned emulator version. Everyone uses exactly this release: the scripting
API differs between versions, and development builds are not supported. The
client uses mGBA's Lua 5.4 scripting and native sockets; see
[mGBA scripting](docs/mgba-scripting.md) for the API, gotchas, how to load a
script and the spike script `client/spike/hello.lua`.
See the [client README](client/README.md) for configuration and networking.
`client/config.example.lua` is tracked; private settings belong in the ignored
`client/config.lua`. Keep join keys and public IP addresses private.

## Documentation

- [Architecture](docs/architecture.md): agreed design and communication flow.
- [Roadmap](docs/ROADMAP.md): foundations, v1 presence and future versions.
- [Protocol](docs/protocol.md): the JSON-lines wire protocol between client and server.
- [Fake client](docs/fakeclient.md): simulated walking, warp and idle players for terminal tests.
- [Memory map](docs/memory-map.md): generated globals, historical offsets and the ROM mailbox.
- [mGBA scripting](docs/mgba-scripting.md): pinned mGBA version, Lua API and gotchas.
- [Playing online](docs/playing-online.md): IPv4 hosting, TCP forwarding and external validation (#18).
- [Networking acceptance](docs/acceptance-0.2.md): three-developer milestone 0.2 test results (#19).
- [Installing](docs/installing.md): patch your ROM and load the client (players).
- [Releasing](docs/releasing.md): build, create the `.bps` patch and publish a release.

## Contributing

Read [AGENTS.md](AGENTS.md) and the [architecture](docs/architecture.md) before
starting. Work on one ready GitHub issue at a time and keep changes within its
scope. Code, comments, docs, commits, issues and PRs use English.

Follow the shared [pick-task](.claude/skills/pick-task/SKILL.md) and
[pre-commit](.claude/skills/pre-commit/SKILL.md) instructions:

- Branch from the latest `master` using `<type>/<issue>-<short-name>`, for example
  `chore/2-repo-skeleton` or `feat/12-protocol-codec`.
- Use Conventional Commits with a gitmoji, such as
  `chore(infra): 🔧 add repository skeleton`.
- Run the available checks and the issue's manual test steps. Explain checks
  whose tooling does not exist yet in the PR.
- Open a PR into `master` with the manual test results and the template's
  Definition of Done checklist. Use `Refs #N` for partial work; use `Closes #N`
  only for completed issue scope. Follow the pre-commit skill's closing-link
  review after opening and before merge.
- Obtain one human approval and passing available CI, then merge with a merge commit.

`master` is protected by a repository ruleset, with no bypass for admins:

- Changes reach `master` only through a PR. Direct pushes, force pushes and
  deleting the branch are rejected.
- A PR needs one approval, and pushing new commits dismisses earlier approvals.
- PRs merge with a merge commit; squash and rebase merges are disabled.
- CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs Go, Lua and ROM
  checks on every PR and on pushes to `master`. The ROM check fails if
  `client/addresses.lua` was not regenerated after a ROM change. Making these
  checks required is tracked in #6.
