// Package protocol defines the Emerald Co-Op wire protocol: JSON messages,
// one per line, over TCP. See docs/protocol.md for the full contract.
//
// Every line is a JSON object with a protocol version "v", a "type" and the
// fields of that type, all at the top level:
//
//	{"v":1,"type":"ping","t":1712345678901}
package protocol

import "encoding/json"

// Version is the protocol version this package speaks. A peer that sends any
// other value gets ErrVersionMismatch.
const Version = 1

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
	}
	return nil
}
