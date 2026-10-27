// Package room implements the single-room presence relay and connection lifecycle.
package room

import (
	"context"
	"crypto/subtle"
	"errors"
	"io"
	"log"
	"net"
	"sort"
	"sync"
	"time"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"
)

// Config contains listener-independent settings. Never log JoinKey.
type Config struct {
	JoinKey    string
	MaxPlayers int
}

func (c Config) Validate() error {
	if c.MaxPlayers < 1 || c.MaxPlayers > protocol.MaxRemotePlayers+1 {
		return errors.New("max-players must be from 1 to 5")
	}
	if protocol.ValidateJoinKey(c.JoinKey) != nil {
		return errors.New("join-key is required and must contain 1-64 characters without control characters")
	}
	return nil
}

type client struct {
	conn          net.Conn
	player        protocol.Player
	writeMu       sync.Mutex
	unknownLogged bool // Owned by this connection's reader, across both phases.
	outbox        chan []byte
	stop          chan struct{}
	stopOnce      sync.Once
	writerDone    chan struct{}
	messageTimes  []time.Time // Reader-owned rolling one-second rate window.
	nextMessage   int
}

func (c *client) stopWriter() { c.stopOnce.Do(func() { close(c.stop) }) }

func (c *client) close() {
	c.stopWriter()
	c.conn.Close()
}

// Server accepts authenticated players. Construct one Server per listener.
type Server struct {
	cfg           Config
	logger        *log.Logger
	helloTimeout  time.Duration
	writeTimeout  time.Duration
	idleTimeout   time.Duration
	rateLimit     int
	sendQueueSize int
	// pending is a semaphore of unauthenticated connections; its capacity is
	// the cap. A slot is held from accept until the join key matches or the
	// handshake ends any other way.
	pending chan struct{}

	// The mutex serializes membership changes and their notifications, so an
	// observer always sees leave(replaced) before join for a replacement.
	// Only non-blocking queue operations run under the lock. Each authenticated
	// connection has its own writer, so socket backpressure never locks the room.
	mu      sync.Mutex
	players map[string]*client
}

// maxPendingHandshakes bounds connections that have not yet sent a hello with
// the correct join key. It is about three times the room capacity, so a whole
// room can reconnect at once while an idle-connection flood holds at most this
// many descriptors, each for at most the hello timeout.
const maxPendingHandshakes = 16

func New(cfg Config, logger *log.Logger) (*Server, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}
	return &Server{cfg: cfg, logger: logger, helloTimeout: 5 * time.Second,
		writeTimeout: 5 * time.Second, idleTimeout: 15 * time.Second,
		rateLimit: 50, sendQueueSize: 64, pending: make(chan struct{}, maxPendingHandshakes),
		players: make(map[string]*client)}, nil
}

// Serve owns listener and all accepted connections. Cancellation closes even
// unauthenticated connections and waits for their handlers before returning.
func (s *Server) Serve(ctx context.Context, listener net.Listener) error {
	var activeMu sync.Mutex
	active := make(map[net.Conn]struct{})
	var handlers sync.WaitGroup
	closeAll := func() {
		listener.Close()
		activeMu.Lock()
		defer activeMu.Unlock()
		for conn := range active {
			conn.Close()
		}
	}
	stop := context.AfterFunc(ctx, closeAll)
	defer func() {
		stop()
		closeAll()
		handlers.Wait()
	}()
	var retryDelay time.Duration
	pendingFullLogged := false
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			// Like net/http, retry temporary accept failures (including descriptor
			// exhaustion) without disconnecting established players. Permanent
			// failures still stop Serve; cancellation interrupts the backoff.
			var temporary interface{ Temporary() bool }
			if errors.As(err, &temporary) && temporary.Temporary() {
				if retryDelay == 0 {
					retryDelay = 5 * time.Millisecond
				} else {
					retryDelay = min(retryDelay*2, time.Second)
				}
				s.logger.Printf("event=accept_retry delay=%s", retryDelay)
				timer := time.NewTimer(retryDelay)
				select {
				case <-ctx.Done():
					timer.Stop()
					return nil
				case <-timer.C:
				}
				continue
			}
			return err
		}
		retryDelay = 0
		select {
		case s.pending <- struct{}{}:
			pendingFullLogged = false
		default:
			// Over the cap: close at once, without reading or replying, so a
			// flood costs no handler and no descriptor beyond this moment.
			// Log once per overload episode to keep the flood out of the log.
			if !pendingFullLogged {
				s.logger.Printf("event=pending_full remote=%q", conn.RemoteAddr())
				pendingFullLogged = true
			}
			conn.Close()
			continue
		}
		var releaseOnce sync.Once
		release := func() { releaseOnce.Do(func() { <-s.pending }) }
		activeMu.Lock()
		if ctx.Err() != nil {
			activeMu.Unlock()
			conn.Close()
			release()
			return nil
		}
		active[conn] = struct{}{}
		activeMu.Unlock()
		handlers.Add(1)
		go func() {
			defer handlers.Done()
			defer release()
			defer func() {
				activeMu.Lock()
				delete(active, conn)
				activeMu.Unlock()
			}()
			s.handle(conn, release)
		}()
	}
}

func (s *Server) event(c *client, event, reason string) {
	// Decoder errors and raw input can contain the join key; never include them.
	s.logger.Printf("event=%s remote=%q playerId=%q reason=%q", event, c.conn.RemoteAddr(), c.player.PlayerID, reason)
}

func (s *Server) send(c *client, msg protocol.Message) error {
	line, err := protocol.Encode(msg)
	if err != nil {
		return err
	}
	return s.write(c, line)
}

func (s *Server) write(c *client, line []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if err := c.conn.SetWriteDeadline(time.Now().Add(s.writeTimeout)); err != nil {
		return err
	}
	n, err := c.conn.Write(line)
	if err == nil && n != len(line) {
		return io.ErrShortWrite
	}
	return err
}

func (s *Server) reject(c *client, code string) {
	s.event(c, "reject", code)
	// Stop queued output before sending the terminal error. Waiting affects
	// only this connection and is bounded by the writer's existing deadline.
	if c.writerDone != nil {
		// Detach before stopping the writer: concurrent broadcasts must not
		// close this socket before its terminal error can be sent.
		s.mu.Lock()
		s.forgetLocked(c, protocol.LeaveDisconnect)
		s.mu.Unlock()
		c.stopWriter()
		<-c.writerDone
	}
	_ = s.send(c, protocol.Error{Code: code, Message: code})
}

func (s *Server) startWriter(c *client) {
	c.writerDone = make(chan struct{})
	go func() {
		defer close(c.writerDone)
		for {
			select {
			case <-c.stop:
				return
			case line := <-c.outbox:
				select {
				case <-c.stop:
					return
				default:
				}
				if err := s.write(c, line); err != nil {
					s.event(c, "write_failed", "disconnect")
					c.close()
					return
				}
			}
		}
	}()
}

// enqueue never waits for a socket or queue space. Frames are immutable, and
// outbox is never closed, so shutdown cannot race a producer into a panic.
func (s *Server) enqueue(c *client, msg protocol.Message) bool {
	line, err := protocol.Encode(msg)
	if err != nil {
		return false
	}
	select {
	case <-c.stop:
		return false
	default:
	}
	select {
	case <-c.stop:
		return false
	case c.outbox <- line:
		return true
	default:
		return false
	}
}

func (s *Server) allowMessage(c *client, now time.Time) bool {
	if len(c.messageTimes) < s.rateLimit {
		c.messageTimes = append(c.messageTimes, now)
		return true
	}
	if now.Sub(c.messageTimes[c.nextMessage]) < time.Second {
		return false
	}
	c.messageTimes[c.nextMessage] = now
	c.nextMessage = (c.nextMessage + 1) % s.rateLimit
	return true
}

func isProtocolError(err error) bool {
	return errors.Is(err, protocol.ErrVersionMismatch) || errors.Is(err, protocol.ErrMalformed) ||
		errors.Is(err, protocol.ErrInvalid) || errors.Is(err, protocol.ErrLineTooLong) ||
		errors.Is(err, io.ErrUnexpectedEOF)
}

func (s *Server) unknown(c *client) {
	if !c.unknownLogged {
		s.event(c, "unknown", "")
		c.unknownLogged = true
	}
}

func decodeCode(err error, handshake bool) string {
	if errors.Is(err, protocol.ErrVersionMismatch) {
		return protocol.CodeVersionMismatch
	}
	var invalid *protocol.ValidationError
	var netErr net.Error
	if handshake && ((errors.As(err, &invalid) && invalid.Type == protocol.TypeHello) ||
		(errors.As(err, &netErr) && netErr.Timeout())) {
		return protocol.CodeBadHello
	}
	return protocol.CodeBadMessage
}

// handle calls authenticated once the join key matches, freeing the pending
// handshake slot; Serve frees it on every other exit.
func (s *Server) handle(conn net.Conn, authenticated func()) {
	c := &client{conn: conn, outbox: make(chan []byte, s.sendQueueSize), stop: make(chan struct{})}
	defer func() {
		c.close()
		if c.writerDone != nil {
			<-c.writerDone
		}
		s.leave(c)
	}()
	s.event(c, "connect", "")
	if conn.SetReadDeadline(time.Now().Add(s.helloTimeout)) != nil {
		return
	}
	decoder := protocol.NewDecoder(conn)
	for {
		msg, err := decoder.Decode()
		if err != nil {
			var netErr net.Error
			if isProtocolError(err) || (errors.As(err, &netErr) && netErr.Timeout()) {
				s.reject(c, decodeCode(err, true))
			}
			return
		}
		if !s.allowMessage(c, time.Now()) {
			s.reject(c, protocol.CodeBadMessage)
			return
		}
		if _, unknown := msg.(protocol.Unknown); unknown {
			s.unknown(c)
			continue // The original hello deadline still applies.
		}
		hello, ok := msg.(protocol.Hello)
		if !ok {
			s.reject(c, protocol.CodeBadHello)
			return
		}
		c.player = protocol.Player{PlayerID: hello.PlayerID, TrainerID: hello.TrainerID, Gender: hello.Gender}
		s.event(c, "hello", "")
		if subtle.ConstantTimeCompare([]byte(hello.JoinKey), []byte(s.cfg.JoinKey)) != 1 {
			s.reject(c, protocol.CodeBadKey)
			return
		}
		authenticated()
		if conn.SetReadDeadline(time.Time{}) != nil {
			return
		}
		s.startWriter(c)
		if !s.join(c) {
			return
		}
		break
	}
	for {
		if conn.SetReadDeadline(time.Now().Add(s.idleTimeout)) != nil {
			return
		}
		msg, err := decoder.Decode()
		if err != nil {
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				s.mu.Lock()
				s.removeLocked(c, protocol.LeaveTimeout)
				s.mu.Unlock()
			} else if isProtocolError(err) {
				s.reject(c, decodeCode(err, false))
			}
			return
		}
		if !s.allowMessage(c, time.Now()) {
			s.reject(c, protocol.CodeBadMessage)
			return
		}
		switch msg := msg.(type) {
		case protocol.Unknown:
			s.unknown(c)
		case protocol.Presence:
			s.presence(c, msg)
		case protocol.Ping:
			s.pong(c, msg)
		case protocol.Relayed:
			s.relay(c, msg)
		default:
			s.reject(c, protocol.CodeBadMessage)
			return
		}
	}
}

func (s *Server) broadcast(msg protocol.Message, except *client) {
	// Caller holds s.mu. Dropping a full queue may notify/drop other peers;
	// recursion is bounded by the room's maximum five members.
	for _, peer := range s.players {
		if peer != except && !s.enqueue(peer, msg) {
			s.event(peer, "drop", "send_queue_full")
			s.removeLocked(peer, protocol.LeaveDisconnect)
		}
	}
}

func (s *Server) join(c *client) bool {
	s.mu.Lock()
	old := s.players[c.player.PlayerID]
	if old == nil && len(s.players) >= s.cfg.MaxPlayers {
		s.mu.Unlock()
		s.reject(c, protocol.CodeRoomFull)
		return false
	}
	defer s.mu.Unlock()
	if old != nil {
		delete(s.players, old.player.PlayerID)
		old.close()
		s.event(old, "leave", protocol.LeaveReplaced)
		s.broadcast(protocol.Leave{PlayerID: old.player.PlayerID, Reason: protocol.LeaveReplaced}, nil)
	}
	players := make([]protocol.Player, 0, len(s.players))
	for _, peer := range s.players {
		players = append(players, peer.player)
	}
	sort.Slice(players, func(i, j int) bool { return players[i].PlayerID < players[j].PlayerID })
	if !s.enqueue(c, protocol.Welcome{Players: players}) {
		return false
	}
	s.players[c.player.PlayerID] = c
	s.event(c, "join", "")
	s.broadcast(protocol.Join{PlayerID: c.player.PlayerID, TrainerID: c.player.TrainerID, Gender: c.player.Gender}, c)
	return true
}

func (s *Server) leave(c *client) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.removeLocked(c, protocol.LeaveDisconnect)
}

func (s *Server) removeLocked(c *client, reason string) {
	if s.players[c.player.PlayerID] != c {
		return
	}
	c.close()
	s.forgetLocked(c, reason)
}

func (s *Server) forgetLocked(c *client, reason string) {
	// An old handler must never remove the replacement with the same ID.
	if s.players[c.player.PlayerID] != c {
		return
	}
	delete(s.players, c.player.PlayerID)
	s.event(c, "leave", reason)
	s.broadcast(protocol.Leave{PlayerID: c.player.PlayerID, Reason: reason}, nil)
}

func (s *Server) presence(c *client, msg protocol.Presence) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.players[c.player.PlayerID] != c {
		return
	}
	state := msg.PresenceState
	c.player.Presence = &state
	msg.PlayerID = c.player.PlayerID
	s.broadcast(msg, c)
}

// relay sends a trade message to every other player, stamped with the
// sender's ID. The server neither routes by targetId nor keeps trade state.
func (s *Server) relay(c *client, msg protocol.Relayed) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.players[c.player.PlayerID] != c {
		return
	}
	s.broadcast(msg.WithPlayerID(c.player.PlayerID), c)
}

func (s *Server) pong(c *client, msg protocol.Ping) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.players[c.player.PlayerID] != c {
		return
	}
	if !s.enqueue(c, protocol.Pong{T: msg.T}) {
		s.event(c, "drop", "send_queue_full")
		s.removeLocked(c, protocol.LeaveDisconnect)
	}
}
