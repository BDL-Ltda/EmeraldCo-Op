// Package protocol defines the Emerald Co-Op wire protocol: JSON messages,
// one per line, over TCP. See docs/protocol.md for the full contract.
//
// Every line is a JSON object with a protocol version "v", a "type" and the
// fields of that type, all at the top level:
//
//	{"v":2,"type":"ping","t":1712345678901}
package protocol

import "encoding/json"

// Version is the protocol version this package speaks. A peer that sends any
// other value gets ErrVersionMismatch.
const Version = 2

// MaxLineLength is the longest line, in bytes and excluding the trailing
// newline, that Encode produces and Decoder accepts.
const MaxLineLength = 4096

// MaxRemotePlayers is the most players a welcome can list: a room holds at
// most 5 players, so a newcomer sees at most 4 others.
const MaxRemotePlayers = 4

// Message type names, as they appear in the "type" field.
const (
	TypeHello    = "hello"
	TypeWelcome  = "welcome"
	TypeJoin     = "join"
	TypePresence = "presence"
	TypeLeave    = "leave"
	TypePing     = "ping"
	TypePong     = "pong"
	TypeError    = "error"

	TypeTradeAvailable = "trade_available"
	TypeTradeInvite    = "trade_invite"
	TypeTradeAccept    = "trade_accept"
	TypeTradeDecline   = "trade_decline"
	TypeTradeCancel    = "trade_cancel"
	TypeTradeLink      = "trade_link"
	TypeTradeConfirm   = "trade_confirm"
)

// Trade decline reasons.
const (
	DeclineDeclined = "declined"
	DeclineTimeout  = "timeout"
	DeclineBusy     = "busy"
)

// Trade cancel reasons.
const (
	CancelCanceled     = "canceled"
	CancelTimeout      = "timeout"
	CancelDisconnected = "disconnected"
)

// Gender values, matching MALE and FEMALE in the pokeemerald decomp.
const (
	GenderMale   = 0
	GenderFemale = 1
)

// Facing values, matching DIR_SOUTH, DIR_NORTH, DIR_WEST and DIR_EAST in the
// pokeemerald decomp.
const (
	FacingSouth = 1
	FacingNorth = 2
	FacingWest  = 3
	FacingEast  = 4
)

// Leave reasons.
const (
	LeaveDisconnect = "disconnect"
	LeaveTimeout    = "timeout"
	LeaveKicked     = "kicked"
	LeaveReplaced   = "replaced"
)

// Error codes. The server closes the connection after sending any error.
const (
	CodeBadKey          = "bad_key"
	CodeBadMessage      = "bad_message"
	CodeRoomFull        = "room_full"
	CodeVersionMismatch = "version_mismatch"
	CodeBadHello        = "bad_hello"
)

// Message is implemented by every message type, including Unknown.
//
// Struct fields without `omitempty` are required on the wire: Decoder rejects
// a line where one is missing or null.
type Message interface {
	// Type returns the value of the "type" field.
	Type() string
	// Validate reports whether every field holds an allowed value.
	Validate() error
}

// Hello is the first message a client sends after connecting.
type Hello struct {
	PlayerID      string `json:"playerId"`
	JoinKey       string `json:"joinKey"`
	TrainerID     uint32 `json:"trainerId"`
	Gender        int    `json:"gender"`
	ClientVersion string `json:"clientVersion"`
}

// Welcome is the server's answer to an accepted hello. It lists the players
// already connected, not including the newcomer.
type Welcome struct {
	Players []Player `json:"players"`
}

// MarshalJSON encodes nil Players as [] rather than null, since the field is
// required.
func (m Welcome) MarshalJSON() ([]byte, error) {
	type plainWelcome Welcome
	if m.Players == nil {
		m.Players = []Player{}
	}
	return json.Marshal(plainWelcome(m))
}

// Player describes a connected player inside a Welcome.
type Player struct {
	PlayerID  string `json:"playerId"`
	TrainerID uint32 `json:"trainerId"`
	Gender    int    `json:"gender"`
	// Presence is the player's last known presence, or nil if they have not
	// sent one yet.
	Presence *PresenceState `json:"presence,omitempty"`
}

// Join tells the other players that someone was accepted into the room.
type Join struct {
	PlayerID  string `json:"playerId"`
	TrainerID uint32 `json:"trainerId"`
	Gender    int    `json:"gender"`
}

// Presence is where a player is in the overworld. Clients send it when it
// changes; the server relays it to everyone else.
type Presence struct {
	PlayerID string `json:"playerId"`
	PresenceState
}

// PresenceState holds the fields of a Presence other than the player ID. It is
// embedded in Presence and nested in Player.
type PresenceState struct {
	MapGroup int  `json:"mapGroup"`
	MapNum   int  `json:"mapNum"`
	X        int  `json:"x"`
	Y        int  `json:"y"`
	Facing   int  `json:"facing"`
	Visible  bool `json:"visible"`
}

// Leave tells the other players that someone left the room.
type Leave struct {
	PlayerID string `json:"playerId"`
	Reason   string `json:"reason"`
}

// Ping asks the peer to answer with a Pong carrying the same T.
type Ping struct {
	// T is the sender's timestamp in milliseconds.
	T int64 `json:"t"`
}

// Pong answers a Ping, echoing its T.
type Pong struct {
	T int64 `json:"t"`
}

// Error is sent by the server right before it closes the connection.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Relayed is implemented by the client messages that the server stamps with
// the sender's player ID and relays unchanged to every other player: all the
// trade messages. Only reciprocal confirms have minimal audit-pairing state;
// this does not affect routing or enforce a gameplay state machine.
type Relayed interface {
	Message
	// WithPlayerID returns a copy of the message with playerId set to id.
	WithPlayerID(id string) Message
}

// TradeAvailable says whether a player is waiting to trade at a Cable Club
// attendant. The server does not remember it; see docs/protocol.md.
type TradeAvailable struct {
	PlayerID  string `json:"playerId"`
	Available bool   `json:"available"`
}

// TradeInvite asks TargetID to trade with PlayerID.
type TradeInvite struct {
	PlayerID string `json:"playerId"`
	TargetID string `json:"targetId"`
}

// TradeAccept answers a TradeInvite from TargetID with yes.
type TradeAccept struct {
	PlayerID string `json:"playerId"`
	TargetID string `json:"targetId"`
}

// TradeDecline answers a TradeInvite from TargetID with no.
type TradeDecline struct {
	PlayerID string `json:"playerId"`
	TargetID string `json:"targetId"`
	Reason   string `json:"reason"`
}

// TradeCancel ends a pending invite or a running trade session with TargetID.
type TradeCancel struct {
	PlayerID string `json:"playerId"`
	TargetID string `json:"targetId"`
	Reason   string `json:"reason"`
}

// TradeLink carries opaque virtual-link bytes to the trade partner.
type TradeLink struct {
	PlayerID string `json:"playerId"`
	TargetID string `json:"targetId"`
	Seq      uint32 `json:"seq"`
	// Data is the payload as lowercase hex, at most MaxTradeLinkBytes bytes.
	Data string `json:"data"`
}

// TradeConfirm is sent when a player confirms the trade, with the Pokémon
// they are giving away.
type TradeConfirm struct {
	PlayerID string `json:"playerId"`
	TargetID string `json:"targetId"`
	// Pokemon is the outgoing struct Pokemon as lowercase hex, exactly
	// PokemonBytes bytes.
	Pokemon string `json:"pokemon"`
}

func (m TradeAvailable) WithPlayerID(id string) Message { m.PlayerID = id; return m }
func (m TradeInvite) WithPlayerID(id string) Message    { m.PlayerID = id; return m }
func (m TradeAccept) WithPlayerID(id string) Message    { m.PlayerID = id; return m }
func (m TradeDecline) WithPlayerID(id string) Message   { m.PlayerID = id; return m }
func (m TradeCancel) WithPlayerID(id string) Message    { m.PlayerID = id; return m }
func (m TradeLink) WithPlayerID(id string) Message      { m.PlayerID = id; return m }
func (m TradeConfirm) WithPlayerID(id string) Message   { m.PlayerID = id; return m }

// Unknown is what Decoder returns for a well-formed line whose type this
// version does not know. Callers should log it and ignore it.
type Unknown struct {
	TypeName string
	// Raw is the full line, without the trailing newline.
	Raw []byte
}

func (Hello) Type() string     { return TypeHello }
func (Welcome) Type() string   { return TypeWelcome }
func (Join) Type() string      { return TypeJoin }
func (Presence) Type() string  { return TypePresence }
func (Leave) Type() string     { return TypeLeave }
func (Ping) Type() string      { return TypePing }
func (Pong) Type() string      { return TypePong }
func (Error) Type() string     { return TypeError }
func (u Unknown) Type() string { return u.TypeName }

func (TradeAvailable) Type() string { return TypeTradeAvailable }
func (TradeInvite) Type() string    { return TypeTradeInvite }
func (TradeAccept) Type() string    { return TypeTradeAccept }
func (TradeDecline) Type() string   { return TypeTradeDecline }
func (TradeCancel) Type() string    { return TypeTradeCancel }
func (TradeLink) Type() string      { return TypeTradeLink }
func (TradeConfirm) Type() string   { return TypeTradeConfirm }

// newMessage returns a pointer to a zero message of the given type, or nil if
// the type is unknown.
func newMessage(typeName string) Message {
	switch typeName {
	case TypeHello:
		return &Hello{}
	case TypeWelcome:
		return &Welcome{}
	case TypeJoin:
		return &Join{}
	case TypePresence:
		return &Presence{}
	case TypeLeave:
		return &Leave{}
	case TypePing:
		return &Ping{}
	case TypePong:
		return &Pong{}
	case TypeError:
		return &Error{}
	case TypeTradeAvailable:
		return &TradeAvailable{}
	case TypeTradeInvite:
		return &TradeInvite{}
	case TypeTradeAccept:
		return &TradeAccept{}
	case TypeTradeDecline:
		return &TradeDecline{}
	case TypeTradeCancel:
		return &TradeCancel{}
	case TypeTradeLink:
		return &TradeLink{}
	case TypeTradeConfirm:
		return &TradeConfirm{}
	}
	return nil
}
