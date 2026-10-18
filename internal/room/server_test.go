package room

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"
)

type testPeer struct {
	conn    net.Conn
	decoder *protocol.Decoder
}

func testServer(t *testing.T, capacity int, configure func(*Server)) (*Server, string, func()) {
	t.Helper()
	s, err := New(Config{JoinKey: "test-key", MaxPlayers: capacity}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if configure != nil {
		configure(s)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	return s, ln.Addr().String(), serveTestListener(t, s, ln)
}

func serveTestListener(t *testing.T, s *Server, ln net.Listener) func() {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Serve(ctx, ln) }()
	var once sync.Once
	stop := func() {
		once.Do(func() {
			cancel()
			select {
			case err := <-done:
				if err != nil {
					t.Error(err)
				}
			case <-time.After(3 * time.Second):
				t.Error("server did not stop")
			}
		})
	}
	t.Cleanup(stop)
	return stop
}

func dial(t *testing.T, addr string) *testPeer {
	t.Helper()
	c, err := net.DialTimeout("tcp", addr, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return &testPeer{conn: c, decoder: protocol.NewDecoder(c)}
}

func (p *testPeer) raw(t *testing.T, line string) {
	t.Helper()
	if err := p.conn.SetWriteDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(p.conn, line); err != nil {
		t.Fatal(err)
	}
}

func (p *testPeer) send(t *testing.T, msg protocol.Message) {
	t.Helper()
	line, err := protocol.Encode(msg)
	if err != nil {
		t.Fatal(err)
	}
	p.raw(t, string(line))
}

func (p *testPeer) read(t *testing.T) protocol.Message {
	t.Helper()
	if err := p.conn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	msg, err := p.decoder.Decode()
	if err != nil {
		t.Fatal(err)
	}
	return msg
}

func (p *testPeer) closed(t *testing.T) {
	t.Helper()
	if err := p.conn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	_, err := p.decoder.Decode()
	if err == nil {
		t.Fatal("expected closed connection")
	}
	if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatalf("connection stayed open: %v", err)
	}
}

func hello(id string) protocol.Hello {
	return protocol.Hello{PlayerID: id, JoinKey: "test-key", TrainerID: 12345, Gender: protocol.GenderMale, ClientVersion: "0.2.0"}
}

func enter(t *testing.T, addr, id string) (*testPeer, protocol.Welcome) {
	t.Helper()
	p := dial(t, addr)
	p.send(t, hello(id))
	msg := p.read(t)
	w, ok := msg.(protocol.Welcome)
	if !ok {
		t.Fatalf("expected welcome, got %#v", msg)
	}
	return p, w
}

func want(t *testing.T, p *testPeer, expected protocol.Message) {
	t.Helper()
	if got := p.read(t); !reflect.DeepEqual(got, expected) {
		t.Fatalf("got %#v, want %#v", got, expected)
	}
}

func wantError(t *testing.T, p *testPeer, code string) {
	t.Helper()
	got, ok := p.read(t).(protocol.Error)
	if !ok || got.Code != code {
		t.Fatalf("got %#v, want error %s", got, code)
	}
	p.closed(t)
}

func TestLifecycle(t *testing.T) {
	_, addr, _ := testServer(t, 5, nil)
	a, w := enter(t, addr, "a")
	if len(w.Players) != 0 {
		t.Fatalf("first welcome: %#v", w)
	}
	// A pong is a barrier: the earlier presence must be stored before B joins.
	presence := protocol.PresenceState{MapGroup: 0, MapNum: 9, X: 5, Y: 3, Facing: 1, Visible: true}
	a.send(t, protocol.Presence{PlayerID: "a", PresenceState: presence})
	a.send(t, protocol.Ping{T: 1})
	want(t, a, protocol.Pong{T: 1})
	b, w := enter(t, addr, "b")
	expected := []protocol.Player{{PlayerID: "a", TrainerID: 12345, Gender: 0, Presence: &presence}}
	if !reflect.DeepEqual(w.Players, expected) {
		t.Fatalf("snapshot %#v, want %#v", w.Players, expected)
	}
	want(t, a, protocol.Join{PlayerID: "b", TrainerID: 12345, Gender: 0})
	b.conn.Close()
	want(t, a, protocol.Leave{PlayerID: "b", Reason: protocol.LeaveDisconnect})
	_, w = enter(t, addr, "c")
	if len(w.Players) != 1 || w.Players[0].PlayerID != "a" {
		t.Fatalf("stale player in snapshot: %#v", w)
	}
	want(t, a, protocol.Join{PlayerID: "c", TrainerID: 12345, Gender: 0})
}

func TestRejections(t *testing.T) {
	good, _ := protocol.Encode(hello("a"))
	for _, tc := range []struct{ name, line, code string }{
		{"wrong key", strings.Replace(string(good), "test-key", "wrong-key", 1), protocol.CodeBadKey},
		{"same-length wrong key", strings.Replace(string(good), "test-key", "test-kez", 1), protocol.CodeBadKey},
		{"wrong version", `{"v":2}` + "\n", protocol.CodeVersionMismatch},
		{"garbage", "not JSON\n", protocol.CodeBadMessage},
		{"oversized", strings.Repeat("x", protocol.MaxLineLength+1) + "\n", protocol.CodeBadMessage},
		{"missing hello", `{"v":1,"type":"ping","t":0}` + "\n", protocol.CodeBadHello},
		{"invalid hello", `{"v":1,"type":"hello"}` + "\n", protocol.CodeBadHello},
		{"invalid envelope", `{"type":"hello"}` + "\n", protocol.CodeBadMessage},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, addr, _ := testServer(t, 5, nil)
			p := dial(t, addr)
			p.raw(t, tc.line)
			wantError(t, p, tc.code)
		})
	}
}

func TestHelloDeadline(t *testing.T) {
	for _, unknown := range []bool{false, true} {
		t.Run(fmt.Sprint(unknown), func(t *testing.T) {
			_, addr, _ := testServer(t, 5, func(s *Server) {
				if s.helloTimeout != 5*time.Second {
					t.Error("production hello timeout must be 5s")
				}
				s.helloTimeout = 80 * time.Millisecond
			})
			p := dial(t, addr)
			if unknown {
				p.raw(t, `{"v":1,"type":"future"}`+"\n")
			}
			wantError(t, p, protocol.CodeBadHello)
		})
	}
}

func TestDuplicateReplacesAtCapacity(t *testing.T) {
	_, addr, _ := testServer(t, 2, nil)
	old, _ := enter(t, addr, "a")
	observer, _ := enter(t, addr, "b")
	want(t, old, protocol.Join{PlayerID: "b", TrainerID: 12345})
	full := dial(t, addr)
	full.send(t, hello("c"))
	wantError(t, full, protocol.CodeRoomFull)
	// Authentication must precede replacement, even in a full room.
	bad := dial(t, addr)
	h := hello("a")
	h.JoinKey = "wrong-key"
	bad.send(t, h)
	wantError(t, bad, protocol.CodeBadKey)
	replacement, w := enter(t, addr, "a")
	if len(w.Players) != 1 || w.Players[0].PlayerID != "b" {
		t.Fatalf("replacement snapshot: %#v", w)
	}
	want(t, observer, protocol.Leave{PlayerID: "a", Reason: protocol.LeaveReplaced})
	want(t, observer, protocol.Join{PlayerID: "a", TrainerID: 12345})
	old.closed(t)
	// Use another replacement as a barrier: a stale old handler must neither
	// remove the new session nor emit a spurious leave(disconnect).
	last, _ := enter(t, addr, "a")
	want(t, observer, protocol.Leave{PlayerID: "a", Reason: protocol.LeaveReplaced})
	want(t, observer, protocol.Join{PlayerID: "a", TrainerID: 12345})
	replacement.closed(t)
	last.conn.Close()
	want(t, observer, protocol.Leave{PlayerID: "a", Reason: protocol.LeaveDisconnect})
}

func TestMessagesAfterHello(t *testing.T) {
	for _, tc := range []struct{ name, line, code string }{
		{"malformed", "garbage\n", protocol.CodeBadMessage},
		{"invalid fields", `{"v":1,"type":"presence"}` + "\n", protocol.CodeBadMessage},
		{"version", `{"v":2}` + "\n", protocol.CodeVersionMismatch},
		{"server message", `{"v":1,"type":"welcome","players":[]}` + "\n", protocol.CodeBadMessage},
		{"second hello", func() string { b, _ := protocol.Encode(hello("a")); return string(b) }(), protocol.CodeBadMessage},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, addr, _ := testServer(t, 5, nil)
			a, _ := enter(t, addr, "a")
			b, _ := enter(t, addr, "b")
			want(t, a, protocol.Join{PlayerID: "b", TrainerID: 12345})
			a.raw(t, tc.line)
			wantError(t, a, tc.code)
			want(t, b, protocol.Leave{PlayerID: "a", Reason: protocol.LeaveDisconnect})
		})
	}
}

func TestUnknownTypesAreIgnored(t *testing.T) {
	_, addr, _ := testServer(t, 5, nil)
	a := dial(t, addr)
	a.raw(t, `{"v":1,"type":"future"}`+"\n")
	a.send(t, hello("a"))
	want(t, a, protocol.Welcome{Players: []protocol.Player{}})
	a.send(t, protocol.Ping{T: 1})
	want(t, a, protocol.Pong{T: 1})
	a.send(t, protocol.Presence{PlayerID: "a", PresenceState: protocol.PresenceState{Facing: 1}})
	a.raw(t, `{"v":1,"type":"future","payload":"ignored"}`+"\n")
	_, _ = enter(t, addr, "b")
	want(t, a, protocol.Join{PlayerID: "b", TrainerID: 12345})
}

func TestConcurrentCapacityAndShutdown(t *testing.T) {
	_, addr, stop := testServer(t, 5, nil)
	type result struct {
		conn net.Conn
		msg  protocol.Message
		err  error
	}
	results := make(chan result, 12)
	for i := range 12 {
		go func() {
			c, err := net.DialTimeout("tcp", addr, time.Second)
			if err != nil {
				results <- result{err: err}
				return
			}
			c.SetDeadline(time.Now().Add(2 * time.Second))
			line, _ := protocol.Encode(hello(fmt.Sprintf("p%d", i)))
			_, err = c.Write(line)
			var msg protocol.Message
			if err == nil {
				msg, err = protocol.NewDecoder(c).Decode()
			}
			results <- result{c, msg, err}
		}()
	}
	accepted := 0
	for range 12 {
		r := <-results
		if r.conn != nil {
			defer r.conn.Close()
		}
		if r.err != nil {
			t.Fatal(r.err)
		}
		switch m := r.msg.(type) {
		case protocol.Welcome:
			accepted++
		case protocol.Error:
			if m.Code != protocol.CodeRoomFull {
				t.Fatalf("unexpected rejection: %#v", m)
			}
		default:
			t.Fatalf("unexpected message %#v", m)
		}
	}
	if accepted != 5 {
		t.Fatalf("accepted %d, want 5", accepted)
	}
	// Cancellation must also close a connection still waiting for hello.
	unauthenticated := dial(t, addr)
	stop()
	unauthenticated.closed(t)
}

func TestLogsDoNotExposeSecrets(t *testing.T) {
	var logs bytes.Buffer
	_, addr, stop := testServer(t, 5, func(s *Server) { s.logger = log.New(&logs, "", 0) })
	a, _ := enter(t, addr, "a")
	bad := dial(t, addr)
	h := hello("b")
	h.JoinKey = "private-rejected-key"
	bad.send(t, h)
	wantError(t, bad, protocol.CodeBadKey)
	malformed := dial(t, addr)
	malformed.raw(t, `{"v":1,"type":"hello","joinKey":"test-key","trainerId":"private-invalid-value"}`+"\n")
	wantError(t, malformed, protocol.CodeBadHello)
	a.conn.Close()
	stop()
	for _, secret := range []string{"test-key", "private-rejected-key", "private-invalid-value"} {
		if strings.Contains(logs.String(), secret) {
			t.Fatalf("secret leaked: %s", secret)
		}
	}
	for _, event := range []string{"connect", "hello", "reject", "join", "leave"} {
		if !strings.Contains(logs.String(), "event="+event+" ") {
			t.Fatalf("missing event %s", event)
		}
	}
}
