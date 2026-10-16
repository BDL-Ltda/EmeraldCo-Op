package room

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"
)

type temporaryAcceptError struct{}

func (temporaryAcceptError) Error() string   { return "temporary accept failure" }
func (temporaryAcceptError) Temporary() bool { return true }

type acceptListener struct {
	net.Listener
	accept func() (net.Conn, error)
}

func (l *acceptListener) Accept() (net.Conn, error) { return l.accept() }

func TestTemporaryAcceptFailurePreservesPlayers(t *testing.T) {
	s, err := New(Config{JoinKey: "test-key", MaxPlayers: 5}, nil)
	if err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	failures := make(chan time.Time, 2)
	ready, releaseFailure := context.WithCancel(context.Background())
	wrapped := &acceptListener{Listener: ln}
	wrapped.accept = func() (net.Conn, error) {
		calls++
		if calls == 2 {
			<-ready.Done() // Fail only after the first player is authenticated.
		}
		if calls == 2 || calls == 3 {
			failures <- time.Now()
			return nil, fmt.Errorf("accept: %w", temporaryAcceptError{})
		}
		return ln.Accept()
	}
	serveTestListener(t, s, wrapped)
	t.Cleanup(releaseFailure)
	a, _ := enter(t, ln.Addr().String(), "a")
	releaseFailure()
	_, _ = enter(t, ln.Addr().String(), "b")
	want(t, a, protocol.Join{PlayerID: "b", TrainerID: 12345})
	first, second := <-failures, <-failures
	if second.Sub(first) < 4*time.Millisecond {
		t.Fatal("temporary accept errors were retried without backoff")
	}
}

func TestAcceptBackoffCancellationAndPermanentErrors(t *testing.T) {
	t.Run("cancel temporary retries", func(t *testing.T) {
		s, err := New(Config{JoinKey: "test-key", MaxPlayers: 5}, nil)
		if err != nil {
			t.Fatal(err)
		}
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		attempts := make(chan struct{}, 1)
		wrapped := &acceptListener{Listener: ln, accept: func() (net.Conn, error) {
			select {
			case attempts <- struct{}{}:
			default:
			}
			return nil, temporaryAcceptError{}
		}}
		stop := serveTestListener(t, s, wrapped)
		select {
		case <-attempts:
		case <-time.After(time.Second):
			t.Fatal("no accept attempt")
		}
		stop()
	})
	t.Run("permanent error", func(t *testing.T) {
		s, err := New(Config{JoinKey: "test-key", MaxPlayers: 5}, nil)
		if err != nil {
			t.Fatal(err)
		}
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer ln.Close()
		permanent := errors.New("permanent listener failure")
		wrapped := &acceptListener{Listener: ln, accept: func() (net.Conn, error) { return nil, permanent }}
		if err := s.Serve(context.Background(), wrapped); !errors.Is(err, permanent) {
			t.Fatalf("got %v, want permanent failure", err)
		}
	})
}

type failingReadConn struct {
	net.Conn
	err    error
	writes int
}

func (c *failingReadConn) Read([]byte) (int, error)    { return 0, c.err }
func (c *failingReadConn) Write(p []byte) (int, error) { c.writes++; return len(p), nil }

func TestHandshakeTransportErrorsAreNotRejections(t *testing.T) {
	for _, readErr := range []error{io.EOF, net.ErrClosed, &net.OpError{Op: "read", Net: "tcp", Err: syscall.ECONNRESET}} {
		t.Run(readErr.Error(), func(t *testing.T) {
			var logs bytes.Buffer
			s, err := New(Config{JoinKey: "test-key", MaxPlayers: 5}, log.New(&logs, "", 0))
			if err != nil {
				t.Fatal(err)
			}
			server, peer := net.Pipe()
			defer peer.Close()
			conn := &failingReadConn{Conn: server, err: readErr}
			s.handle(conn)
			if conn.writes != 0 {
				t.Fatal("wrote an error response to a failed transport")
			}
			if strings.Contains(logs.String(), "event=reject ") {
				t.Fatalf("transport failure logged as protocol rejection: %s", logs.String())
			}
		})
	}
}

func TestUnknownLogsAreBoundedAcrossHandshake(t *testing.T) {
	var logs bytes.Buffer
	_, addr, stop := testServer(t, 5, func(s *Server) { s.logger = log.New(&logs, "", 0) })
	a := dial(t, addr)
	unknown := strings.Repeat(`{"v":1,"type":"future"}`+"\n", 100)
	a.raw(t, unknown)
	a.send(t, hello("a"))
	want(t, a, protocol.Welcome{Players: []protocol.Player{}})
	a.raw(t, unknown)
	// The rejection is a barrier: all preceding unknown messages were read.
	a.raw(t, "garbage\n")
	wantError(t, a, protocol.CodeBadMessage)
	b := dial(t, addr)
	b.raw(t, unknown)
	b.send(t, hello("b"))
	want(t, b, protocol.Welcome{Players: []protocol.Player{}})
	stop()
	if count := strings.Count(logs.String(), "event=unknown "); count != 2 {
		t.Fatalf("got %d unknown logs for two connections; want one each", count)
	}
}

func TestReplacementCanUseANewTrainerID(t *testing.T) {
	_, addr, _ := testServer(t, 2, nil)
	old, _ := enter(t, addr, "a")
	replacement := dial(t, addr)
	h := hello("a")
	h.TrainerID++ // A new save may have a different in-game trainer identity.
	replacement.send(t, h)
	want(t, replacement, protocol.Welcome{Players: []protocol.Player{}})
	old.closed(t)
	_, welcome := enter(t, addr, "b")
	if len(welcome.Players) != 1 || welcome.Players[0].TrainerID != h.TrainerID {
		t.Fatalf("replacement identity not reflected in snapshot: %#v", welcome)
	}
	want(t, replacement, protocol.Join{PlayerID: "b", TrainerID: 12345})
}
