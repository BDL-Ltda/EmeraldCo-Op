package protocol

import (
	"errors"
	"fmt"
	"math"
	"unicode"
	"unicode/utf8"
)

// Field limits enforced by Validate.
const (
	MaxPlayerIDLength      = 16
	MaxJoinKeyLength       = 64
	MaxClientVersionLength = 32
	MaxErrorMessageLength  = 256
	MaxMapIndex            = 255
	MinCoordinate          = math.MinInt16
	MaxCoordinate          = math.MaxInt16
	// MaxTradeLinkBytes bounds one trade_link payload. It is four of the
	// game's 256-byte link blocks (BLOCK_BUFFER_SIZE), and its hex form keeps
	// the line well under MaxLineLength.
	MaxTradeLinkBytes = 1024
	// PokemonBytes is sizeof(struct Pokemon) in the decomp: an 80-byte
	// BoxPokemon plus 20 bytes of party stats.
	PokemonBytes = 100
)

// ErrInvalid is wrapped by every *ValidationError.
var ErrInvalid = errors.New("invalid message")

// ValidationError reports a field that holds a value the protocol does not
// allow.
type ValidationError struct {
	Type   string
	Field  string
	Reason string
}

func (e *ValidationError) Error() string {
	return fmt.Sprintf("invalid %s: %s %s", e.Type, e.Field, e.Reason)
}

func (e *ValidationError) Unwrap() error { return ErrInvalid }

// ValidateJoinKey checks the shared key's wire-format rules without requiring
// unrelated hello fields. Errors identify the field but never include its value.
func ValidateJoinKey(key string) error {
	return validateText(TypeHello, "joinKey", key, 1, MaxJoinKeyLength)
}

func (m Hello) Validate() error {
	if err := validatePlayerID(TypeHello, "playerId", m.PlayerID); err != nil {
		return err
	}
	if err := ValidateJoinKey(m.JoinKey); err != nil {
		return err
	}
	if err := validateGender(TypeHello, "gender", m.Gender); err != nil {
		return err
	}
	return validateText(TypeHello, "clientVersion", m.ClientVersion, 1, MaxClientVersionLength)
}

func (m Welcome) Validate() error {
	if len(m.Players) > MaxRemotePlayers {
		return invalid(TypeWelcome, "players", fmt.Sprintf("has more than %d entries", MaxRemotePlayers))
	}
	seen := make(map[string]bool, len(m.Players))
	for i, player := range m.Players {
		prefix := fmt.Sprintf("players[%d].", i)
		if err := validatePlayerID(TypeWelcome, prefix+"playerId", player.PlayerID); err != nil {
			return err
		}
		if seen[player.PlayerID] {
			return invalid(TypeWelcome, prefix+"playerId", "is listed twice")
		}
		seen[player.PlayerID] = true
		if err := validateGender(TypeWelcome, prefix+"gender", player.Gender); err != nil {
			return err
		}
		if player.Presence != nil {
			if err := player.Presence.validate(TypeWelcome, prefix+"presence."); err != nil {
				return err
			}
		}
	}
	return nil
}

func (m Join) Validate() error {
	if err := validatePlayerID(TypeJoin, "playerId", m.PlayerID); err != nil {
		return err
	}
	return validateGender(TypeJoin, "gender", m.Gender)
}

func (m Presence) Validate() error {
	if err := validatePlayerID(TypePresence, "playerId", m.PlayerID); err != nil {
		return err
	}
	return m.PresenceState.validate(TypePresence, "")
}

func (s PresenceState) validate(typeName, prefix string) error {
	if s.MapGroup < 0 || s.MapGroup > MaxMapIndex {
		return invalid(typeName, prefix+"mapGroup", fmt.Sprintf("must be 0-%d", MaxMapIndex))
	}
	if s.MapNum < 0 || s.MapNum > MaxMapIndex {
		return invalid(typeName, prefix+"mapNum", fmt.Sprintf("must be 0-%d", MaxMapIndex))
	}
	if s.X < MinCoordinate || s.X > MaxCoordinate {
		return invalid(typeName, prefix+"x", fmt.Sprintf("must be %d-%d", MinCoordinate, MaxCoordinate))
	}
	if s.Y < MinCoordinate || s.Y > MaxCoordinate {
		return invalid(typeName, prefix+"y", fmt.Sprintf("must be %d-%d", MinCoordinate, MaxCoordinate))
	}
	if s.Facing < FacingSouth || s.Facing > FacingEast {
		return invalid(typeName, prefix+"facing", fmt.Sprintf("must be %d-%d", FacingSouth, FacingEast))
	}
	return nil
}

func (m Leave) Validate() error {
	if err := validatePlayerID(TypeLeave, "playerId", m.PlayerID); err != nil {
		return err
	}
	switch m.Reason {
	case LeaveDisconnect, LeaveTimeout, LeaveKicked, LeaveReplaced:
		return nil
	}
	return invalid(TypeLeave, "reason", fmt.Sprintf("%q is not a known reason", m.Reason))
}

func (m Ping) Validate() error { return validateTimestamp(TypePing, m.T) }

func (m Pong) Validate() error { return validateTimestamp(TypePong, m.T) }

func (m Error) Validate() error {
	switch m.Code {
	case CodeBadKey, CodeBadMessage, CodeRoomFull, CodeVersionMismatch, CodeBadHello:
	default:
		return invalid(TypeError, "code", fmt.Sprintf("%q is not a known code", m.Code))
	}
	return validateText(TypeError, "message", m.Message, 0, MaxErrorMessageLength)
}

func (m TradeAvailable) Validate() error {
	return validatePlayerID(TypeTradeAvailable, "playerId", m.PlayerID)
}

func (m TradeInvite) Validate() error {
	return validateTradePair(TypeTradeInvite, m.PlayerID, m.TargetID)
}

func (m TradeAccept) Validate() error {
	return validateTradePair(TypeTradeAccept, m.PlayerID, m.TargetID)
}

func (m TradeDecline) Validate() error {
	if err := validateTradePair(TypeTradeDecline, m.PlayerID, m.TargetID); err != nil {
		return err
	}
	switch m.Reason {
	case DeclineDeclined, DeclineTimeout, DeclineBusy:
		return nil
	}
	return invalid(TypeTradeDecline, "reason", fmt.Sprintf("%q is not a known reason", m.Reason))
}

func (m TradeCancel) Validate() error {
	if err := validateTradePair(TypeTradeCancel, m.PlayerID, m.TargetID); err != nil {
		return err
	}
	switch m.Reason {
	case CancelCanceled, CancelTimeout, CancelDisconnected:
		return nil
	}
	return invalid(TypeTradeCancel, "reason", fmt.Sprintf("%q is not a known reason", m.Reason))
}

func (m TradeLink) Validate() error {
	if err := validateTradePair(TypeTradeLink, m.PlayerID, m.TargetID); err != nil {
		return err
	}
	return validateHex(TypeTradeLink, "data", m.Data, 0, MaxTradeLinkBytes)
}

func (m TradeConfirm) Validate() error {
	if err := validateTradePair(TypeTradeConfirm, m.PlayerID, m.TargetID); err != nil {
		return err
	}
	return validateHex(TypeTradeConfirm, "pokemon", m.Pokemon, PokemonBytes, PokemonBytes)
}

func validateTradePair(typeName, playerID, targetID string) error {
	if err := validatePlayerID(typeName, "playerId", playerID); err != nil {
		return err
	}
	return validatePlayerID(typeName, "targetId", targetID)
}

// validateHex checks for lowercase hex of min-max bytes (twice as many
// characters).
func validateHex(typeName, field, value string, min, max int) error {
	if len(value)%2 != 0 || len(value) < 2*min || len(value) > 2*max {
		if min == max {
			return invalid(typeName, field, fmt.Sprintf("must be %d bytes of hex", min))
		}
		return invalid(typeName, field, fmt.Sprintf("must be %d-%d bytes of hex", min, max))
	}
	for i := 0; i < len(value); i++ {
		if c := value[i]; (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return invalid(typeName, field, "may only contain 0-9 and a-f")
		}
	}
	return nil
}

// Validate always succeeds: an unknown message has no rules to check.
func (Unknown) Validate() error { return nil }

func invalid(typeName, field, reason string) error {
	return &ValidationError{Type: typeName, Field: field, Reason: reason}
}

// validatePlayerID checks for 1-16 characters of [a-zA-Z0-9_-].
func validatePlayerID(typeName, field, playerID string) error {
	if len(playerID) == 0 || len(playerID) > MaxPlayerIDLength {
		return invalid(typeName, field, fmt.Sprintf("must be 1-%d characters", MaxPlayerIDLength))
	}
	for _, r := range playerID {
		if !isPlayerIDRune(r) {
			return invalid(typeName, field, "may only contain a-z, A-Z, 0-9, _ and -")
		}
	}
	return nil
}

func isPlayerIDRune(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-'
}

// validateText checks a free-text field: valid UTF-8, no control characters,
// and a length in characters between min and max.
func validateText(typeName, field, value string, min, max int) error {
	if !utf8.ValidString(value) {
		return invalid(typeName, field, "is not valid UTF-8")
	}
	length := utf8.RuneCountInString(value)
	if length < min || length > max {
		return invalid(typeName, field, fmt.Sprintf("must be %d-%d characters", min, max))
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return invalid(typeName, field, "contains a control character")
		}
	}
	return nil
}

func validateGender(typeName, field string, gender int) error {
	if gender != GenderMale && gender != GenderFemale {
		return invalid(typeName, field, fmt.Sprintf("must be %d or %d", GenderMale, GenderFemale))
	}
	return nil
}

func validateTimestamp(typeName string, t int64) error {
	if t < 0 {
		return invalid(typeName, "t", "must not be negative")
	}
	return nil
}
