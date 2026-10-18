package main

import (
	"testing"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"
)

func TestSquareWalkTurnsAtEveryCornerAndRepeats(t *testing.T) {
	walk := newWalker("square")
	checkpoints := map[int]struct{ x, y, facing int }{
		0: {5, 3, protocol.FacingEast}, 1: {6, 3, protocol.FacingEast},
		4: {9, 3, protocol.FacingEast}, 5: {9, 4, protocol.FacingSouth},
		8: {9, 7, protocol.FacingSouth}, 9: {8, 7, protocol.FacingWest},
		12: {5, 7, protocol.FacingWest}, 13: {5, 6, protocol.FacingNorth},
		16: {5, 3, protocol.FacingNorth}, 17: {6, 3, protocol.FacingEast},
	}
	state := walk.state()
	for step := 0; step <= 17; step++ {
		if step != 0 {
			state = walk.step()
		}
		if state != walk.state() {
			t.Fatalf("step %d returned a state different from the stored state", step)
		}
		if state.MapGroup != 0 || state.MapNum != 9 || !state.Visible {
			t.Fatalf("step %d: unexpected map or visibility: %+v", step, state)
		}
		if err := (protocol.Presence{PlayerID: "bot1", PresenceState: state}).Validate(); err != nil {
			t.Fatalf("step %d is not a valid wire presence: %v", step, err)
		}
		if want, ok := checkpoints[step]; ok && (state.X != want.x || state.Y != want.y || state.Facing != want.facing) {
			t.Errorf("step %d: got (%d,%d,%d), want (%d,%d,%d)", step, state.X, state.Y, state.Facing, want.x, want.y, want.facing)
		}
	}
}

func TestIdleDoesNotMove(t *testing.T) {
	walk := newWalker("idle")
	want := walk.state()
	for step := 0; step < 20; step++ {
		if got := walk.step(); got != want {
			t.Fatalf("idle step %d changed state: got %+v, want %+v", step, got, want)
		}
	}
}

func TestWarpChangesMapsIndependentlyOfWalking(t *testing.T) {
	walk := newWalker("warp")
	start := walk.state()
	first := walk.warp()
	if first.MapGroup != 1 || first.MapNum != 0 || !first.Visible {
		t.Fatalf("first warp: %+v", first)
	}
	if got := walk.state(); got != first {
		t.Fatalf("warp did not retain its state: %+v", got)
	}
	for step := 0; step < 17; step++ {
		if got := walk.step(); got.MapGroup != 1 || got.MapNum != 0 {
			t.Fatalf("walking changed map without a warp: %+v", got)
		}
	}
	second := walk.warp()
	if second.MapGroup != start.MapGroup || second.MapNum != start.MapNum || !second.Visible {
		t.Fatalf("second warp did not return to the initial map: %+v", second)
	}
}
