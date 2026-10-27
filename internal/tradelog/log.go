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
	output, err := os.OpenFile(f.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, output.Close()) }()
	n, err := output.Write(line)
	if err != nil {
		return err
	}
	if n != len(line) {
		return io.ErrShortWrite
	}
	return output.Sync()
}
