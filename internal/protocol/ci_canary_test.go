package protocol

import "testing"

// Throwaway: proves CI turns red on a failing Go test (#5). Never merge.
func TestCICanaryMustFail(t *testing.T) {
	t.Fatal("deliberate failure for the #5 CI test")
}
