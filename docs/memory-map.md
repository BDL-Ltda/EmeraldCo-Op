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

The default symbol allowlist lives in
[`cmd/symgen/symbols.txt`](../cmd/symgen/symbols.txt): `gObjectEvents`,
`gPlayerAvatar`, `gSaveBlock1Ptr`, `gSaveBlock2Ptr` and `gMain`. It is embedded at
compile time. Later issues can extend the list as needed, for example when
`gCoopMailbox` is introduced. The allowlist names globals, not struct fields.

After building the ROM, generate the file from the repository root:

```sh
go run ./cmd/symgen -elf rom/pokeemerald_modern.elf -rom rom/pokeemerald_modern.gba -out client/addresses.lua
```

Always supply the ELF and ROM from the **same build**. The SHA1 records the ROM
input; it does not validate the pairing with the ELF. Spot-check symbols against
`rom/pokeemerald_modern.map` from that build. Output is sorted and deterministic,
so another run with identical inputs must produce identical bytes. Missing
allowlisted symbols fail with their names in the error instead of generating
partial data. See [Generating client addresses](../README.md#generating-client-addresses)
for validation details and the optional diagnostic `-symbols` flag.

Never hand-write or guess global addresses, or edit the generated module.
Rebuild and regenerate after every ROM source, submodule, toolchain or build
configuration change. Commit `client/addresses.lua` in the same pull request;
keep ELF, ROM and map outputs local. Update this document if the memory layout
changes. Client runtime integration is still planned in
[issue #10](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/10).

## Future layouts

The 0.4+ **`gCoopMailbox`** design is recorded in [architecture.md](architecture.md). Its exact memory layout will be documented here when implemented; the planned header and two 16-slot rings do not establish offsets or a binary contract yet.
