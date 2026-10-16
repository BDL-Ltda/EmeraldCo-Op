package protocol

import (
	"errors"
	"strings"
	"testing"
)

func TestValidateJoinKey(t *testing.T) {
	for _, key := range []string{"x", strings.Repeat("é", MaxJoinKeyLength)} {
		if err := ValidateJoinKey(key); err != nil {
			t.Fatal(err)
		}
	}
	for _, key := range []string{"", strings.Repeat("x", MaxJoinKeyLength+1), "control\ncharacter", string([]byte{0xff})} {
		err := ValidateJoinKey(key)
		var validation *ValidationError
		if !errors.As(err, &validation) || validation.Field != "joinKey" || !errors.Is(err, ErrInvalid) {
			t.Fatalf("expected joinKey ValidationError, got %v", err)
		}
	}
}
