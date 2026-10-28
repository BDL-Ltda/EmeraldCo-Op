package room

import (
	"time"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"
	"github.com/DaviAlencastro/EmeraldCo-Op/internal/tradelog"
)

type tradePair [2]string

type pendingConfirm struct {
	sender  *client
	pokemon string
}

func pairFor(a, b string) tradePair {
	if b < a {
		a, b = b, a
	}
	return tradePair{a, b}
}

func (s *Server) clearConfirmsLocked(id string) {
	for pair := range s.confirms {
		if pair[0] == id || pair[1] == id {
			delete(s.confirms, pair)
		}
	}
}

// Only connected, distinct authenticated senders can form an audit pair.
// This bounds pending entries to at most 10 pairs in a five-player room.
// Relay behavior remains unchanged, even for nonexistent or self targets.
func (s *Server) confirmLocked(c *client, msg protocol.Message) *tradelog.Record {
	if s.cfg.TradeLog == nil || s.players[c.player.PlayerID] != c {
		return nil
	}
	switch message := msg.(type) {
	case protocol.TradeInvite:
		delete(s.confirms, pairFor(c.player.PlayerID, message.TargetID))
	case protocol.TradeDecline:
		delete(s.confirms, pairFor(c.player.PlayerID, message.TargetID))
	case protocol.TradeCancel:
		delete(s.confirms, pairFor(c.player.PlayerID, message.TargetID))
	case protocol.TradeConfirm:
		partner := s.players[message.TargetID]
		if partner == nil || partner == c {
			return nil
		}
		pair := pairFor(c.player.PlayerID, message.TargetID)
		first, exists := s.confirms[pair]
		if !exists || first.sender != partner {
			// Repeated confirms from the same side replace, never complete, it.
			s.confirms[pair] = pendingConfirm{sender: c, pokemon: message.Pokemon}
			return nil
		}
		delete(s.confirms, pair)
		players := [2]tradelog.Player{
			tradelog.NewPlayer(partner.player.PlayerID, partner.player.TrainerID, first.pokemon),
			tradelog.NewPlayer(c.player.PlayerID, c.player.TrainerID, message.Pokemon),
		}
		if players[1].PlayerID < players[0].PlayerID {
			players[0], players[1] = players[1], players[0]
		}
		return &tradelog.Record{Time: time.Now().UTC(), Players: players}
	}
	return nil
}
