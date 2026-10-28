// Package tradelog writes the local, append-only trade-confirmation audit log.
package tradelog

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"sync"
	"time"
)

// DefaultPath is relative to the server's working directory, including go run.
const DefaultPath = "trade-log.jsonl"

// ErrIncompleteTail preserves a failed write for inspection instead of joining
// the next record to it. An operator must repair the tail before appends resume.
var ErrIncompleteTail = errors.New("trade log has an incomplete trailing record")

// Player is one authenticated sender and the exact Pokemon it offered.
type Player struct {
	PlayerID      string `json:"playerId"`
	TrainerID     uint32 `json:"trainerId"`
	SpeciesID     uint16 `json:"speciesId"`
	Species       string `json:"species"`
	ChecksumValid bool   `json:"checksumValid"`
	Pokemon       string `json:"pokemon"`
}

// Record means both clients confirmed, not proof that either save completed.
// Players are ordered by player ID so arrival order cannot swap the fields.
type Record struct {
	Time    time.Time `json:"time"`
	Players [2]Player `json:"players"`
}

// NewPlayer describes a protocol-validated, encrypted struct Pokemon without
// changing its bytes. Invalid checksums are annotated, not rejected by the relay.
func NewPlayer(id string, trainerID uint32, pokemon string) Player {
	species, name, valid := describePokemon(pokemon)
	return Player{PlayerID: id, TrainerID: trainerID, SpeciesID: species,
		Species: name, ChecksumValid: valid, Pokemon: pokemon}
}

// File appends one JSON line per record. File I/O must run outside the room lock.
// Reopening per record permits recovery after an operator fixes a missing path.
type File struct {
	path string
	mu   sync.Mutex
}

func NewFile(path string) *File { return &File{path: path} }

func (f *File) Append(record Record) (err error) {
	record.Time = record.Time.UTC()
	line, err := json.Marshal(record)
	if err != nil {
		return err
	}
	line = append(line, '\n')
	f.mu.Lock()
	defer f.mu.Unlock()
	output, err := os.OpenFile(f.path, os.O_CREATE|os.O_RDWR|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, output.Close()) }()
	info, err := output.Stat()
	if err != nil {
		return err
	}
	if info.Size() != 0 {
		var last [1]byte
		if _, err := output.ReadAt(last[:], info.Size()-1); err != nil {
			return err
		}
		if last[0] != '\n' {
			return ErrIncompleteTail
		}
	}
	n, err := output.Write(line)
	if err != nil {
		return err
	}
	if n != len(line) {
		return io.ErrShortWrite
	}
	return output.Sync()
}
