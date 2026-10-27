package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"
)

const (
	handshakeTimeout = 5 * time.Second
	writeTimeout     = 5 * time.Second
	pingInterval     = 5 * time.Second
	warpInterval     = 3 * time.Second
)

type received struct {
	message protocol.Message
	err     error
}

func run(ctx context.Context, args []string, getenv func(string) string, output io.Writer) (runErr error) {
	cfg, err := parseConfig(args, getenv)
	if errors.Is(err, flag.ErrHelp) {
		_, err = fmt.Fprintln(output, "Usage: fakeclient -id PLAYER [-addr ADDRESS] [-key KEY] [-pattern square|idle|warp] [-steps-per-sec RATE] [-trade PLAYER]\nKey fallback: FAKECLIENT_JOIN_KEY. Defaults: addr=localhost:8765, pattern=square, steps-per-sec=4.\nRATE must be greater than 0 and at most 40. Ctrl+C disconnects; there is no automatic reconnect.")
		return err
	}
	if err != nil {
		return err
	}
	defer func() {
		if ctx.Err() != nil {
			runErr = nil
		} else if runErr != nil {
			text := redact(runErr.Error(), cfg.hello.JoinKey)
			if text != runErr.Error() {
				runErr = errors.New(text)
			}
		}
	}()
	dialer := net.Dialer{Timeout: handshakeTimeout}
	conn, err := dialer.DialContext(ctx, "tcp", cfg.addr)
	if err != nil {
		return fmt.Errorf("connect to server: %w", err)
	}
	defer conn.Close()
	// Cancellation also interrupts a blocked socket read or write.
	stopClose := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stopClose()
	if err := send(conn, cfg.hello); err != nil {
		return err
	}

	readCtx, cancelRead := context.WithCancel(ctx)
	results := make(chan received, 1)
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		decoder := protocol.NewDecoder(conn)
		for {
			message, err := decoder.Decode()
			select {
			case results <- received{message, err}:
			case <-readCtx.Done():
				return
			}
			if err != nil {
				return
			}
		}
	}()
	defer func() {
		cancelRead()
		_ = conn.Close()
		<-readerDone
	}()
	if err := awaitWelcome(ctx, results, output, cfg.hello.JoinKey); err != nil {
		return err
	}
	if ctx.Err() != nil {
		return nil
	}

	walker := newWalker(cfg.pattern)
	last := walker.state()
	publish := func(state protocol.PresenceState) error {
		return send(conn, protocol.Presence{PlayerID: cfg.hello.PlayerID, PresenceState: state})
	}
	if err := publish(last); err != nil {
		return err
	}
	if cfg.tradeTarget != "" {
		samples := tradeSamples(cfg.hello.PlayerID, cfg.tradeTarget)
		for _, message := range samples {
			if err := send(conn, message); err != nil {
				return err
			}
		}
		if _, err := fmt.Fprintf(output, "[trade] sent %d sample trade messages to %s\n", len(samples), cfg.tradeTarget); err != nil {
			return err
		}
	}
	steps := time.NewTicker(time.Duration(float64(time.Second) / cfg.stepsPerSec))
	defer steps.Stop()
	pings := time.NewTicker(pingInterval)
	defer pings.Stop()
	var warps <-chan time.Time
	if cfg.pattern == "warp" {
		ticker := time.NewTicker(warpInterval)
		defer ticker.Stop()
		warps = ticker.C
	}
	for {
		var next protocol.PresenceState
		select {
		case <-ctx.Done():
			return nil
		case result := <-results:
			if result.err != nil {
				return receiveError(result.err)
			}
			if err := logMessage(output, result.message, cfg.hello.JoinKey); err != nil {
				return err
			}
			switch message := result.message.(type) {
			case protocol.Join, protocol.Presence, protocol.Leave, protocol.Pong, protocol.Unknown, protocol.Relayed:
			case protocol.Ping:
				if err := send(conn, protocol.Pong{T: message.T}); err != nil {
					return err
				}
			case protocol.Error:
				return fmt.Errorf("server rejected connection (%s)", message.Code)
			default:
				return errors.New("unexpected server message after welcome")
			}
			continue
		case <-pings.C:
			if err := send(conn, protocol.Ping{T: time.Now().UnixMilli()}); err != nil {
				return err
			}
			continue
		case <-steps.C:
			next = walker.step()
		case <-warps:
			next = walker.warp()
		}
		// Idle clients announce their initial state, then only send heartbeats.
		if next != last {
			if err := publish(next); err != nil {
				return err
			}
			last = next
		}
	}
}

func awaitWelcome(ctx context.Context, results <-chan received, output io.Writer, key string) error {
	timer := time.NewTimer(handshakeTimeout)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-timer.C:
			return errors.New("timed out waiting for welcome")
		case result := <-results:
			if result.err != nil {
				return receiveError(result.err)
			}
			if err := logMessage(output, result.message, key); err != nil {
				return err
			}
			switch message := result.message.(type) {
			case protocol.Welcome:
				return nil
			case protocol.Unknown:
				// Unknown extensions do not reset the handshake deadline.
			case protocol.Error:
				return fmt.Errorf("server rejected connection (%s)", message.Code)
			default:
				return errors.New("expected welcome from server")
			}
		}
	}
}

func send(conn net.Conn, message protocol.Message) error {
	line, err := protocol.Encode(message)
	if err != nil {
		return errors.New("cannot encode outgoing message")
	}
	if err := conn.SetWriteDeadline(time.Now().Add(writeTimeout)); err != nil {
		return fmt.Errorf("set write deadline: %w", err)
	}
	n, err := conn.Write(line)
	if err != nil {
		return fmt.Errorf("send message: %w", err)
	}
	if n != len(line) {
		return io.ErrShortWrite
	}
	return nil
}

func receiveError(err error) error {
	switch {
	case errors.Is(err, io.EOF):
		return errors.New("server disconnected")
	case errors.Is(err, protocol.ErrVersionMismatch):
		return errors.New("server uses a different protocol version")
	case errors.Is(err, protocol.ErrLineTooLong):
		return errors.New("server message exceeds the line limit")
	default:
		// Decoder errors may contain remote text. Do not expose raw payloads.
		return errors.New("invalid server message or connection read failure")
	}
}

func redact(text, key string) string {
	if key == "" {
		return text
	}
	return strings.ReplaceAll(text, key, "[REDACTED]")
}

func logMessage(output io.Writer, message protocol.Message, key string) error {
	var text strings.Builder
	writePresence := func(id string, state protocol.PresenceState) {
		fmt.Fprintf(&text, "[presence] %s %d:%d %d,%d %s visible=%t\n", id, state.MapGroup, state.MapNum, state.X, state.Y, facingName(state.Facing), state.Visible)
	}
	switch message := message.(type) {
	case protocol.Welcome:
		fmt.Fprintf(&text, "[welcome] players=%d\n", len(message.Players))
		for _, player := range message.Players {
			fmt.Fprintf(&text, "[join] %s trainerId=%d gender=%d\n", player.PlayerID, player.TrainerID, player.Gender)
			if player.Presence != nil {
				writePresence(player.PlayerID, *player.Presence)
			}
		}
	case protocol.Join:
		fmt.Fprintf(&text, "[join] %s trainerId=%d gender=%d\n", message.PlayerID, message.TrainerID, message.Gender)
	case protocol.Presence:
		writePresence(message.PlayerID, message.PresenceState)
	case protocol.Leave:
		fmt.Fprintf(&text, "[leave] %s reason=%s\n", message.PlayerID, message.Reason)
	case protocol.Ping:
		fmt.Fprintf(&text, "[ping] t=%d\n", message.T)
	case protocol.Pong:
		fmt.Fprintf(&text, "[pong] t=%d\n", message.T)
	case protocol.Error:
		fmt.Fprintf(&text, "[error] %s %q\n", message.Code, redact(message.Message, key))
	case protocol.Unknown:
		fmt.Fprintf(&text, "[unknown] %q\n", redact(message.TypeName, key))
	// Trade payloads are logged by size only, like other raw payloads.
	case protocol.TradeAvailable:
		fmt.Fprintf(&text, "[trade_available] %s available=%t\n", message.PlayerID, message.Available)
	case protocol.TradeInvite:
		fmt.Fprintf(&text, "[trade_invite] %s -> %s\n", message.PlayerID, message.TargetID)
	case protocol.TradeAccept:
		fmt.Fprintf(&text, "[trade_accept] %s -> %s\n", message.PlayerID, message.TargetID)
	case protocol.TradeDecline:
		fmt.Fprintf(&text, "[trade_decline] %s -> %s reason=%s\n", message.PlayerID, message.TargetID, message.Reason)
	case protocol.TradeCancel:
		fmt.Fprintf(&text, "[trade_cancel] %s -> %s reason=%s\n", message.PlayerID, message.TargetID, message.Reason)
	case protocol.TradeLink:
		fmt.Fprintf(&text, "[trade_link] %s -> %s seq=%d bytes=%d\n", message.PlayerID, message.TargetID, message.Seq, len(message.Data)/2)
	case protocol.TradeConfirm:
		fmt.Fprintf(&text, "[trade_confirm] %s -> %s bytes=%d\n", message.PlayerID, message.TargetID, len(message.Pokemon)/2)
	default:
		fmt.Fprintf(&text, "[unexpected] %q\n", message.Type())
	}
	_, err := io.WriteString(output, redact(text.String(), key))
	return err
}

// tradeSamples returns one of each trade message, from id to target, so a
// developer can watch the relay without an emulator. The payloads are
// synthetic test bytes, not game data.
func tradeSamples(id, target string) []protocol.Message {
	return []protocol.Message{
		protocol.TradeAvailable{PlayerID: id, Available: true},
		protocol.TradeInvite{PlayerID: id, TargetID: target},
		protocol.TradeAccept{PlayerID: id, TargetID: target},
		protocol.TradeDecline{PlayerID: id, TargetID: target, Reason: protocol.DeclineDeclined},
		protocol.TradeCancel{PlayerID: id, TargetID: target, Reason: protocol.CancelCanceled},
		protocol.TradeLink{PlayerID: id, TargetID: target, Seq: 0, Data: "00010203"},
		protocol.TradeConfirm{PlayerID: id, TargetID: target, Pokemon: strings.Repeat("00", protocol.PokemonBytes)},
		protocol.TradeAvailable{PlayerID: id, Available: false},
	}
}

func facingName(facing int) string {
	switch facing {
	case protocol.FacingSouth:
		return "SOUTH"
	case protocol.FacingNorth:
		return "NORTH"
	case protocol.FacingWest:
		return "WEST"
	case protocol.FacingEast:
		return "EAST"
	default:
		return "UNKNOWN"
	}
}
