package main

import (
	"bytes"
	"debug/elf"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fixtureROM = "synthetic symgen ROM fixture\n"

type fixtureSymbol struct {
	name    string
	value   uint32
	size    uint32
	section uint16
}

func fixtureSymbols() []fixtureSymbol {
	return []fixtureSymbol{
		{name: "fixtureBeta", value: 8, size: 8, section: 1},
		{name: "fixtureAlpha", value: 0, size: 4, section: 1},
	}
}

// syntheticELF contains no game code or real memory addresses. Its symbol
// values are offsets into a 16-byte synthetic section, built entirely here.
func syntheticELF(t *testing.T, symbols []fixtureSymbol) []byte {
	t.Helper()
	stringsData := []byte{0}
	symbolTable := []elf.Sym32{{}}
	for _, symbol := range symbols {
		nameOffset := len(stringsData)
		stringsData = append(stringsData, symbol.name...)
		stringsData = append(stringsData, 0)
		symbolTable = append(symbolTable, elf.Sym32{
			Name: uint32(nameOffset), Value: symbol.value, Size: symbol.size,
			Info: byte(elf.STB_GLOBAL)<<4 | byte(elf.STT_OBJECT), Shndx: symbol.section,
		})
	}

	const headerSize = 52
	const dataSize = 16
	stringOffset := headerSize + dataSize
	symbolOffset := (stringOffset + len(stringsData) + 3) &^ 3
	symbolSize := binary.Size(elf.Sym32{}) * len(symbolTable)
	sectionOffset := symbolOffset + symbolSize
	header := elf.Header32{
		Type: uint16(elf.ET_EXEC), Machine: uint16(elf.EM_ARM), Version: uint32(elf.EV_CURRENT),
		Ehsize: headerSize, Shoff: uint32(sectionOffset),
		Shentsize: uint16(binary.Size(elf.Section32{})), Shnum: 4,
	}
	copy(header.Ident[:], []byte(elf.ELFMAG))
	header.Ident[elf.EI_CLASS] = byte(elf.ELFCLASS32)
	header.Ident[elf.EI_DATA] = byte(elf.ELFDATA2LSB)
	header.Ident[elf.EI_VERSION] = byte(elf.EV_CURRENT)

	var buffer bytes.Buffer
	write := func(value any) {
		t.Helper()
		if err := binary.Write(&buffer, binary.LittleEndian, value); err != nil {
			t.Fatal(err)
		}
	}
	write(header)
	buffer.Write(make([]byte, dataSize))
	buffer.Write(stringsData)
	buffer.Write(make([]byte, symbolOffset-buffer.Len()))
	write(symbolTable)
	write([]elf.Section32{
		{},
		{Type: uint32(elf.SHT_PROGBITS), Off: headerSize, Size: dataSize, Addralign: 4},
		{Type: uint32(elf.SHT_STRTAB), Off: uint32(stringOffset), Size: uint32(len(stringsData)), Addralign: 1},
		{Type: uint32(elf.SHT_SYMTAB), Off: uint32(symbolOffset), Size: uint32(symbolSize), Link: 2,
			Info: 1, Addralign: 4, Entsize: uint32(binary.Size(elf.Sym32{}))},
	})
	return buffer.Bytes()
}

func readGolden(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "addresses.golden.lua"))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestGenerateGoldenDeterministic(t *testing.T) {
	allowlist, err := os.ReadFile(filepath.Join("testdata", "symbols.txt"))
	if err != nil {
		t.Fatal(err)
	}
	golden := readGolden(t)
	symbols := fixtureSymbols()
	variants := []struct {
		name      string
		symbols   []fixtureSymbol
		allowlist string
	}{
		{"fixture order", symbols, string(allowlist)},
		{"reordered and CRLF", []fixtureSymbol{symbols[1], symbols[0]}, "# Reordered input\r\n\r\n fixtureAlpha \r\nfixtureBeta\r\n"},
		{"unlisted symbol", append(fixtureSymbols(), fixtureSymbol{name: "fixtureUnused", value: 12, size: 4, section: 1}), string(allowlist)},
	}
	for _, variant := range variants {
		t.Run(variant.name, func(t *testing.T) {
			for attempt := 0; attempt < 2; attempt++ {
				got, err := generate(bytes.NewReader(syntheticELF(t, variant.symbols)), strings.NewReader(fixtureROM), strings.NewReader(variant.allowlist))
				if err != nil {
					t.Fatal(err)
				}
				if !bytes.Equal(got, golden) {
					t.Fatalf("output differs from golden:\n%s\nwant:\n%s", got, golden)
				}
			}
		})
	}
}

func TestGenerateMissingOrUndefinedSymbol(t *testing.T) {
	for _, test := range []struct {
		name    string
		symbols []fixtureSymbol
	}{
		{"missing", fixtureSymbols()[1:]},
		{"undefined", []fixtureSymbol{{name: "fixtureBeta", section: uint16(elf.SHN_UNDEF)}}},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := generate(bytes.NewReader(syntheticELF(t, test.symbols)), strings.NewReader(fixtureROM), strings.NewReader("fixtureBeta\n"))
			if err == nil || !strings.Contains(err.Error(), "fixtureBeta") {
				t.Fatalf("expected error naming fixtureBeta, got output %q and error %v", got, err)
			}
		})
	}
}

func TestGenerateRejectsConflictingSymbols(t *testing.T) {
	for _, duplicate := range []fixtureSymbol{
		{name: "fixtureBeta", value: 12, size: 8, section: 1},
		{name: "fixtureBeta", value: 8, size: 4, section: 1},
	} {
		symbols := append(fixtureSymbols(), duplicate)
		_, err := generate(bytes.NewReader(syntheticELF(t, symbols)), strings.NewReader(fixtureROM), strings.NewReader("fixtureBeta\n"))
		if err == nil || !strings.Contains(err.Error(), "fixtureBeta") {
			t.Fatalf("expected conflict error naming fixtureBeta for %+v, got %v", duplicate, err)
		}
	}
}

func TestGenerateRejectsInvalidAllowlist(t *testing.T) {
	for _, allowlist := range []string{"", "# comments only\n\n", "fixtureAlpha\nfixtureAlpha\n", "9invalid\n", "bad-name\n", "fixtureAlpha extra\n", "nonASCII\u00e9\n"} {
		t.Run(allowlist, func(t *testing.T) {
			_, err := generate(bytes.NewReader(syntheticELF(t, fixtureSymbols())), strings.NewReader(fixtureROM), strings.NewReader(allowlist))
			if err == nil {
				t.Fatalf("expected invalid allowlist %q to fail", allowlist)
			}
		})
	}
}

func TestGenerateRejectsInvalidELF(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func([]byte) []byte
	}{
		{"malformed", func([]byte) []byte { return []byte("not an ELF") }},
		{"ELF64", func(data []byte) []byte { data[elf.EI_CLASS] = byte(elf.ELFCLASS64); return data }},
		{"big endian", func(data []byte) []byte { data[elf.EI_DATA] = byte(elf.ELFDATA2MSB); return data }},
		{"non ARM", func(data []byte) []byte { binary.LittleEndian.PutUint16(data[18:20], uint16(elf.EM_386)); return data }},
		{"relocatable", func(data []byte) []byte { binary.LittleEndian.PutUint16(data[16:18], uint16(elf.ET_REL)); return data }},
	} {
		t.Run(test.name, func(t *testing.T) {
			data := test.mutate(syntheticELF(t, fixtureSymbols()))
			_, err := generate(bytes.NewReader(data), strings.NewReader(fixtureROM), strings.NewReader("fixtureAlpha\n"))
			if err == nil {
				t.Fatal("expected unsupported or malformed ELF to fail")
			}
		})
	}
}

type failedReader struct{}

func (failedReader) Read([]byte) (int, error) {
	return 0, errors.New("synthetic read failure")
}

func TestGeneratePropagatesReadErrors(t *testing.T) {
	for _, test := range []struct {
		name      string
		rom       io.Reader
		allowlist io.Reader
	}{
		{"ROM", failedReader{}, strings.NewReader("fixtureAlpha\n")},
		{"allowlist", strings.NewReader(fixtureROM), failedReader{}},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := generate(bytes.NewReader(syntheticELF(t, fixtureSymbols())), test.rom, test.allowlist)
			if err == nil || !strings.Contains(err.Error(), "synthetic read failure") {
				t.Fatalf("expected reader error to be retained, got %v", err)
			}
		})
	}
}

func writeFixtureFile(t *testing.T, directory, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

type cliFixture struct {
	elfPath     string
	romPath     string
	symbolsPath string
	outPath     string
}

func (fixture cliFixture) args() []string {
	return []string{
		"-elf", fixture.elfPath,
		"-rom", fixture.romPath,
		"-symbols", fixture.symbolsPath,
		"-out", fixture.outPath,
	}
}

func newCLIFixture(t *testing.T) cliFixture {
	t.Helper()
	directory := t.TempDir()
	return cliFixture{
		elfPath:     writeFixtureFile(t, directory, "synthetic-elf", syntheticELF(t, fixtureSymbols())),
		romPath:     writeFixtureFile(t, directory, "synthetic-rom", []byte(fixtureROM)),
		symbolsPath: writeFixtureFile(t, directory, "symbols.txt", []byte("fixtureBeta\nfixtureAlpha\n")),
		outPath:     filepath.Join(directory, "addresses.lua"),
	}
}

func TestRunWritesGolden(t *testing.T) {
	fixture := newCLIFixture(t)
	var stdout, stderr bytes.Buffer
	if code := run(fixture.args(), &stdout, &stderr); code != 0 {
		t.Fatalf("exit = %d, stderr = %s", code, &stderr)
	}
	got, err := os.ReadFile(fixture.outPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, readGolden(t)) {
		t.Fatalf("CLI output differs from golden:\n%s", got)
	}
	if !strings.Contains(stdout.String(), fixture.outPath) || stderr.Len() != 0 {
		t.Fatalf("expected success naming output, got stdout %q, stderr %q", &stdout, &stderr)
	}
}

func TestRunArguments(t *testing.T) {
	for _, test := range []struct {
		name string
		args []string
		code int
	}{
		{"help", []string{"-h"}, 0},
		{"no arguments", nil, 2},
		{"missing ELF", []string{"-rom", "input", "-out", "output"}, 2},
		{"missing ROM", []string{"-elf", "input", "-out", "output"}, 2},
		{"missing output", []string{"-elf", "input", "-rom", "input"}, 2},
		{"unknown flag", []string{"-unknown"}, 2},
		{"extra positional argument", []string{"-elf", "input", "-rom", "input", "-out", "output", "extra"}, 2},
	} {
		t.Run(test.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			if code := run(test.args, &stdout, &stderr); code != test.code {
				t.Fatalf("exit = %d, want %d, stdout = %s, stderr = %s", code, test.code, &stdout, &stderr)
			}
			if test.code != 0 && stderr.Len() == 0 {
				t.Fatal("expected argument error on stderr")
			}
		})
	}
}

func TestRunFailurePreservesExistingOutput(t *testing.T) {
	for _, failure := range []string{"missing symbol", "missing ROM", "malformed ELF"} {
		t.Run(failure, func(t *testing.T) {
			fixture := newCLIFixture(t)
			previous := []byte("previous output must survive\n")
			writeFixtureFile(t, filepath.Dir(fixture.outPath), filepath.Base(fixture.outPath), previous)
			switch failure {
			case "missing symbol":
				writeFixtureFile(t, filepath.Dir(fixture.symbolsPath), filepath.Base(fixture.symbolsPath), []byte("fixtureMissing\n"))
			case "missing ROM":
				fixture.romPath = filepath.Join(filepath.Dir(fixture.outPath), "missing-rom")
			case "malformed ELF":
				writeFixtureFile(t, filepath.Dir(fixture.elfPath), filepath.Base(fixture.elfPath), []byte("invalid ELF"))
			}
			var stdout, stderr bytes.Buffer
			if code := run(fixture.args(), &stdout, &stderr); code != 1 {
				t.Fatalf("exit = %d, want 1, stderr = %s", code, &stderr)
			}
			if stderr.Len() == 0 || stdout.Len() != 0 {
				t.Fatalf("failure must report an error without success output: stdout %q, stderr %q", &stdout, &stderr)
			}
			if failure == "missing symbol" && !strings.Contains(stderr.String(), "fixtureMissing") {
				t.Fatalf("missing symbol error does not name fixtureMissing: %s", &stderr)
			}
			got, err := os.ReadFile(fixture.outPath)
			if err != nil || !bytes.Equal(got, previous) {
				t.Fatalf("old output was changed: got %q, read error %v", got, err)
			}
		})
	}
}

func TestRunOutputError(t *testing.T) {
	fixture := newCLIFixture(t)
	fixture.outPath = filepath.Dir(fixture.outPath)
	var stdout, stderr bytes.Buffer
	if code := run(fixture.args(), &stdout, &stderr); code != 1 {
		t.Fatalf("exit = %d, want 1, stderr = %s", code, &stderr)
	}
	if stderr.Len() == 0 || stdout.Len() != 0 {
		t.Fatalf("expected output error without success, stdout %q, stderr %q", &stdout, &stderr)
	}
}
