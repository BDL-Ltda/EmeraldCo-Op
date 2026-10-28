package tradelog

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestFilePartialWriteAndStorageRecovery(t *testing.T) {
	for _, reopen := range []bool{false, true} {
		t.Run(map[bool]string{false: "same_writer", true: "reopened_writer"}[reopen], func(t *testing.T) {
			path := filepath.Join(t.TempDir(), DefaultPath)
			sink := NewFile(path)
			record := Record{Time: time.Now().UTC()}
			// Exercise a real partial filesystem write without mocking File.Append.
			// This process-wide limit must not run in parallel with other tests.
			var original syscall.Rlimit
			if err := syscall.Getrlimit(syscall.RLIMIT_FSIZE, &original); err != nil {
				t.Fatal(err)
			}
			limited := original
			limited.Cur = 64
			if err := syscall.Setrlimit(syscall.RLIMIT_FSIZE, &limited); err != nil {
				t.Fatal(err)
			}
			defer syscall.Setrlimit(syscall.RLIMIT_FSIZE, &original)
			writeErr := sink.Append(record)
			if err := syscall.Setrlimit(syscall.RLIMIT_FSIZE, &original); err != nil {
				t.Fatal(err)
			}
			if writeErr == nil {
				t.Fatal("file-size limit must fail the first append")
			}
			partial, err := os.ReadFile(path)
			if err != nil || len(partial) != 64 || bytes.HasSuffix(partial, []byte("\n")) {
				t.Fatalf("partial write not reproduced: %d bytes, %v", len(partial), err)
			}
			if reopen {
				sink = NewFile(path)
			}
			if err := sink.Append(record); !errors.Is(err, ErrIncompleteTail) {
				t.Fatalf("storage recovery must not silently concatenate records: %v", err)
			}
			unchanged, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(unchanged, partial) {
				t.Fatalf("partial record was modified: %v", err)
			}
			// Model an explicit operator repair: keep the fragment as evidence and
			// terminate its line. The application must not do this automatically.
			output, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
			if err != nil {
				t.Fatal(err)
			}
			_, writeErr = output.Write([]byte("\n"))
			closeErr := output.Close()
			if err := errors.Join(writeErr, closeErr); err != nil {
				t.Fatal(err)
			}
			if err := sink.Append(record); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			lines := bytes.Split(bytes.TrimSuffix(data, []byte("\n")), []byte("\n"))
			if len(lines) != 2 || !bytes.Equal(lines[0], partial) || !json.Valid(lines[1]) {
				t.Fatal("operator repair did not isolate a valid new JSON record")
			}
		})
	}
}
