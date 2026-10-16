# Memory map

Global addresses are generated. Struct field offsets remain to be documented in
[issue #9](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/9), sourced from the
decompilation headers; this document does not assign offsets or duplicate
generated addresses.

## Generated globals

**[`client/addresses.lua`](../client/addresses.lua)** is the only source of global
addresses. `cmd/symgen` reads the built ELF using Go's standard-library
`debug/elf` and writes a Lua module returning:

| Field | Meaning |
| --- | --- |
| `romSha1` | Lowercase SHA1 of the supplied ROM file. |
| `symbols["NAME"].addr` | Symbol address from the ELF. |
| `symbols["NAME"].size` | Symbol size in bytes from the ELF. |

Symbol selection lives in
[`cmd/symgen/symbols.txt`](../cmd/symgen/symbols.txt). The allowlist names global
data objects, not functions or struct fields. Later issues can extend it as
needed, for example when `gCoopMailbox` is introduced.

See [Generating client addresses](../README.md#generating-client-addresses) for
the command, required build inputs, validation, map verification and regeneration
rules. Never hand-write or guess global addresses, or edit the generated module.
Update this document if the memory layout changes. Client runtime integration is
still planned in
[issue #10](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/10).

## Future layouts

The 0.4+ **`gCoopMailbox`** design is recorded in [architecture.md](architecture.md). Its exact memory layout will be documented here when implemented; the planned header and two 16-slot rings do not establish offsets or a binary contract yet.
