package room

import (
	"bytes"
	"fmt"
	"log"
	"math"
	"net"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"
)

func TestPresenceUsesConnectionIdentityAndDoesNotEcho(t *testing.T) {
	_, addr, _ := testServer(t, 5, nil)
	a, _ := enter(t, addr, "a")
	b, _ := enter(t, addr, "b")
	want(t, a, protocol.Join{PlayerID: "b", TrainerID: 12345})
	c, _ := enter(t, addr, "c")
	want(t, a, protocol.Join{PlayerID: "c", TrainerID: 12345})
	want(t, b, protocol.Join{PlayerID: "c", TrainerID: 12345})
	state := protocol.PresenceState{MapGroup: 0, MapNum: 9, X: 4, Y: 7, Facing: 3, Visible: true}
	a.send(t, protocol.Presence{PlayerID: "b", PresenceState: state})
	expected := protocol.Presence{PlayerID: "a", PresenceState: state}
	want(t, b, expected)
	want(t, c, expected)
	a.send(t, protocol.Ping{T: 42})
	want(t, a, protocol.Pong{T: 42}) // Any presence echoed to A would fail this.
	d, welcome := enter(t, addr, "d")
	if len(welcome.Players) != 3 || welcome.Players[0].PlayerID != "a" || !reflect.DeepEqual(welcome.Players[0].Presence, &state) {
		t.Fatalf("welcome did not retain authenticated presence: %#v", welcome)
	}
	for _, peer := range []*testPeer{a, b, c} {
		want(t, peer, protocol.Join{PlayerID: "d", TrainerID: 12345})
	}
	state.X++
	state.Visible = false
	a.send(t, protocol.Presence{PlayerID: "d", PresenceState: state})
	for _, peer := range []*testPeer{b, c, d} {
		want(t, peer, protocol.Presence{PlayerID: "a", PresenceState: state})
	}
}

func TestPingEchoesExactTimestamp(t *testing.T) {
	_, addr, _ := testServer(t, 5, nil)
	a, _ := enter(t, addr, "a")
	for _, stamp := range []int64{0, 1712345678901, math.MaxInt64} {
		a.send(t, protocol.Ping{T: stamp})
		want(t, a, protocol.Pong{T: stamp})
	}
}

func TestSilentClientTimesOutWhileActivePeerStays(t *testing.T) {
	_, addr, _ := testServer(t, 5, func(s *Server) {
		if s.idleTimeout != 15*time.Second {
			t.Fatal("production idle timeout must be 15s")
		}
		s.idleTimeout = 250 * time.Millisecond
	})
	a, _ := enter(t, addr, "a")
	b, _ := enter(t, addr, "b")
	want(t, a, protocol.Join{PlayerID: "b", TrainerID: 12345})
	start := time.Now()
	tick := time.NewTicker(30 * time.Millisecond)
	defer tick.Stop()
	left := false
	for stamp := int64(1); !left && stamp <= 30; stamp++ {
		<-tick.C
		a.send(t, protocol.Ping{T: stamp})
		for {
			msg := a.read(t)
			if leave, ok := msg.(protocol.Leave); ok {
				if leave.PlayerID != "b" || leave.Reason != protocol.LeaveTimeout {
					t.Fatalf("unexpected leave: %#v", leave)
				}
				left = true
				continue
			}
			if !reflect.DeepEqual(msg, protocol.Pong{T: stamp}) {
				t.Fatalf("unexpected message %#v", msg)
			}
			break
		}
	}
	if !left {
		t.Fatal("silent player did not time out")
	}
	if time.Since(start) < 180*time.Millisecond {
		t.Fatal("silent player removed too early")
	}
	b.closed(t)
	a.send(t, protocol.Ping{T: 100})
	want(t, a, protocol.Pong{T: 100})
}

func TestCompleteMessagesRefreshIdleDeadline(t *testing.T) {
	_, addr, _ := testServer(t, 5, func(s *Server) { s.idleTimeout = 180 * time.Millisecond })
	a, _ := enter(t, addr, "a")
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for stamp := int64(1); stamp <= 6; stamp++ {
		<-tick.C
		a.send(t, protocol.Ping{T: stamp})
		want(t, a, protocol.Pong{T: stamp})
	}
	a.closed(t) // Once messages stop, the refreshed deadline still expires.
}

func TestMessageFloodIsRejectedBeforeAndAfterHello(t *testing.T) {
	for _, authenticated := range []bool{false, true} {
		t.Run(fmt.Sprint(authenticated), func(t *testing.T) {
			s, addr, _ := testServer(t, 5, nil)
			if s.rateLimit != 50 {
				t.Fatal("production rate must be 50 messages in a rolling second")
			}
			observer, _ := enter(t, addr, "observer")
			p := dial(t, addr)
			if authenticated {
				p.send(t, hello("flood"))
				_ = p.read(t)
				want(t, observer, protocol.Join{PlayerID: "flood", TrainerID: 12345})
			}
			p.raw(t, strings.Repeat(`{"v":1,"type":"future"}`+"\n", s.rateLimit+1))
			wantError(t, p, protocol.CodeBadMessage)
			if authenticated {
				want(t, observer, protocol.Leave{PlayerID: "flood", Reason: protocol.LeaveDisconnect})
			}
			observer.send(t, protocol.Ping{T: 7})
			want(t, observer, protocol.Pong{T: 7})
		})
	}
}

func TestRollingRateWindowHasNoBoundaryBurst(t *testing.T) {
	s, err := New(Config{JoinKey: "test-key", MaxPlayers: 5}, nil)
	if err != nil {
		t.Fatal(err)
	}
	c := &client{}
	start := time.Now()
	for range 49 {
		if !s.allowMessage(c, start) {
			t.Fatal("initial allowance rejected")
		}
	}
	if !s.allowMessage(c, start.Add(900*time.Millisecond)) {
		t.Fatal("50th message rejected")
	}
	for range 49 {
		if !s.allowMessage(c, start.Add(time.Second)) {
			t.Fatal("expired messages still counted")
		}
	}
	if s.allowMessage(c, start.Add(time.Second)) {
		t.Fatal("accepted more than 50 messages across a window boundary")
	}
	if !s.allowMessage(c, start.Add(1900*time.Millisecond)) {
		t.Fatal("oldest message did not expire")
	}
	if s.allowMessage(c, start.Add(1900*time.Millisecond)) {
		t.Fatal("accepted a 51st message in the rolling window")
	}
}

// stalledPresenceConn simulates a socket whose receiver stopped draining data.
// Unlike OS buffers, its first blocked presence write is deterministic.
type stalledPresenceConn struct {
	net.Conn
	blocked   chan struct{}
	closed    chan struct{}
	blockOnce sync.Once
	closeOnce sync.Once
}

func (c *stalledPresenceConn) Write(p []byte) (int, error) {
	if bytes.Contains(p, []byte(`"type":"presence"`)) {
		c.blockOnce.Do(func() { close(c.blocked) })
		<-c.closed
		return 0, net.ErrClosed
	}
	return c.Conn.Write(p)
}

func (c *stalledPresenceConn) Close() error {
	c.closeOnce.Do(func() { close(c.closed) })
	return c.Conn.Close()
}

func TestFullSendQueueDropsOnlySlowPeer(t *testing.T) {
	var logs bytes.Buffer
	s, err := New(Config{JoinKey: "test-key", MaxPlayers: 5}, log.New(&logs, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	s.sendQueueSize = 4
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	wrapped := &acceptListener{Listener: ln}
	first := true
	slowConn := make(chan *stalledPresenceConn, 1)
	wrapped.accept = func() (net.Conn, error) {
		conn, err := ln.Accept()
		if err == nil && first {
			first = false
			c := &stalledPresenceConn{Conn: conn, blocked: make(chan struct{}), closed: make(chan struct{})}
			slowConn <- c
			return c, nil
		}
		return conn, err
	}
	stop := serveTestListener(t, s, wrapped)
	slow, _ := enter(t, ln.Addr().String(), "slow")
	controlled := <-slowConn
	a, _ := enter(t, ln.Addr().String(), "a")
	want(t, slow, protocol.Join{PlayerID: "a", TrainerID: 12345})
	b, _ := enter(t, ln.Addr().String(), "b")
	want(t, slow, protocol.Join{PlayerID: "b", TrainerID: 12345})
	want(t, a, protocol.Join{PlayerID: "b", TrainerID: 12345})
	sawLeave := false
	for x := range 7 {
		state := protocol.PresenceState{X: x, Facing: 1, Visible: true}
		a.send(t, protocol.Presence{PlayerID: "a", PresenceState: state})
		for {
			msg := b.read(t)
			if leave, ok := msg.(protocol.Leave); ok {
				if leave.PlayerID != "slow" || leave.Reason != protocol.LeaveDisconnect {
					t.Fatalf("unexpected leave %#v", leave)
				}
				sawLeave = true
				continue
			}
			if !reflect.DeepEqual(msg, protocol.Presence{PlayerID: "a", PresenceState: state}) {
				t.Fatalf("bad relay: %#v", msg)
			}
			break
		}
		if x == 0 {
			select {
			case <-controlled.blocked:
			case <-time.After(time.Second):
				t.Fatal("slow writer did not block")
			}
		}
	}
	select {
	case <-controlled.closed:
	case <-time.After(time.Second):
		t.Fatal("full queue did not close slow connection")
	}
	b.send(t, protocol.Ping{T: 99})
	for {
		msg := b.read(t)
		if leave, ok := msg.(protocol.Leave); ok && leave.PlayerID == "slow" {
			sawLeave = true
			continue
		}
		if !reflect.DeepEqual(msg, protocol.Pong{T: 99}) {
			t.Fatalf("fast peer stalled: %#v", msg)
		}
		break
	}
	if !sawLeave {
		t.Fatal("no leave notification for slow peer")
	}
	want(t, a, protocol.Leave{PlayerID: "slow", Reason: protocol.LeaveDisconnect})
	slow.closed(t)
	stop()
	if !strings.Contains(logs.String(), `event=drop `) || !strings.Contains(logs.String(), `reason="send_queue_full"`) {
		t.Fatal("queue overflow was not logged")
	}
}

func TestReplacedReaderCannotPublishPresence(t *testing.T) {
	s, addr, _ := testServer(t, 5, nil)
	old, _ := enter(t, addr, "a")
	observer, _ := enter(t, addr, "b")
	want(t, old, protocol.Join{PlayerID: "b", TrainerID: 12345})
	s.mu.Lock()
	oldSession := s.players["a"]
	s.mu.Unlock()
	_, _ = enter(t, addr, "a")
	want(t, observer, protocol.Leave{PlayerID: "a", Reason: protocol.LeaveReplaced})
	want(t, observer, protocol.Join{PlayerID: "a", TrainerID: 12345})
	old.closed(t)
	// Model a frame already decoded by the old reader just before replacement.
	s.presence(oldSession, protocol.Presence{PlayerID: "a", PresenceState: protocol.PresenceState{X: 99, Facing: 1}})
	observer.send(t, protocol.Ping{T: 1})
	want(t, observer, protocol.Pong{T: 1})
	_, welcome := enter(t, addr, "c")
	if welcome.Players[0].PlayerID != "a" || welcome.Players[0].Presence != nil {
		t.Fatalf("stale reader overwrote replacement state: %#v", welcome)
	}
}
