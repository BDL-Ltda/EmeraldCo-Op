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
├── rom/                      # pokeemerald sources; submodule conversion in #1
├── docs/                     # design decisions and planned interfaces
└── .github/                  # issue and pull request templates
```

## Cloning

```sh
git clone --recurse-submodules https://github.com/DaviAlencastro/EmeraldCo-Op.git
cd EmeraldCo-Op
```

For an existing checkout, run `git submodule update --init --recursive` after
pulling changes. `rom/` is currently a vendored copy of pokeemerald;
[issue #1](https://github.com/DaviAlencastro/EmeraldCo-Op/issues/1) converts it to
the project's fork as a submodule. These commands also work after that conversion.

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

## ROM and client development

The planned ROM build uses modern GCC (`make modern`) inside a pinned Docker
image. The Docker setup and build wrappers are tracked in
[issue #3](https://github.com/DaviAlencastro/EmeraldCo-Op/issues/3).
All players will use our built ROM from milestone 0.1 onward, distributed as a
`.bps` patch applied locally. Do not commit ROMs, saves, BIOS files, patches or
build outputs.

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
