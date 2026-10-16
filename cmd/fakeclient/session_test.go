package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"
)

type synchronizedOutput struct {
	mu      sync.Mutex
	data    bytes.Buffer
	failure error
}

func (output *synchronizedOutput) Write(data []byte) (int, error) {
	output.mu.Lock()
	defer output.mu.Unlock()
	if output.failure != nil {
		return 0, output.failure
	}
	return output.data.Write(data)
}

func (output *synchronizedOutput) String() string {
	output.mu.Lock()
	defer output.mu.Unlock()
	return output.data.String()
}

// scriptedPeer tests the client against only the shared wire contract. It
// does not require a production relay or the separate presence-relay issue.
type scriptedPeer struct {
	conn    net.Conn
	decoder *protocol.Decoder
	output  *synchronizedOutput
	cancel  context.CancelFunc
	result  <-chan error
	stopped bool
}

func startScriptedPeer(t *testing.T, extraArgs ...string) *scriptedPeer {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	if err := listener.(*net.TCPListener).SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	output := &synchronizedOutput{}
	result := make(chan error, 1)
	args := append([]string{"-addr", listener.Addr().String(), "-id", "bot1", "-key", fixtureJoinKey}, extraArgs...)
	go func() { result <- run(ctx, args, noEnvironment, output) }()
	peer := &scriptedPeer{output: output, cancel: cancel, result: result}
	t.Cleanup(func() {
		cancel()
		if peer.conn != nil {
			peer.conn.Close()
		}
		if !peer.stopped {
			select {
			case <-result:
			case <-time.After(2 * time.Second):
				t.Error("client did not stop within two seconds of cleanup")
			}
		}
	})
	peer.conn, err = listener.Accept()
	if err != nil {
		t.Fatalf("accept fakeclient: %v", err)
	}
	peer.decoder = protocol.NewDecoder(peer.conn)
	return peer
}

func (peer *scriptedPeer) read(t *testing.T, timeout time.Duration) protocol.Message {
	t.Helper()
	if err := peer.conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		t.Fatal(err)
	}
	message, err := peer.decoder.Decode()
	if err != nil {
		t.Fatalf("read client message: %v", err)
	}
	return message
}

func (peer *scriptedPeer) send(t *testing.T, message protocol.Message) {
	t.Helper()
	line, err := protocol.Encode(message)
	if err != nil {
		t.Fatal(err)
	}
	peer.sendRaw(t, string(line))
}

func (peer *scriptedPeer) sendRaw(t *testing.T, line string) {
	t.Helper()
	if err := peer.conn.SetWriteDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(peer.conn, line); err != nil {
		t.Fatalf("write server message: %v", err)
	}
}

func (peer *scriptedPeer) wait(t *testing.T, timeout time.Duration) error {
	t.Helper()
	select {
	case err := <-peer.result:
		peer.stopped = true
		return err
	case <-time.After(timeout):
		t.Fatal("client did not return within the bounded wait")
		return nil
	}
}

func (peer *scriptedPeer) assertNoKeyDisclosure(t *testing.T, err error) {
	t.Helper()
	if strings.Contains(peer.output.String(), fixtureJoinKey) || (err != nil && strings.Contains(err.Error(), fixtureJoinKey)) {
		t.Fatal("client output or returned error disclosed the fixture join key")
	}
}

func expectHello(t *testing.T, peer *scriptedPeer) {
	t.Helper()
	message := peer.read(t, 2*time.Second)
	hello, ok := message.(protocol.Hello)
	if !ok {
		t.Fatalf("first message is %T, want hello", message)
	}
	if hello.PlayerID != "bot1" || hello.JoinKey != fixtureJoinKey || hello.TrainerID != 0 || hello.Gender != protocol.GenderMale || hello.ClientVersion != "fakeclient" {
		t.Fatal("hello does not contain the configured ID/key and synthetic identity")
	}
}

func expectInitialPresence(t *testing.T, peer *scriptedPeer) {
	t.Helper()
	message := peer.read(t, 2*time.Second)
	want := protocol.Presence{PlayerID: "bot1", PresenceState: protocol.PresenceState{
		MapGroup: 0, MapNum: 9, X: 5, Y: 3, Facing: protocol.FacingEast, Visible: true,
	}}
	if got, ok := message.(protocol.Presence); !ok || got != want {
		t.Fatalf("first message after welcome: got %#v, want %#v", message, want)
	}
}

func TestSessionWaitsForWelcomeThenWalksAndCancels(t *testing.T) {
	peer := startScriptedPeer(t, "-steps-per-sec", "40")
	expectHello(t, peer)
	peer.sendRaw(t, "{\"v\":1,\"type\":\"future-handshake\",\"ignored\":true}\n")
	if err := peer.conn.SetReadDeadline(time.Now().Add(150 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	message, err := peer.decoder.Decode()
	var timeout net.Error
	if !errors.As(err, &timeout) || !timeout.Timeout() {
		t.Fatalf("client sent data before welcome or stopped: message %T, error %v", message, err)
	}
	peer.send(t, protocol.Welcome{})
	expectInitialPresence(t, peer)
	message = peer.read(t, 2*time.Second)
	presence, ok := message.(protocol.Presence)
	if !ok || presence.PlayerID != "bot1" || presence.X != 6 || presence.Y != 3 || presence.Facing != protocol.FacingEast {
		t.Fatalf("first walking update: %#v", message)
	}
	peer.cancel()
	if err := peer.wait(t, 2*time.Second); err != nil {
		t.Fatalf("context cancellation should be clean: %v", err)
	}
	peer.assertNoKeyDisclosure(t, nil)
	if !strings.Contains(peer.output.String(), "[welcome] players=0") {
		t.Fatalf("welcome was not logged: %s", peer.output.String())
	}
	// Pending writes may already be buffered; all must end with a closed socket.
	if err := peer.conn.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	for {
		_, err := peer.decoder.Decode()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("client did not close its connection on cancellation: %v", err)
		}
	}
}

func TestSessionLogsIncomingMessagesAndEchoesPing(t *testing.T) {
	peer := startScriptedPeer(t, "-pattern", "idle")
	expectHello(t, peer)
	snapshot := protocol.PresenceState{MapGroup: 0, MapNum: 9, X: 7, Y: 5, Facing: protocol.FacingSouth, Visible: true}
	peer.send(t, protocol.Welcome{Players: []protocol.Player{
		{PlayerID: "existing", TrainerID: 23, Gender: protocol.GenderFemale, Presence: &snapshot},
		{PlayerID: "waiting", TrainerID: 24, Gender: protocol.GenderMale},
	}})
	expectInitialPresence(t, peer)
	peer.send(t, protocol.Join{PlayerID: "remote", TrainerID: 42, Gender: protocol.GenderMale})
	peer.send(t, protocol.Presence{PlayerID: "remote", PresenceState: snapshot})
	peer.send(t, protocol.Leave{PlayerID: "remote", Reason: protocol.LeaveDisconnect})
	peer.send(t, protocol.Pong{T: 4321})
	peer.sendRaw(t, "{\"v\":1,\"type\":\"future\\nmessage\",\"privatePayload\":\"fixture-unknown-body\"}\n")
	peer.send(t, protocol.Ping{T: 123456789})
	message := peer.read(t, 2*time.Second)
	if got, ok := message.(protocol.Pong); !ok || got.T != 123456789 {
		t.Fatalf("server ping must be echoed exactly, got %#v", message)
	}
	peer.cancel()
	if err := peer.wait(t, 2*time.Second); err != nil {
		t.Fatalf("unknown type should be ignored, not fatal: %v", err)
	}
	output := peer.output.String()
	for _, line := range []string{
		"[welcome] players=2", "[join] existing trainerId=23 gender=1", "[join] waiting trainerId=24 gender=0",
		"[presence] existing 0:9 7,5 SOUTH visible=true", "[join] remote trainerId=42 gender=0",
		"[presence] remote 0:9 7,5 SOUTH visible=true", "[leave] remote reason=disconnect",
		"[pong] t=4321", "[ping] t=123456789", `[unknown] "future\nmessage"`,
	} {
		if !strings.Contains(output, line) {
			t.Errorf("missing readable log %q in:\n%s", line, output)
		}
	}
	if strings.Contains(output, "fixture-unknown-body") || strings.Contains(output, "privatePayload") {
		t.Fatal("unknown message logged its raw JSON payload")
	}
	peer.assertNoKeyDisclosure(t, nil)
}

func TestSessionFailurePaths(t *testing.T) {
	for _, failure := range []string{"rejected hello", "unexpected handshake", "malformed before welcome", "malformed after welcome", "disconnect", "server error"} {
		t.Run(failure, func(t *testing.T) {
			peer := startScriptedPeer(t, "-pattern", "idle")
			expectHello(t, peer)
			switch failure {
			case "rejected hello":
				peer.send(t, protocol.Error{Code: protocol.CodeBadKey, Message: "rejected " + fixtureJoinKey})
			case "unexpected handshake":
				peer.send(t, protocol.Join{PlayerID: "other", TrainerID: 1, Gender: protocol.GenderMale})
			case "malformed before welcome":
				peer.sendRaw(t, "not JSON\n")
			default:
				peer.send(t, protocol.Welcome{})
				expectInitialPresence(t, peer)
				switch failure {
				case "malformed after welcome":
					peer.sendRaw(t, "{\"v\":1,\"type\":\"presence\"}\n")
				case "disconnect":
					peer.conn.Close()
				case "server error":
					peer.send(t, protocol.Error{Code: protocol.CodeBadMessage, Message: "fixture rejection"})
				}
			}
			err := peer.wait(t, 2*time.Second)
			if err == nil {
				t.Fatal("expected protocol, rejection, or disconnect error")
			}
			peer.assertNoKeyDisclosure(t, err)
			if failure == "server error" && !strings.Contains(peer.output.String(), `[error] bad_message "fixture rejection"`) {
				t.Fatalf("server error was not readable: %s", peer.output.String())
			}
		})
	}
}

func TestSessionCancellationDuringHandshake(t *testing.T) {
	peer := startScriptedPeer(t)
	expectHello(t, peer)
	peer.cancel()
	if err := peer.wait(t, 2*time.Second); err != nil {
		t.Fatalf("cancel while waiting for welcome: %v", err)
	}
}

func TestSessionOutputFailureStopsClient(t *testing.T) {
	peer := startScriptedPeer(t)
	expectHello(t, peer)
	want := errors.New("synthetic output failure")
	peer.output.mu.Lock()
	peer.output.failure = want
	peer.output.mu.Unlock()
	peer.send(t, protocol.Welcome{})
	if err := peer.wait(t, 2*time.Second); !errors.Is(err, want) {
		t.Fatalf("output failure was not propagated: %v", err)
	}
}

func TestSessionHandshakeTimeout(t *testing.T) {
	t.Parallel()
	peer := startScriptedPeer(t)
	expectHello(t, peer)
	started := time.Now()
	err := peer.wait(t, 6*time.Second)
	if err == nil || !strings.Contains(err.Error(), "welcome") {
		t.Fatal("server that never sends welcome must time out")
	}
	if elapsed := time.Since(started); elapsed < 4*time.Second {
		t.Fatalf("handshake failed before its timeout: %s", elapsed)
	}
}

func TestSessionWarpAndPeriodicPing(t *testing.T) {
	t.Parallel()
	peer := startScriptedPeer(t, "-pattern", "warp", "-steps-per-sec", "4")
	expectHello(t, peer)
	peer.send(t, protocol.Welcome{})
	expectInitialPresence(t, peer)
	deadline := time.Now().Add(7 * time.Second)
	var sawWarp bool
	var sawPing bool
	for !sawWarp || !sawPing {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			t.Fatalf("missing periodic activity: warp=%t ping=%t", sawWarp, sawPing)
		}
		message := peer.read(t, remaining)
		switch message := message.(type) {
		case protocol.Presence:
			if message.PlayerID != "bot1" || !message.Visible {
				t.Fatalf("invalid local presence: %#v", message)
			}
			if message.MapGroup == 1 && message.MapNum == 0 {
				sawWarp = true
			}
		case protocol.Ping:
			if message.T <= 0 {
				t.Fatalf("periodic ping needs a millisecond timestamp, got %d", message.T)
			}
			sawPing = true
			peer.send(t, protocol.Pong{T: message.T})
		default:
			t.Fatalf("unexpected client message %T", message)
		}
	}
	peer.cancel()
	if err := peer.wait(t, 2*time.Second); err != nil {
		t.Fatalf("cancel after periodic activity: %v", err)
	}
}
