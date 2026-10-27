package room

import (
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"
	"github.com/DaviAlencastro/EmeraldCo-Op/internal/tradelog"
)

type tradeLogFunc func(tradelog.Record) error

func (f tradeLogFunc) Append(r tradelog.Record) error { return f(r) }

// Synthetic struct Pokemon: permutation 0, key 0, just a species/checksum.
// These offsets are sourced in docs/memory-map.md#pokemon-bytes-in-the-trade-log.
func tradePokemon(species uint16) string {
	data := make([]byte, 100)
	binary.LittleEndian.PutUint16(data[32:], species)
	binary.LittleEndian.PutUint16(data[28:], species)
	return hex.EncodeToString(data)
}

func confirm(t *testing.T, from, to *testPeer, target, authenticatedID string, species uint16) {
	t.Helper()
	message := protocol.TradeConfirm{PlayerID: "forged", TargetID: target, Pokemon: tradePokemon(species)}
	from.send(t, message)
	message.PlayerID = authenticatedID
	want(t, to, message)
}

func waitTradeRecord(t *testing.T, records <-chan tradelog.Record) tradelog.Record {
	t.Helper()
	select {
	case r := <-records:
		return r
	case <-time.After(2 * time.Second):
		t.Fatal("trade audit record did not arrive")
		return tradelog.Record{}
	}
}

func TestTradeLogTwoConfirmsAndNextTrade(t *testing.T) {
	path := filepath.Join(t.TempDir(), tradelog.DefaultPath)
	records := make(chan tradelog.Record, 8)
	sink := tradelog.NewFile(path)
	_, addr, _ := testServer(t, 5, func(s *Server) {
		s.cfg.TradeLog = tradeLogFunc(func(r tradelog.Record) error {
			if err := sink.Append(r); err != nil {
				return err
			}
			records <- r
			return nil
		})
	})
	a := dial(t, addr)
	h := hello("a")
	h.TrainerID = 101
	a.send(t, h)
	want(t, a, protocol.Welcome{Players: []protocol.Player{}})
	b := dial(t, addr)
	h = hello("b")
	h.TrainerID = 202
	b.send(t, h)
	_ = b.read(t)
	want(t, a, protocol.Join{PlayerID: "b", TrainerID: 202})
	for range 2 {
		confirm(t, b, a, "a", "b", 277) // Arrival order differs from canonical ID order.
		confirm(t, b, a, "a", "b", 277) // A repeated same-side confirm cannot complete it.
		select {
		case <-records:
			t.Fatal("single-sided confirm was logged")
		default:
		}
		confirm(t, a, b, "b", "a", 65)
		r := waitTradeRecord(t, records)
		if r.Time.IsZero() || r.Time.Location() != time.UTC || r.Players[0] != tradelog.NewPlayer("a", 101, tradePokemon(65)) || r.Players[1] != tradelog.NewPlayer("b", 202, tradePokemon(277)) {
			t.Fatalf("wrong audit fields: %#v", r)
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d lines for two trades", len(lines))
	}
	for _, line := range lines {
		var fields map[string]json.RawMessage
		if err := json.Unmarshal([]byte(line), &fields); err != nil {
			t.Fatal(err)
		}
		if len(fields) != 2 || fields["time"] == nil || fields["players"] == nil {
			t.Fatal("unexpected top-level audit fields")
		}
	}
	for _, private := range []string{"test-key", "127.0.0.1", "joinKey", "remote", "forged"} {
		if strings.Contains(string(data), private) {
			t.Fatalf("audit contains private/untrusted value %q", private)
		}
	}
}

func TestTradeLogDiscardLifecycle(t *testing.T) {
	for _, kind := range []string{"cancel", "decline", "invite", "disconnect", "replace"} {
		t.Run(kind, func(t *testing.T) {
			records := make(chan tradelog.Record, 8)
			_, addr, _ := testServer(t, 5, func(s *Server) {
				s.cfg.TradeLog = tradeLogFunc(func(r tradelog.Record) error { records <- r; return nil })
			})
			a, _ := enter(t, addr, "a")
			b, _ := enter(t, addr, "b")
			_ = a.read(t)
			confirm(t, a, b, "b", "a", 65)
			switch kind {
			case "cancel":
				b.send(t, protocol.TradeCancel{PlayerID: "b", TargetID: "a", Reason: protocol.CancelCanceled})
				_ = a.read(t)
			case "decline":
				b.send(t, protocol.TradeDecline{PlayerID: "b", TargetID: "a", Reason: protocol.DeclineDeclined})
				_ = a.read(t)
			case "invite":
				b.send(t, protocol.TradeInvite{PlayerID: "b", TargetID: "a"})
				_ = a.read(t)
			case "disconnect":
				b.conn.Close()
				want(t, a, protocol.Leave{PlayerID: "b", Reason: protocol.LeaveDisconnect})
				b, _ = enter(t, addr, "b")
				_ = a.read(t)
			case "replace":
				b, _ = enter(t, addr, "b")
				want(t, a, protocol.Leave{PlayerID: "b", Reason: protocol.LeaveReplaced})
				_ = a.read(t)
			}
			confirm(t, b, a, "a", "b", 277)
			// A ping on B is a barrier after the attempted match/log call.
			b.send(t, protocol.Ping{T: 1})
			want(t, b, protocol.Pong{T: 1})
			select {
			case <-records:
				t.Fatal("stale confirmation survived lifecycle change")
			default:
			}
			confirm(t, a, b, "b", "a", 65)
			waitTradeRecord(t, records)
		})
	}
}

func TestTradeLogMissingAndSelfTargetRemainStateless(t *testing.T) {
	s, addr, _ := testServer(t, 5, func(s *Server) {
		s.cfg.TradeLog = tradeLogFunc(func(tradelog.Record) error { t.Error("unexpected audit record"); return nil })
	})
	a, _ := enter(t, addr, "a")
	b, _ := enter(t, addr, "b")
	_ = a.read(t)
	for _, target := range []string{"nobody", "a"} {
		confirm(t, a, b, target, "a", 65)
	}
	a.send(t, protocol.Ping{T: 1})
	want(t, a, protocol.Pong{T: 1})
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.confirms) != 0 {
		t.Fatal("invalid targets retained audit state")
	}
}

func TestTradeLogFailureDoesNotStopRelay(t *testing.T) {
	records := make(chan tradelog.Record, 1)
	logs := make(chan string, 32)
	_, addr, _ := testServer(t, 5, func(s *Server) {
		s.cfg.TradeLog = tradeLogFunc(func(r tradelog.Record) error { records <- r; return errors.New("private-path test-key") })
		s.logger = log.New(logChannel(logs), "", 0)
	})
	a, _ := enter(t, addr, "a")
	b, _ := enter(t, addr, "b")
	_ = a.read(t)
	confirm(t, a, b, "b", "a", 65)
	confirm(t, b, a, "a", "b", 277)
	waitTradeRecord(t, records)
	b.send(t, protocol.Ping{T: 9})
	want(t, b, protocol.Pong{T: 9})
	presence := protocol.Presence{PlayerID: "a", PresenceState: protocol.PresenceState{Facing: 1}}
	a.send(t, presence)
	want(t, b, presence)
	found := false
	for len(logs) > 0 {
		line := <-logs
		if strings.Contains(line, "private-path") || strings.Contains(line, "test-key") {
			t.Fatal("raw audit error leaked")
		}
		found = found || strings.Contains(line, "event=trade_log_error")
	}
	if !found {
		t.Fatal("audit failure was not reported as a server error")
	}
}

type logChannel chan string

func (ch logChannel) Write(p []byte) (int, error) { ch <- string(p); return len(p), nil }

func TestTradeLogSlowDiskDoesNotLockRoom(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	defer close(release)
	_, addr, _ := testServer(t, 5, func(s *Server) {
		s.cfg.TradeLog = tradeLogFunc(func(tradelog.Record) error { close(started); <-release; return nil })
	})
	a, _ := enter(t, addr, "a")
	b, _ := enter(t, addr, "b")
	_ = a.read(t)
	confirm(t, a, b, "b", "a", 65)
	confirm(t, b, a, "a", "b", 277)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("audit writer did not start")
	}
	a.send(t, protocol.Ping{T: 5})
	want(t, a, protocol.Pong{T: 5})
	// Another client can join while B's handler waits for storage.
	c, _ := enter(t, addr, "c")
	_ = c
}

func TestTradeLogPairSurvivesDropWhileBroadcastingSecondConfirm(t *testing.T) {
	records := make(chan tradelog.Record, 1)
	s, err := New(Config{JoinKey: "test-key", MaxPlayers: 5,
		TradeLog: tradeLogFunc(func(r tradelog.Record) error { records <- r; return nil })}, nil)
	if err != nil {
		t.Fatal(err)
	}
	aConn, aPeer := net.Pipe()
	defer aConn.Close()
	defer aPeer.Close()
	bConn, bPeer := net.Pipe()
	defer bConn.Close()
	defer bPeer.Close()
	a := &client{conn: aConn, player: protocol.Player{PlayerID: "a", TrainerID: 1}, outbox: make(chan []byte, 1), stop: make(chan struct{})}
	b := &client{conn: bConn, player: protocol.Player{PlayerID: "b", TrainerID: 2}, outbox: make(chan []byte, 4), stop: make(chan struct{})}
	s.players["a"], s.players["b"] = a, b
	s.relay(a, protocol.TradeConfirm{PlayerID: "forged", TargetID: "b", Pokemon: tradePokemon(65)})
	// Both players have confirmed while authenticated. A full recipient queue
	// during the second broadcast must not erase those diagnostic facts.
	a.outbox <- []byte("full")
	s.relay(b, protocol.TradeConfirm{PlayerID: "forged", TargetID: "a", Pokemon: tradePokemon(277)})
	if s.players["a"] != nil {
		t.Fatal("test did not drop the slow recipient")
	}
	select {
	case r := <-records:
		if r.Players[0].PlayerID != "a" || r.Players[1].PlayerID != "b" {
			t.Fatal("wrong confirmation snapshots")
		}
	default:
		t.Fatal("broadcast cleanup erased a completed confirmation pair")
	}
}
