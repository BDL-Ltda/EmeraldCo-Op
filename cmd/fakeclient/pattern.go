package main

import "github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"

// These coordinates are a synthetic path, not values read from an emulator.
type walker struct {
	pattern      string
	steps        uint64
	alternateMap bool
}

func newWalker(pattern string) *walker { return &walker{pattern: pattern} }

func (w *walker) state() protocol.PresenceState {
	state := protocol.PresenceState{
		MapGroup: 0, MapNum: 9, X: 5, Y: 3,
		Facing: protocol.FacingEast, Visible: true,
	}
	if w.pattern != "idle" && w.steps != 0 {
		const side = 4
		edge := (w.steps - 1) / side % 4
		offset := int((w.steps-1)%side) + 1
		switch edge {
		case 0:
			state.X += offset
		case 1:
			state.X += side
			state.Y += offset
			state.Facing = protocol.FacingSouth
		case 2:
			state.X += side - offset
			state.Y += side
			state.Facing = protocol.FacingWest
		case 3:
			state.Y += side - offset
			state.Facing = protocol.FacingNorth
		}
	}
	if w.pattern == "warp" && w.alternateMap {
		state.MapGroup, state.MapNum = 1, 0
	}
	return state
}

func (w *walker) step() protocol.PresenceState {
	if w.pattern != "idle" {
		w.steps++
	}
	return w.state()
}

func (w *walker) warp() protocol.PresenceState {
	if w.pattern == "warp" {
		w.alternateMap = !w.alternateMap
	}
	return w.state()
}
