// Package room implements the connection lifecycle for one global room.
package room

import (
	"context"
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
	hello := protocol.Hello{PlayerID: "config", JoinKey: c.JoinKey, ClientVersion: "config"}
	if hello.Validate() != nil {
		return errors.New("join-key is required and must contain 1-64 characters without control characters")
	}
	return nil
}

type client struct {
	conn    net.Conn
	player  protocol.Player
	writeMu sync.Mutex
}

// Server accepts authenticated players. Construct one Server per listener.
type Server struct {
	cfg          Config
	logger       *log.Logger
	helloTimeout time.Duration
	writeTimeout time.Duration

	// The mutex serializes membership changes and their notifications, so an
	// observer always sees leave(replaced) before join for a replacement.
	// Writes currently run under this lock with a bounded deadline. Per-client
	// queues and slow-reader isolation belong to issue #14.
	mu      sync.Mutex
	players map[string]*client
}

func New(cfg Config, logger *log.Logger) (*Server, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}
	return &Server{cfg: cfg, logger: logger, helloTimeout: 5 * time.Second,
		writeTimeout: 5 * time.Second, players: make(map[string]*client)}, nil
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
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		activeMu.Lock()
		if ctx.Err() != nil {
			activeMu.Unlock()
			conn.Close()
			return nil
		}
		active[conn] = struct{}{}
		activeMu.Unlock()
		handlers.Add(1)
		go func() {
			defer handlers.Done()
			defer func() {
				activeMu.Lock()
				delete(active, conn)
				activeMu.Unlock()
			}()
			s.handle(conn)
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
	_ = s.send(c, protocol.Error{Code: code, Message: code})
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

func (s *Server) handle(conn net.Conn) {
	c := &client{conn: conn}
	defer conn.Close()
	defer s.leave(c)
	s.event(c, "connect", "")
	if conn.SetReadDeadline(time.Now().Add(s.helloTimeout)) != nil {
		return
	}
	decoder := protocol.NewDecoder(conn)
	for {
		msg, err := decoder.Decode()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				s.reject(c, decodeCode(err, true))
			}
			return
		}
		if _, unknown := msg.(protocol.Unknown); unknown {
			s.event(c, "unknown", "")
			continue // The original hello deadline still applies.
		}
		hello, ok := msg.(protocol.Hello)
		if !ok {
			s.reject(c, protocol.CodeBadHello)
			return
		}
		c.player = protocol.Player{PlayerID: hello.PlayerID, TrainerID: hello.TrainerID, Gender: hello.Gender}
		s.event(c, "hello", "")
		if hello.JoinKey != s.cfg.JoinKey {
			s.reject(c, protocol.CodeBadKey)
			return
		}
		if conn.SetReadDeadline(time.Time{}) != nil || !s.join(c) {
			return
		}
		break
	}
	for {
		msg, err := decoder.Decode()
		if err != nil {
			if errors.Is(err, protocol.ErrVersionMismatch) || errors.Is(err, protocol.ErrMalformed) ||
				errors.Is(err, protocol.ErrInvalid) || errors.Is(err, protocol.ErrLineTooLong) ||
				errors.Is(err, io.ErrUnexpectedEOF) {
				s.reject(c, decodeCode(err, false))
			}
			return
		}
		switch msg.(type) {
		case protocol.Unknown:
			s.event(c, "unknown", "")
		case protocol.Presence, protocol.Ping:
			// Validated but not processed until #14 implements presence/liveness.
		default:
			s.reject(c, protocol.CodeBadMessage)
			return
		}
	}
}

func (s *Server) broadcast(msg protocol.Message, except *client) {
	// Caller holds s.mu. A failed peer is closed; its handler removes it.
	for _, peer := range s.players {
		if peer != except && s.send(peer, msg) != nil {
			peer.conn.Close()
		}
	}
}

func (s *Server) join(c *client) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	old := s.players[c.player.PlayerID]
	if old == nil && len(s.players) >= s.cfg.MaxPlayers {
		s.reject(c, protocol.CodeRoomFull)
		return false
	}
	if old != nil {
		delete(s.players, old.player.PlayerID)
		old.conn.Close()
		s.event(old, "leave", protocol.LeaveReplaced)
		s.broadcast(protocol.Leave{PlayerID: old.player.PlayerID, Reason: protocol.LeaveReplaced}, nil)
	}
	players := make([]protocol.Player, 0, len(s.players))
	for _, peer := range s.players {
		players = append(players, peer.player)
	}
	sort.Slice(players, func(i, j int) bool { return players[i].PlayerID < players[j].PlayerID })
	if s.send(c, protocol.Welcome{Players: players}) != nil {
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
	// An old handler must never remove the replacement with the same ID.
	if s.players[c.player.PlayerID] != c {
		return
	}
	delete(s.players, c.player.PlayerID)
	s.event(c, "leave", protocol.LeaveDisconnect)
	s.broadcast(protocol.Leave{PlayerID: c.player.PlayerID, Reason: protocol.LeaveDisconnect}, nil)
}
