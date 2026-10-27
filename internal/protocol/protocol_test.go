package protocol

import (
	"bytes"
	"errors"
	"io"
	"os"
	"reflect"
	"strings"
	"testing"
)

func validPresenceState() PresenceState {
	return PresenceState{MapGroup: 0, MapNum: 9, X: 7, Y: -3, Facing: FacingNorth, Visible: true}
}

func TestRoundTrip(t *testing.T) {
	state := validPresenceState()
	tests := []struct {
		name string
		msg  Message
	}{
		{"hello", Hello{PlayerID: "bernardo", JoinKey: "secret key", TrainerID: 4294967295, Gender: GenderFemale, ClientVersion: "0.2.0"}},
		{"welcome empty", Welcome{Players: []Player{}}},
		{"welcome full", Welcome{Players: []Player{
			{PlayerID: "a", TrainerID: 0, Gender: GenderMale, Presence: &state},
			{PlayerID: "b-2", TrainerID: 12345, Gender: GenderFemale},
			{PlayerID: "C_3", TrainerID: 1, Gender: GenderMale},
			{PlayerID: "0123456789abcdef", TrainerID: 2, Gender: GenderFemale, Presence: &state},
		}}},
		{"join", Join{PlayerID: "leo", TrainerID: 54321, Gender: GenderMale}},
		{"presence", Presence{PlayerID: "davi", PresenceState: state}},
		{"presence zero coordinates hidden", Presence{PlayerID: "davi", PresenceState: PresenceState{Facing: FacingSouth}}},
		{"presence extreme coordinates", Presence{PlayerID: "davi", PresenceState: PresenceState{
			MapGroup: MaxMapIndex, MapNum: MaxMapIndex, X: MinCoordinate, Y: MaxCoordinate, Facing: FacingEast,
		}}},
		{"leave disconnect", Leave{PlayerID: "leo", Reason: LeaveDisconnect}},
		{"leave timeout", Leave{PlayerID: "leo", Reason: LeaveTimeout}},
		{"leave kicked", Leave{PlayerID: "leo", Reason: LeaveKicked}},
		{"leave replaced", Leave{PlayerID: "leo", Reason: LeaveReplaced}},
		{"ping", Ping{T: 1712345678901}},
		{"ping zero", Ping{T: 0}},
		{"pong", Pong{T: 1712345678901}},
		{"error bad_key", Error{Code: CodeBadKey, Message: "wrong join key"}},
		{"error bad_message", Error{Code: CodeBadMessage, Message: ""}},
		{"error room_full", Error{Code: CodeRoomFull, Message: "room is full"}},
		{"error version_mismatch", Error{Code: CodeVersionMismatch, Message: "server speaks v1"}},
		{"error bad_hello", Error{Code: CodeBadHello, Message: "bad hello"}},
		{"trade_available on", TradeAvailable{PlayerID: "leo", Available: true}},
		{"trade_available off", TradeAvailable{PlayerID: "leo", Available: false}},
		{"trade_invite", TradeInvite{PlayerID: "leo", TargetID: "davi"}},
		{"trade_accept", TradeAccept{PlayerID: "davi", TargetID: "leo"}},
		{"trade_decline declined", TradeDecline{PlayerID: "davi", TargetID: "leo", Reason: DeclineDeclined}},
		{"trade_decline timeout", TradeDecline{PlayerID: "davi", TargetID: "leo", Reason: DeclineTimeout}},
		{"trade_decline busy", TradeDecline{PlayerID: "davi", TargetID: "leo", Reason: DeclineBusy}},
		{"trade_cancel canceled", TradeCancel{PlayerID: "leo", TargetID: "davi", Reason: CancelCanceled}},
		{"trade_cancel timeout", TradeCancel{PlayerID: "leo", TargetID: "davi", Reason: CancelTimeout}},
		{"trade_cancel disconnected", TradeCancel{PlayerID: "leo", TargetID: "davi", Reason: CancelDisconnected}},
		{"trade_link", TradeLink{PlayerID: "leo", TargetID: "davi", Seq: 7, Data: "00ff10ab"}},
		{"trade_link empty", TradeLink{PlayerID: "leo", TargetID: "davi", Seq: 0, Data: ""}},
		{"trade_link largest", TradeLink{PlayerID: "0123456789abcdef", TargetID: "fedcba9876543210",
			Seq: 4294967295, Data: strings.Repeat("ff", MaxTradeLinkBytes)}},
		{"trade_confirm", TradeConfirm{PlayerID: "leo", TargetID: "davi", Pokemon: strings.Repeat("a5", PokemonBytes)}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			line, err := Encode(tt.msg)
			if err != nil {
				t.Fatalf("Encode: %v", err)
			}
			if !bytes.HasSuffix(line, []byte("\n")) || bytes.Count(line, []byte("\n")) != 1 {
				t.Fatalf("Encode must produce exactly one line ending in \\n, got %q", line)
			}
			if !bytes.HasPrefix(line, []byte(`{"v":2,"type":"`+tt.msg.Type()+`"`)) {
				t.Fatalf("line must start with v and type, got %q", line)
			}

			got, err := NewDecoder(bytes.NewReader(line)).Decode()
			if err != nil {
				t.Fatalf("Decode(%q): %v", line, err)
			}
			if !reflect.DeepEqual(got, tt.msg) {
				t.Fatalf("round trip mismatch\n got: %#v\nwant: %#v", got, tt.msg)
			}
		})
	}
}

func TestTradeMessagesAreRelayedWithSenderID(t *testing.T) {
	messages := []Message{
		TradeAvailable{PlayerID: "x", Available: true},
		TradeInvite{PlayerID: "x", TargetID: "b"},
		TradeAccept{PlayerID: "x", TargetID: "b"},
		TradeDecline{PlayerID: "x", TargetID: "b", Reason: DeclineBusy},
		TradeCancel{PlayerID: "x", TargetID: "b", Reason: CancelTimeout},
		TradeLink{PlayerID: "x", TargetID: "b", Seq: 1, Data: "00"},
		TradeConfirm{PlayerID: "x", TargetID: "b", Pokemon: strings.Repeat("00", PokemonBytes)},
	}
	for _, msg := range messages {
		relayed, ok := msg.(Relayed)
		if !ok {
			t.Fatalf("%s does not implement Relayed", msg.Type())
		}
		stamped := relayed.WithPlayerID("a")
		if stamped.Type() != msg.Type() {
			t.Fatalf("%s: WithPlayerID changed the type to %s", msg.Type(), stamped.Type())
		}
		line, err := Encode(stamped)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Contains(line, []byte(`"playerId":"a"`)) || bytes.Contains(line, []byte(`"playerId":"x"`)) {
			t.Fatalf("%s: got %s", msg.Type(), line)
		}
	}
	// Server-only and presence messages are not relayed through this path.
	for _, msg := range []Message{Presence{}, Ping{}, Hello{}, Welcome{}} {
		if _, ok := msg.(Relayed); ok {
			t.Fatalf("%s must not implement Relayed", msg.Type())
		}
	}
}

func TestEncodeNilPlayersAsEmptyArray(t *testing.T) {
	line, err := Encode(Welcome{})
	if err != nil {
		t.Fatal(err)
	}
	if want := "{\"v\":2,\"type\":\"welcome\",\"players\":[]}\n"; string(line) != want {
		t.Fatalf("got %q, want %q", line, want)
	}
}

func TestEncodeDoesNotEscapeHTML(t *testing.T) {
	line, err := Encode(Error{Code: CodeBadMessage, Message: "<a> & <b>"})
	if err != nil {
		t.Fatal(err)
	}
	if want := "{\"v\":2,\"type\":\"error\",\"code\":\"bad_message\",\"message\":\"<a> & <b>\"}\n"; string(line) != want {
		t.Fatalf("got %q, want %q", line, want)
	}
}

func TestEncodeRejects(t *testing.T) {
	tests := []struct {
		name string
		msg  Message
		want error
	}{
		{"nil", nil, ErrUnencodable},
		{"unknown", Unknown{TypeName: "trade", Raw: []byte(`{"v":2,"type":"trade"}`)}, ErrUnencodable},
		{"unknown pointer", &Unknown{TypeName: "trade"}, ErrUnencodable},
		{"invalid message", Ping{T: -1}, ErrInvalid},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Encode(tt.msg)
			if !errors.Is(err, tt.want) {
				t.Fatalf("got %v, want %v", err, tt.want)
			}
		})
	}
}

func TestParseValidation(t *testing.T) {
	tests := []struct {
		name  string
		line  string
		field string
	}{
		// Required fields.
		{"hello missing playerId", `{"v":2,"type":"hello","joinKey":"k","trainerId":1,"gender":0,"clientVersion":"0.2.0"}`, "playerId"},
		{"hello null joinKey", `{"v":2,"type":"hello","playerId":"a","joinKey":null,"trainerId":1,"gender":0,"clientVersion":"0.2.0"}`, "joinKey"},
		{"hello missing trainerId", `{"v":2,"type":"hello","playerId":"a","joinKey":"k","gender":0,"clientVersion":"0.2.0"}`, "trainerId"},
		{"hello missing gender", `{"v":2,"type":"hello","playerId":"a","joinKey":"k","trainerId":1,"clientVersion":"0.2.0"}`, "gender"},
		{"hello missing clientVersion", `{"v":2,"type":"hello","playerId":"a","joinKey":"k","trainerId":1,"gender":0}`, "clientVersion"},
		{"welcome missing players", `{"v":2,"type":"welcome"}`, "players"},
		{"welcome null players", `{"v":2,"type":"welcome","players":null}`, "players"},
		{"welcome player missing trainerId", `{"v":2,"type":"welcome","players":[{"playerId":"a","gender":0}]}`, "players[0].trainerId"},
		{"welcome null player", `{"v":2,"type":"welcome","players":[null]}`, "players[0].playerId"},
		{"welcome presence missing visible", `{"v":2,"type":"welcome","players":[{"playerId":"a","trainerId":1,"gender":0,"presence":{"mapGroup":0,"mapNum":0,"x":0,"y":0,"facing":1}}]}`, "players[0].presence.visible"},
		{"join missing gender", `{"v":2,"type":"join","playerId":"a","trainerId":1}`, "gender"},
		{"presence missing x", `{"v":2,"type":"presence","playerId":"a","mapGroup":0,"mapNum":0,"y":0,"facing":1,"visible":true}`, "x"},
		{"presence missing visible", `{"v":2,"type":"presence","playerId":"a","mapGroup":0,"mapNum":0,"x":0,"y":0,"facing":1}`, "visible"},
		{"leave missing reason", `{"v":2,"type":"leave","playerId":"a"}`, "reason"},
		{"ping missing t", `{"v":2,"type":"ping"}`, "t"},
		{"pong null t", `{"v":2,"type":"pong","t":null}`, "t"},
		{"error missing message", `{"v":2,"type":"error","code":"bad_key"}`, "message"},

		// playerId.
		{"playerId empty", `{"v":2,"type":"join","playerId":"","trainerId":1,"gender":0}`, "playerId"},
		{"playerId too long", `{"v":2,"type":"join","playerId":"0123456789abcdefg","trainerId":1,"gender":0}`, "playerId"},
		{"playerId space", `{"v":2,"type":"join","playerId":"a b","trainerId":1,"gender":0}`, "playerId"},
		{"playerId dot", `{"v":2,"type":"leave","playerId":"a.b","reason":"timeout"}`, "playerId"},
		{"playerId non-ASCII", `{"v":2,"type":"presence","playerId":"é","mapGroup":0,"mapNum":0,"x":0,"y":0,"facing":1,"visible":true}`, "playerId"},
		{"welcome player bad id", `{"v":2,"type":"welcome","players":[{"playerId":"a/b","trainerId":1,"gender":0}]}`, "players[0].playerId"},
		{"welcome duplicate player", `{"v":2,"type":"welcome","players":[{"playerId":"a","trainerId":1,"gender":0},{"playerId":"a","trainerId":2,"gender":1}]}`, "players[1].playerId"},

		// Hello text fields.
		{"joinKey empty", `{"v":2,"type":"hello","playerId":"a","joinKey":"","trainerId":1,"gender":0,"clientVersion":"0.2.0"}`, "joinKey"},
		{"joinKey too long", `{"v":2,"type":"hello","playerId":"a","joinKey":"` + strings.Repeat("k", MaxJoinKeyLength+1) + `","trainerId":1,"gender":0,"clientVersion":"0.2.0"}`, "joinKey"},
		{"joinKey control character", `{"v":2,"type":"hello","playerId":"a","joinKey":"k\n","trainerId":1,"gender":0,"clientVersion":"0.2.0"}`, "joinKey"},
		{"clientVersion empty", `{"v":2,"type":"hello","playerId":"a","joinKey":"k","trainerId":1,"gender":0,"clientVersion":""}`, "clientVersion"},
		{"clientVersion too long", `{"v":2,"type":"hello","playerId":"a","joinKey":"k","trainerId":1,"gender":0,"clientVersion":"` + strings.Repeat("1", MaxClientVersionLength+1) + `"}`, "clientVersion"},

		// trainerId and gender.
		{"trainerId negative", `{"v":2,"type":"join","playerId":"a","trainerId":-1,"gender":0}`, "trainerId"},
		{"trainerId above uint32", `{"v":2,"type":"join","playerId":"a","trainerId":4294967296,"gender":0}`, "trainerId"},
		{"trainerId string", `{"v":2,"type":"join","playerId":"a","trainerId":"1","gender":0}`, "trainerId"},
		{"gender 2", `{"v":2,"type":"join","playerId":"a","trainerId":1,"gender":2}`, "gender"},
		{"gender negative", `{"v":2,"type":"hello","playerId":"a","joinKey":"k","trainerId":1,"gender":-1,"clientVersion":"0.2.0"}`, "gender"},
		{"welcome player gender", `{"v":2,"type":"welcome","players":[{"playerId":"a","trainerId":1,"gender":5}]}`, "players[0].gender"},

		// Presence ranges.
		{"mapGroup negative", `{"v":2,"type":"presence","playerId":"a","mapGroup":-1,"mapNum":0,"x":0,"y":0,"facing":1,"visible":true}`, "mapGroup"},
		{"mapGroup too big", `{"v":2,"type":"presence","playerId":"a","mapGroup":256,"mapNum":0,"x":0,"y":0,"facing":1,"visible":true}`, "mapGroup"},
		{"mapNum too big", `{"v":2,"type":"presence","playerId":"a","mapGroup":0,"mapNum":256,"x":0,"y":0,"facing":1,"visible":true}`, "mapNum"},
		{"x too small", `{"v":2,"type":"presence","playerId":"a","mapGroup":0,"mapNum":0,"x":-32769,"y":0,"facing":1,"visible":true}`, "x"},
		{"y too big", `{"v":2,"type":"presence","playerId":"a","mapGroup":0,"mapNum":0,"x":0,"y":32768,"facing":1,"visible":true}`, "y"},
		{"x fraction", `{"v":2,"type":"presence","playerId":"a","mapGroup":0,"mapNum":0,"x":1.5,"y":0,"facing":1,"visible":true}`, "x"},
		{"facing 0", `{"v":2,"type":"presence","playerId":"a","mapGroup":0,"mapNum":0,"x":0,"y":0,"facing":0,"visible":true}`, "facing"},
		{"facing 5", `{"v":2,"type":"presence","playerId":"a","mapGroup":0,"mapNum":0,"x":0,"y":0,"facing":5,"visible":true}`, "facing"},
		{"visible not bool", `{"v":2,"type":"presence","playerId":"a","mapGroup":0,"mapNum":0,"x":0,"y":0,"facing":1,"visible":1}`, "visible"},
		{"welcome presence facing", `{"v":2,"type":"welcome","players":[{"playerId":"a","trainerId":1,"gender":0,"presence":{"mapGroup":0,"mapNum":0,"x":0,"y":0,"facing":9,"visible":true}}]}`, "players[0].presence.facing"},
		{"welcome too many players", `{"v":2,"type":"welcome","players":[` +
			`{"playerId":"a","trainerId":1,"gender":0},{"playerId":"b","trainerId":1,"gender":0},` +
			`{"playerId":"c","trainerId":1,"gender":0},{"playerId":"d","trainerId":1,"gender":0},` +
			`{"playerId":"e","trainerId":1,"gender":0}]}`, "players"},

		// Enums and timestamps.
		{"leave unknown reason", `{"v":2,"type":"leave","playerId":"a","reason":"bored"}`, "reason"},
		{"ping negative", `{"v":2,"type":"ping","t":-1}`, "t"},
		{"pong fraction", `{"v":2,"type":"pong","t":1.5}`, "t"},
		{"error unknown code", `{"v":2,"type":"error","code":"oops","message":""}`, "code"},
		{"error message too long", `{"v":2,"type":"error","code":"bad_key","message":"` + strings.Repeat("m", MaxErrorMessageLength+1) + `"}`, "message"},

		// Trade messages.
		{"trade_available missing available", `{"v":2,"type":"trade_available","playerId":"a"}`, "available"},
		{"trade_available not bool", `{"v":2,"type":"trade_available","playerId":"a","available":1}`, "available"},
		{"trade_available bad playerId", `{"v":2,"type":"trade_available","playerId":"a b","available":true}`, "playerId"},
		{"trade_invite missing targetId", `{"v":2,"type":"trade_invite","playerId":"a"}`, "targetId"},
		{"trade_invite null targetId", `{"v":2,"type":"trade_invite","playerId":"a","targetId":null}`, "targetId"},
		{"trade_invite empty targetId", `{"v":2,"type":"trade_invite","playerId":"a","targetId":""}`, "targetId"},
		{"trade_accept targetId too long", `{"v":2,"type":"trade_accept","playerId":"a","targetId":"0123456789abcdefg"}`, "targetId"},
		{"trade_accept missing playerId", `{"v":2,"type":"trade_accept","targetId":"b"}`, "playerId"},
		{"trade_decline missing reason", `{"v":2,"type":"trade_decline","playerId":"a","targetId":"b"}`, "reason"},
		{"trade_decline unknown reason", `{"v":2,"type":"trade_decline","playerId":"a","targetId":"b","reason":"canceled"}`, "reason"},
		{"trade_cancel unknown reason", `{"v":2,"type":"trade_cancel","playerId":"a","targetId":"b","reason":"busy"}`, "reason"},
		{"trade_cancel bad targetId", `{"v":2,"type":"trade_cancel","playerId":"a","targetId":"b/c","reason":"timeout"}`, "targetId"},
		{"trade_link missing seq", `{"v":2,"type":"trade_link","playerId":"a","targetId":"b","data":""}`, "seq"},
		{"trade_link negative seq", `{"v":2,"type":"trade_link","playerId":"a","targetId":"b","seq":-1,"data":""}`, "seq"},
		{"trade_link seq above uint32", `{"v":2,"type":"trade_link","playerId":"a","targetId":"b","seq":4294967296,"data":""}`, "seq"},
		{"trade_link fraction seq", `{"v":2,"type":"trade_link","playerId":"a","targetId":"b","seq":1.5,"data":""}`, "seq"},
		{"trade_link missing data", `{"v":2,"type":"trade_link","playerId":"a","targetId":"b","seq":0}`, "data"},
		{"trade_link odd data", `{"v":2,"type":"trade_link","playerId":"a","targetId":"b","seq":0,"data":"abc"}`, "data"},
		{"trade_link uppercase data", `{"v":2,"type":"trade_link","playerId":"a","targetId":"b","seq":0,"data":"AB"}`, "data"},
		{"trade_link non-hex data", `{"v":2,"type":"trade_link","playerId":"a","targetId":"b","seq":0,"data":"zz"}`, "data"},
		{"trade_link oversize data", `{"v":2,"type":"trade_link","playerId":"a","targetId":"b","seq":0,"data":"` + strings.Repeat("00", MaxTradeLinkBytes+1) + `"}`, "data"},
		{"trade_link data not string", `{"v":2,"type":"trade_link","playerId":"a","targetId":"b","seq":0,"data":[1,2]}`, "data"},
		{"trade_confirm missing pokemon", `{"v":2,"type":"trade_confirm","playerId":"a","targetId":"b"}`, "pokemon"},
		{"trade_confirm short pokemon", `{"v":2,"type":"trade_confirm","playerId":"a","targetId":"b","pokemon":"` + strings.Repeat("00", PokemonBytes-1) + `"}`, "pokemon"},
		{"trade_confirm long pokemon", `{"v":2,"type":"trade_confirm","playerId":"a","targetId":"b","pokemon":"` + strings.Repeat("00", PokemonBytes+1) + `"}`, "pokemon"},
		{"trade_confirm non-hex pokemon", `{"v":2,"type":"trade_confirm","playerId":"a","targetId":"b","pokemon":"` + strings.Repeat("0g", PokemonBytes) + `"}`, "pokemon"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			msg, err := Parse([]byte(tt.line))
			if !errors.Is(err, ErrInvalid) {
				t.Fatalf("got (%#v, %v), want ErrInvalid", msg, err)
			}
			var validationError *ValidationError
			if !errors.As(err, &validationError) {
				t.Fatalf("got %T, want *ValidationError", err)
			}
			if validationError.Field != tt.field {
				t.Fatalf("got field %q (%v), want %q", validationError.Field, err, tt.field)
			}
		})
	}
}

func TestParseMalformed(t *testing.T) {
	tests := []struct {
		name string
		line string
	}{
		{"empty", ``},
		{"garbage", `hello there`},
		{"binary", "\x00\xff\x13\x37"},
		{"truncated", `{"v":2,"type":"ping","t":1`},
		{"two objects", `{"v":2,"type":"ping","t":1}{"v":2,"type":"ping","t":2}`},
		{"array", `[{"v":2,"type":"ping","t":1}]`},
		{"number", `42`},
		{"null", `null`},
		{"empty object", `{}`},
		{"missing v", `{"type":"ping","t":1}`},
		{"null v", `{"v":null,"type":"ping","t":1}`},
		{"string v", `{"v":"1","type":"ping","t":1}`},
		{"fraction v", `{"v":1.5,"type":"ping","t":1}`},
		{"missing type", `{"v":2,"t":1}`},
		{"empty type", `{"v":2,"type":"","t":1}`},
		{"number type", `{"v":2,"type":7,"t":1}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			msg, err := Parse([]byte(tt.line))
			if !errors.Is(err, ErrMalformed) {
				t.Fatalf("got (%#v, %v), want ErrMalformed", msg, err)
			}
		})
	}
}

func TestParseVersionMismatch(t *testing.T) {
	tests := []string{
		`{"v":0,"type":"ping","t":1}`,
		`{"v":3,"type":"ping","t":1}`,
		// A v1.0 client's hello: valid in v1, rejected by version alone.
		`{"v":1,"type":"hello","playerId":"bernardo","joinKey":"example-key","trainerId":2882400001,"gender":0,"clientVersion":"0.2.0"}`,
		`{"v":1,"type":"presence","playerId":"leo","mapGroup":0,"mapNum":9,"x":8,"y":5,"facing":4,"visible":true}`,
		`{"v":1,"type":"hello","playerId":"a","joinKey":"k","trainerId":1,"gender":0,"clientVersion":"9.0.0"}`,
		// The version is checked before the type and fields, so a future client
		// gets version_mismatch rather than bad_message.
		`{"v":1,"type":"hello","futureField":true}`,
		`{"v":1,"type":"teleport"}`,
	}
	for _, line := range tests {
		t.Run(line, func(t *testing.T) {
			_, err := Parse([]byte(line))
			if !errors.Is(err, ErrVersionMismatch) {
				t.Fatalf("got %v, want ErrVersionMismatch", err)
			}
		})
	}
}

func TestParseUnknownType(t *testing.T) {
	line := []byte(`{"v":2,"type":"trade","offer":[1,2,3]}`)

	msg, err := Parse(line)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	unknown, ok := msg.(Unknown)
	if !ok {
		t.Fatalf("got %T, want Unknown", msg)
	}
	if unknown.Type() != "trade" || !bytes.Equal(unknown.Raw, line) {
		t.Fatalf("got %#v", unknown)
	}
	line[0] = 'X'
	if unknown.Raw[0] != '{' {
		t.Fatal("Unknown.Raw must not alias the input")
	}
}

func TestParseIgnoresUnknownFields(t *testing.T) {
	msg, err := Parse([]byte(`{"v":2,"type":"ping","t":5,"addedInAMinorChange":"x"}`))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if msg != (Ping{T: 5}) {
		t.Fatalf("got %#v", msg)
	}
}

// countingReader serves data and counts how many bytes were read from it.
type countingReader struct {
	reader io.Reader
	count  int
}

func (r *countingReader) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	r.count += n
	return n, err
}

// endlessReader returns the same byte forever and never a newline.
type endlessReader struct{}

func (endlessReader) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 'a'
	}
	return len(p), nil
}

func TestDecodeRejectsEndlessLineWithBoundedMemory(t *testing.T) {
	reader := &countingReader{reader: endlessReader{}}
	decoder := NewDecoder(reader)

	_, err := decoder.Decode()

	if !errors.Is(err, ErrLineTooLong) {
		t.Fatalf("got %v, want ErrLineTooLong", err)
	}
	if reader.count > MaxLineLength+1 {
		t.Fatalf("read %d bytes before rejecting, want at most %d", reader.count, MaxLineLength+1)
	}
}

func TestDecodeSkipsOversizeLineAndContinues(t *testing.T) {
	stream := strings.Repeat("x", 10*MaxLineLength) + "\n" + `{"v":2,"type":"ping","t":7}` + "\n"
	decoder := NewDecoder(strings.NewReader(stream))

	if _, err := decoder.Decode(); !errors.Is(err, ErrLineTooLong) {
		t.Fatalf("first Decode: got %v, want ErrLineTooLong", err)
	}
	msg, err := decoder.Decode()
	if err != nil || msg != (Ping{T: 7}) {
		t.Fatalf("second Decode: got (%#v, %v), want ping 7", msg, err)
	}
	if _, err := decoder.Decode(); err != io.EOF {
		t.Fatalf("third Decode: got %v, want io.EOF", err)
	}
}

// paddedPing returns a valid ping line of exactly length bytes, without the
// newline, by padding it with JSON whitespace.
func paddedPing(length int) string {
	prefix := `{"v":2,"type":"ping","t":1`
	return prefix + strings.Repeat(" ", length-len(prefix)-1) + "}"
}

func TestDecodeLineLengthBoundary(t *testing.T) {
	decoder := NewDecoder(strings.NewReader(paddedPing(MaxLineLength) + "\n" + paddedPing(MaxLineLength+1) + "\n"))

	msg, err := decoder.Decode()
	if err != nil || msg != (Ping{T: 1}) {
		t.Fatalf("line of exactly MaxLineLength: got (%#v, %v)", msg, err)
	}
	if _, err := decoder.Decode(); !errors.Is(err, ErrLineTooLong) {
		t.Fatalf("line of MaxLineLength+1: got %v, want ErrLineTooLong", err)
	}
}

func TestDecodeStream(t *testing.T) {
	stream := `{"v":2,"type":"ping","t":1}` + "\n" +
		"garbage\n" +
		`{"v":2,"type":"future","x":1}` + "\n" +
		`{"v":2,"type":"leave","playerId":"a","reason":"timeout"}` + "\n" +
		`{"v":2,"type":"pong","t":2}` // no newline: the stream ends mid-line
	decoder := NewDecoder(strings.NewReader(stream))

	if msg, err := decoder.Decode(); err != nil || msg != (Ping{T: 1}) {
		t.Fatalf("line 1: got (%#v, %v)", msg, err)
	}
	if _, err := decoder.Decode(); !errors.Is(err, ErrMalformed) {
		t.Fatalf("line 2: got %v, want ErrMalformed", err)
	}
	if msg, err := decoder.Decode(); err != nil || msg.Type() != "future" {
		t.Fatalf("line 3: got (%#v, %v), want Unknown", msg, err)
	}
	if msg, err := decoder.Decode(); err != nil || msg != (Leave{PlayerID: "a", Reason: LeaveTimeout}) {
		t.Fatalf("line 4: got (%#v, %v)", msg, err)
	}
	if _, err := decoder.Decode(); err != io.ErrUnexpectedEOF {
		t.Fatalf("line 5: got %v, want io.ErrUnexpectedEOF", err)
	}
}

func TestDecodeEmptyStream(t *testing.T) {
	if _, err := NewDecoder(strings.NewReader("")).Decode(); err != io.EOF {
		t.Fatalf("got %v, want io.EOF", err)
	}
}

// TestProtocolDocExamples keeps docs/protocol.md honest: every line in its
// ```json example blocks must decode, and re-encode to exactly the same line.
func TestProtocolDocExamples(t *testing.T) {
	doc, err := os.ReadFile("../../docs/protocol.md")
	if err != nil {
		t.Fatal(err)
	}

	seenTypes := map[string]bool{}
	inExample := false
	for line := range strings.Lines(string(doc)) {
		line = strings.TrimRight(line, "\n")
		switch {
		case line == "```json":
			inExample = true
			continue
		case line == "```":
			inExample = false
			continue
		case !inExample:
			continue
		}

		msg, err := Parse([]byte(line))
		if err != nil {
			t.Errorf("example %s: %v", line, err)
			continue
		}
		encoded, err := Encode(msg)
		if err != nil {
			t.Errorf("example %s: Encode: %v", line, err)
			continue
		}
		if got := strings.TrimSuffix(string(encoded), "\n"); got != line {
			t.Errorf("example does not match the encoder\n  doc: %s\n code: %s", line, got)
		}
		seenTypes[msg.Type()] = true
	}

	for _, typeName := range []string{TypeHello, TypeWelcome, TypeJoin, TypePresence, TypeLeave, TypePing, TypePong, TypeError,
		TypeTradeAvailable, TypeTradeInvite, TypeTradeAccept, TypeTradeDecline, TypeTradeCancel, TypeTradeLink, TypeTradeConfirm} {
		if !seenTypes[typeName] {
			t.Errorf("docs/protocol.md has no example for %q", typeName)
		}
	}
}
