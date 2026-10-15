# Emerald Co-Op

A co-op mod for Pokémon Emerald, with a Go presence server and an mGBA Lua
client. The first release aims to let up to five players see each other in the
overworld. Saves, battles and items stay local in v1.

The project is at **0.0 Foundations**. The Go commands currently print placeholder
messages and exit; there is no working server or Lua client yet. Follow progress
in the [milestones](https://github.com/DaviAlencastro/EmeraldCo-Op/milestones).

## Repository layout

```text
EmeraldCo-Op/
├── go.mod                    # one Go module for the server and tools
├── cmd/
│   ├── server/               # presence relay entry point (placeholder)
│   ├── fakeclient/           # simulated player entry point (placeholder)
│   └── symgen/               # ELF symbol generator entry point (placeholder)
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

For an existing checkout, run `git submodule update --init --recursive` after
pulling changes. `rom/` tracks our fork at
[DaviAlencastro/pokeemerald](https://github.com/DaviAlencastro/pokeemerald) as a
Git submodule.

## Go development

Install [Go 1.27.2](https://go.dev/dl/), the stable version pinned in `go.mod`.
Run these commands from the repository root:

```sh
go build ./...
go vet ./...
go test -race ./...
go run ./cmd/server
```

The server prints a startup placeholder message and exits without opening a
network listener. `go run ./cmd/fakeclient` and `go run ./cmd/symgen` also print
placeholder messages. No external Go dependencies are required.

The race check requires a supported C compiler with cgo enabled. There are no
tests yet because the commands have no behavior beyond their placeholder logs.

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
| `rom/pokeemerald_modern.elf` | Build symbols for the future address generator. |
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

Address generation belongs to [issue #4](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/4)
and is not performed by this command. All players will use our built ROM from
milestone 0.1 onward, distributed as a `.bps` patch applied locally. Do not commit
ROMs, saves, BIOS files, patches or build outputs.

## Client development

The client targets mGBA with Lua 5.4 and native sockets, subject to validation in
[issue #8](https://github.com/DaviAlencastro/EmeraldCo-Op/issues/8).
See the [client README](client/README.md) for the planned configuration.
`client/config.example.lua` is tracked; private settings belong in the ignored
`client/config.lua`. Keep join keys and public IP addresses private.

## Documentation

- [Architecture](docs/architecture.md): agreed design and communication flow.
- [Roadmap](docs/ROADMAP.md): foundations, v1 presence and future versions.
- [Protocol](docs/protocol.md): the JSON-lines wire protocol between client and server.
- [Memory map](docs/memory-map.md): stub for sourced memory layouts (#9).
- [Playing online](docs/playing-online.md): stub for hosting and joining (#18).

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
- Open a PR into `master`, include `Closes #N` and the manual test results, and
  complete the template's Definition of Done checklist.
- Obtain one human approval and passing available CI before squash merging.
  Branch protection and CI setup are tracked in issues #6 and #5; never push
  directly to `master` or merge your own PR without that approval.
