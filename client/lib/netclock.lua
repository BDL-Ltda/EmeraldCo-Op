-- The network clock for net.lua: milliseconds that advance with the frames,
-- for sub-second detail, but never run ahead of the wall clock. The relay
-- counts messages per real second, so fast-forward must not speed up the
-- budgets, heartbeats or retries that net.lua times with this clock.
--
-- Pure: tick() is given the wall clock's whole seconds (os.time() in mGBA),
-- so tests can drive it with a fake one.

local M = {
	-- One GBA frame: 280896 cycles at 16777216 Hz, about 16.74 ms.
	FRAME_MS = 280896 * 1000 / 16777216,
}

function M.new()
	local ms = 0.0
	local origin, last = nil, nil
	local clock = {}

	-- Called once per frame. Returns an integer millisecond count that never
	-- goes back and stays within the current elapsed wall-clock second:
	-- ms // 1000 is always the number of whole seconds since the first tick.
	function clock.tick(_, seconds)
		if not origin then
			origin, last = seconds, seconds
		elseif seconds < last then
			-- The system clock was set back: keep the elapsed time continuous.
			origin = origin - (last - seconds)
		end
		last = seconds
		local floor = (seconds - origin) * 1000
		ms = math.max(floor, math.min(ms + M.FRAME_MS, floor + 999))
		return math.floor(ms)
	end

	return clock
end

return M
