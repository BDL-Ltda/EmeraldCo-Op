# Synthetic symbol fixtures

`main_test.go` builds a small ELF32, little-endian, ARM executable in memory
using Go's `encoding/binary` and `debug/elf` structures. No game code, ROM
binary, or ELF build output is committed as a fixture.

`fixtureAlpha` and `fixtureBeta` refer to offsets 0 and 8 in a synthetic
16-byte section, with sizes 4 and 8 respectively. They are not real game
globals or memory addresses. `symbols.txt` deliberately lists them out of
order to exercise deterministic sorting.

The ROM input is the exact UTF-8 byte sequence
`synthetic symgen ROM fixture\n`, where `\n` means one LF byte. The golden
Lua file records the resulting SHA1 and symbol table. Keep the golden file
LF-only so the comparison is byte-identical on every operating system.
