package tradelog

import (
	"bufio"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// Synthetic bytes, never a ROM/save extract. The block positions below follow
// GetSubstruct's first column, independently of the production lookup table.
func pokemonFixture(personality uint32, species uint16) string {
	positions := [...]int{0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 2, 3,
		1, 1, 2, 3, 2, 3, 1, 1, 2, 3, 2, 3}
	data := make([]byte, 100)
	binary.LittleEndian.PutUint32(data[0:], personality)
	binary.LittleEndian.PutUint32(data[4:], 0xA1B2C3D4)
	secure := data[32:80]
	for i := range secure {
		secure[i] = byte(i*17 + 3)
	}
	binary.LittleEndian.PutUint16(secure[positions[personality%24]*12:], species)
	var checksum uint16
	for i := 0; i < len(secure); i += 2 {
		checksum += binary.LittleEndian.Uint16(secure[i:])
	}
	binary.LittleEndian.PutUint16(data[28:], checksum)
	for i := 0; i < len(secure); i += 4 {
		word := binary.LittleEndian.Uint32(secure[i:]) ^ personality ^ 0xA1B2C3D4
		binary.LittleEndian.PutUint32(secure[i:], word)
	}
	return hex.EncodeToString(data)
}

func TestPokemonSpeciesAllPermutations(t *testing.T) {
	for i := range uint32(24) {
		// Exercise the full 32-bit unsigned personality and OT encryption key.
		personality := uint32(0x80000010) + i
		encoded := pokemonFixture(personality, 65)
		p := NewPlayer("alice", 123, encoded)
		if p.SpeciesID != 65 || p.Species != "ALAKAZAM" || !p.ChecksumValid || p.Pokemon != encoded || p.TrainerID != 123 {
			t.Fatalf("permutation %d: %#v", personality%24, p)
		}
	}
}

func TestPokemonSpeciesNamesAndInvalidBytes(t *testing.T) {
	for _, tc := range []struct {
		id   uint16
		name string
	}{
		{0, "NONE"}, {29, "NIDORAN♀"}, {32, "NIDORAN♂"}, {122, "MR. MIME"},
		{277, "TREECKO"}, {411, "CHIMECHO"}, {412, "EGG"}, {65535, "UNKNOWN"},
	} {
		p := NewPlayer("a", 1, pokemonFixture(7, tc.id))
		if p.Species != tc.name || p.SpeciesID != tc.id || !p.ChecksumValid {
			t.Fatalf("species %d: %#v", tc.id, p)
		}
	}
	corrupt, _ := hex.DecodeString(pokemonFixture(9, 65))
	corrupt[28] ^= 1 // Annotate a bad checksum without discarding the evidence.
	p := NewPlayer("a", 1, hex.EncodeToString(corrupt))
	if p.ChecksumValid || p.Species != "ALAKAZAM" || p.Pokemon != hex.EncodeToString(corrupt) {
		t.Fatal("corrupt Pokemon was lost or silently declared valid")
	}
	for _, raw := range []string{"", "zz", strings.Repeat("00", 99), strings.Repeat("00", 101)} {
		p := NewPlayer("a", 1, raw)
		if p.ChecksumValid || p.Species != "UNKNOWN" || p.Pokemon != raw {
			t.Fatal("invalid input not handled safely")
		}
	}
}

func TestFileAppendAndRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), DefaultPath)
	stamp := time.Date(2026, 10, 27, 16, 0, 0, 0, time.FixedZone("test", -3*60*60))
	record := Record{Time: stamp, Players: [2]Player{NewPlayer("a", 1, pokemonFixture(0, 65)), NewPlayer("b", 2, pokemonFixture(23, 277))}}
	if err := NewFile(path).Append(record); err != nil {
		t.Fatal(err)
	}
	if err := NewFile(path).Append(record); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(string(data), "\n") {
		t.Fatal("missing JSON-line delimiter")
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d lines", len(lines))
	}
	for _, line := range lines {
		var got Record
		if err := json.Unmarshal([]byte(line), &got); err != nil {
			t.Fatal(err)
		}
		if !got.Time.Equal(stamp) || got.Time.Location() != time.UTC || got.Players != record.Players {
			t.Fatalf("record mismatch: %#v", got)
		}
	}
}

func TestFileConcurrentAppends(t *testing.T) {
	path := filepath.Join(t.TempDir(), DefaultPath)
	sink := NewFile(path)
	var workers sync.WaitGroup
	for range 24 {
		workers.Go(func() {
			if err := sink.Append(Record{Time: time.Now()}); err != nil {
				t.Error(err)
			}
		})
	}
	workers.Wait()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	count := 0
	for scanner.Scan() {
		var record Record
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
			t.Fatal(err)
		}
		count++
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if count != 24 {
		t.Fatalf("got %d complete JSON lines", count)
	}
}

func TestFileFailureAndRecovery(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "missing")
	sink := NewFile(filepath.Join(dir, DefaultPath))
	if err := sink.Append(Record{Time: time.Now()}); err == nil {
		t.Fatal("missing directory must fail")
	}
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := sink.Append(Record{Time: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := NewFile(dir).Append(Record{Time: time.Now()}); err == nil {
		t.Fatal("directory must fail as a file")
	}
}

func TestFileIncompleteTailIsPreservedAcrossReopen(t *testing.T) {
	for _, reopen := range []bool{false, true} {
		t.Run(map[bool]string{false: "same_writer", true: "reopened_writer"}[reopen], func(t *testing.T) {
			path := filepath.Join(t.TempDir(), DefaultPath)
			sink := NewFile(path)
			record := Record{Time: time.Now().UTC()}
			if err := sink.Append(record); err != nil {
				t.Fatal(err)
			}
			complete, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			// A previous failed write left a partial record after a valid line.
			original := append(append([]byte(nil), complete...), []byte(`{"time":"incomplete`)...)
			if err := os.WriteFile(path, original, 0o600); err != nil {
				t.Fatal(err)
			}
			if reopen {
				sink = NewFile(path)
			}
			for range 2 {
				if err := sink.Append(record); !errors.Is(err, ErrIncompleteTail) {
					t.Fatalf("wanted incomplete-tail error, got %v", err)
				}
			}
			got, err := os.ReadFile(path)
			if err != nil || string(got) != string(original) {
				t.Fatalf("refusal changed existing evidence: %v", err)
			}
		})
	}
}
