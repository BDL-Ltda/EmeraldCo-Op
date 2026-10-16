# Internal Go packages

Shared server and tool packages belong here, inside the root Go module
`github.com/DaviAlencastro/EmeraldCo-Op` (the module path predates the move to
`BDL-Ltda/EmeraldCo-Op` and is kept unchanged). Use the standard library only.

| Package | Purpose |
| --- | --- |
| `protocol` | Wire messages, the JSON line codec and validation. Contract in [docs/protocol.md](../docs/protocol.md). |
| `room` | Single-room TCP connection lifecycle: authenticated hello, welcome snapshots, joins, leaves and duplicate-ID replacement. See [docs/server.md](../docs/server.md). |
