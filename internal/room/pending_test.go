package room

import (
	"bytes"
	"errors"
	"log"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"
)

func waitPending(t *testing.T, s *Server, n int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for len(s.pending) != n {
		if time.Now().After(deadline) {
			t.Fatalf("pending handshakes = %d, want %d", len(s.pending), n)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func holdPending(t *testing.T, s *Server, addr string) *testPeer {
	t.Helper()
	n := len(s.pending)
	p := dial(t, addr)
	waitPending(t, s, n+1)
	return p
}

func TestDefaultPendingHandshakeCap(t *testing.T) {
	s, err := New(Config{JoinKey: "test-key", MaxPlayers: 5}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if cap(s.pending) != 16 {
		t.Fatalf("pending handshake cap = %d, want 16", cap(s.pending))
	}
}

func TestPendingCapKeepsPlayersAndReleasesSlots(t *testing.T) {
	var logs bytes.Buffer
	s, addr, stop := testServer(t, 5, func(s *Server) {
		s.logger = log.New(&logs, "", 0)
		s.pending = make(chan struct{}, 2)
		s.helloTimeout = time.Minute
	})
	a, _ := enter(t, addr, "a")
	waitPending(t, s, 0)
	idle1 := holdPending(t, s, addr)
	idle2 := holdPending(t, s, addr)
	for range 5 {
		dial(t, addr).closed(t) // Over the cap: closed without a reply.
	}
	a.send(t, protocol.Ping{T: 1})
	want(t, a, protocol.Pong{T: 1})

	// Successful authentication frees the slot for a new connection.
	idle1.send(t, hello("b"))
	if _, ok := idle1.read(t).(protocol.Welcome); !ok {
		t.Fatal("expected welcome")
	}
	want(t, a, protocol.Join{PlayerID: "b", TrainerID: 12345})
	waitPending(t, s, 1)
	idle3 := holdPending(t, s, addr)
	dial(t, addr).closed(t)

	// Rejection and transport failure free their slots too.
	bad := hello("c")
	bad.JoinKey = "wrong-key"
	idle2.send(t, bad)
	wantError(t, idle2, protocol.CodeBadKey)
	waitPending(t, s, 1)
	idle3.conn.Close()
	waitPending(t, s, 0)

	a.send(t, protocol.Ping{T: 2})
	want(t, a, protocol.Pong{T: 2})
	idle1.send(t, protocol.Ping{T: 3})
	want(t, idle1, protocol.Pong{T: 3})
	stop()
	if got := strings.Count(logs.String(), "event=pending_full "); got != 2 {
		t.Fatalf("want one pending_full log per overload episode (2), got %d:\n%s", got, logs.String())
	}
}

func TestHelloTimeoutReleasesPendingSlots(t *testing.T) {
	s, addr, _ := testServer(t, 5, func(s *Server) {
		s.pending = make(chan struct{}, 2)
		s.helloTimeout = 100 * time.Millisecond
	})
	first := holdPending(t, s, addr)
	second := holdPending(t, s, addr)
	wantError(t, first, protocol.CodeBadHello)
	wantError(t, second, protocol.CodeBadHello)
	waitPending(t, s, 0)
	enter(t, addr, "a")
}

func TestShutdownReleasesPendingSlots(t *testing.T) {
	s, addr, stop := testServer(t, 5, func(s *Server) {
		s.pending = make(chan struct{}, 2)
		s.helloTimeout = time.Minute
	})
	first := holdPending(t, s, addr)
	second := holdPending(t, s, addr)
	stop()
	if len(s.pending) != 0 {
		t.Fatalf("pending handshakes after shutdown = %d", len(s.pending))
	}
	first.closed(t)
	second.closed(t)
}

func TestConcurrentConnectionsNeverExceedPendingCap(t *testing.T) {
	const capacity, attempts = 4, 20
	s, addr, _ := testServer(t, 5, func(s *Server) {
		s.pending = make(chan struct{}, capacity)
		s.helloTimeout = time.Minute
	})
	conns := make([]net.Conn, attempts)
	var wg sync.WaitGroup
	for i := range conns {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if c, err := net.DialTimeout("tcp", addr, time.Second); err == nil {
				conns[i] = c
			}
		}()
	}
	wg.Wait()
	held := 0
	for _, c := range conns {
		if c == nil {
			continue
		}
		t.Cleanup(func() { c.Close() })
		if err := c.SetReadDeadline(time.Now().Add(500 * time.Millisecond)); err != nil {
			t.Fatal(err)
		}
		var netErr net.Error
		if _, err := c.Read(make([]byte, 1)); errors.As(err, &netErr) && netErr.Timeout() {
			held++
		}
	}
	if held != capacity || len(s.pending) != capacity {
		t.Fatalf("held %d connections with %d pending slots, want %d", held, len(s.pending), capacity)
	}
}
