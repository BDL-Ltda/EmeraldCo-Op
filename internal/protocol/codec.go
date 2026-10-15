package protocol

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
	"strings"
)

var (
	// ErrMalformed means a line is not a JSON object with a numeric "v" and a
	// non-empty string "type", or a field could not be parsed.
	ErrMalformed = errors.New("malformed message")
	// ErrVersionMismatch means a line's "v" is not Version.
	ErrVersionMismatch = errors.New("protocol version mismatch")
	// ErrLineTooLong means a line is longer than MaxLineLength bytes.
	ErrLineTooLong = errors.New("line too long")
	// ErrUnencodable means Encode was given nil or an Unknown message.
	ErrUnencodable = errors.New("message cannot be encoded")
)

// Encode validates msg and returns it as one line of JSON, ending in "\n",
// with "v" and "type" first.
func Encode(msg Message) ([]byte, error) {
	if msg == nil {
		return nil, ErrUnencodable
	}
	switch msg.(type) {
	case Unknown, *Unknown:
		return nil, ErrUnencodable
	}
	if err := msg.Validate(); err != nil {
		return nil, err
	}
	body, err := json.Marshal(msg)
	if err != nil {
		return nil, err
	}

	// Type names are fixed ASCII constants, so they need no JSON escaping.
	line := fmt.Appendf(nil, `{"v":%d,"type":%q`, Version, msg.Type())
	if !bytes.Equal(body, []byte("{}")) {
		line = append(line, ',')
	}
	line = append(line, body[1:]...)
	if len(line) > MaxLineLength {
		return nil, ErrLineTooLong
	}
	return append(line, '\n'), nil
}

// Decoder reads messages from a stream of newline-terminated lines. It never
// buffers more than MaxLineLength+1 bytes, however long a line is.
type Decoder struct {
	reader *bufio.Reader
	// discarding is set after ErrLineTooLong, until the rest of that line has
	// been skipped.
	discarding bool
}

// NewDecoder returns a Decoder that reads from r.
func NewDecoder(r io.Reader) *Decoder {
	return &Decoder{reader: bufio.NewReaderSize(r, MaxLineLength+1)}
}

// Decode reads the next line and returns its message, already validated.
//
// It returns io.EOF at a clean end of stream, io.ErrUnexpectedEOF if the stream
// ends in the middle of a line, and ErrLineTooLong for an oversized line (the
// next call skips the rest of that line). Other errors come from Parse. After
// an error that is not io.EOF, the caller may keep decoding the following
// lines.
func (d *Decoder) Decode() (Message, error) {
	for d.discarding {
		_, err := d.reader.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		d.discarding = false
		if err != nil {
			return nil, err
		}
	}

	line, err := d.reader.ReadSlice('\n')
	switch {
	case errors.Is(err, bufio.ErrBufferFull):
		d.discarding = true
		return nil, ErrLineTooLong
	case errors.Is(err, io.EOF) && len(line) == 0:
		return nil, io.EOF
	case errors.Is(err, io.EOF):
		return nil, io.ErrUnexpectedEOF
	case err != nil:
		return nil, err
	}
	return Parse(line[:len(line)-1])
}

// Parse decodes one line, without its trailing newline, into a validated
// message.
//
// It returns Unknown for a well-formed line of a type it does not know, and
// otherwise an error wrapping ErrMalformed, ErrVersionMismatch or ErrInvalid.
// The version is checked before anything else about the message.
func Parse(line []byte) (Message, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(line, &fields); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	if fields == nil {
		return nil, fmt.Errorf("%w: not a JSON object", ErrMalformed)
	}

	var version int
	if err := unmarshalRequired(fields, "v", &version); err != nil {
		return nil, err
	}
	if version != Version {
		return nil, fmt.Errorf("%w: got %d, want %d", ErrVersionMismatch, version, Version)
	}
	var typeName string
	if err := unmarshalRequired(fields, "type", &typeName); err != nil {
		return nil, err
	}
	if typeName == "" {
		return nil, fmt.Errorf("%w: empty type", ErrMalformed)
	}

	target := newMessage(typeName)
	if target == nil {
		return Unknown{TypeName: typeName, Raw: bytes.Clone(line)}, nil
	}
	targetType := reflect.TypeOf(target).Elem()
	if err := checkRequired(fields, targetType, typeName, ""); err != nil {
		return nil, err
	}
	if err := json.Unmarshal(line, target); err != nil {
		return nil, unmarshalError(typeName, err)
	}

	msg := reflect.ValueOf(target).Elem().Interface().(Message)
	if err := msg.Validate(); err != nil {
		return nil, err
	}
	return msg, nil
}

func unmarshalRequired(fields map[string]json.RawMessage, key string, target any) error {
	raw, ok := fields[key]
	if !ok || isNull(raw) {
		return fmt.Errorf("%w: missing %q", ErrMalformed, key)
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return fmt.Errorf("%w: bad %q: %v", ErrMalformed, key, err)
	}
	return nil
}

// unmarshalError turns a field that has the wrong JSON type or does not fit
// its Go type (for example a fraction, or a trainerId above 2^32-1) into a
// ValidationError naming the field.
func unmarshalError(typeName string, err error) error {
	var typeError *json.UnmarshalTypeError
	if errors.As(err, &typeError) {
		return invalid(typeName, typeError.Field, "has the wrong JSON type or is out of range")
	}
	return fmt.Errorf("%w: %v", ErrMalformed, err)
}

// checkRequired returns a ValidationError for the first field of structType
// that is missing from fields or null. Every field without `omitempty` is
// required. It descends into embedded structs, nested objects and arrays of
// objects.
func checkRequired(fields map[string]json.RawMessage, structType reflect.Type, typeName, prefix string) error {
	for i := range structType.NumField() {
		field := structType.Field(i)
		name, options, _ := strings.Cut(field.Tag.Get("json"), ",")
		if field.Anonymous && name == "" {
			if err := checkRequired(fields, field.Type, typeName, prefix); err != nil {
				return err
			}
			continue
		}

		raw, present := fields[name]
		if !present || isNull(raw) {
			if options == "omitempty" {
				continue
			}
			return invalid(typeName, prefix+name, "is required")
		}
		if err := checkNested(raw, field.Type, typeName, prefix+name); err != nil {
			return err
		}
	}
	return nil
}

// checkNested runs checkRequired on a field's value when the field is a
// struct, a pointer to a struct or a slice of structs. Values of the wrong
// JSON shape are left for json.Unmarshal to reject.
func checkNested(raw json.RawMessage, fieldType reflect.Type, typeName, path string) error {
	if fieldType.Kind() == reflect.Pointer {
		fieldType = fieldType.Elem()
	}
	switch {
	case fieldType.Kind() == reflect.Struct:
		var nested map[string]json.RawMessage
		if json.Unmarshal(raw, &nested) != nil {
			return nil
		}
		return checkRequired(nested, fieldType, typeName, path+".")
	case fieldType.Kind() == reflect.Slice && fieldType.Elem().Kind() == reflect.Struct:
		var elements []json.RawMessage
		if json.Unmarshal(raw, &elements) != nil {
			return nil
		}
		for i, element := range elements {
			elementPath := fmt.Sprintf("%s[%d]", path, i)
			if err := checkNested(element, fieldType.Elem(), typeName, elementPath); err != nil {
				return err
			}
		}
	}
	return nil
}

func isNull(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}
