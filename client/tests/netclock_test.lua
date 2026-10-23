-- Tests for client/lib/netclock.lua with a fake wall clock.
local netclock, h = require("netclock"), require("helpers")
local tests = {}

-- Ticks frames per second of wall time; returns every value the clock gave.
local function run(clock, startSecond, seconds, framesPerSecond)
	local values = {}
	for s = startSecond, startSecond + seconds - 1 do
		for _ = 1, framesPerSecond do values[#values + 1] = clock:tick(s) end
	end
	return values
end

tests["at normal speed the clock follows the frames"] = function()
	local clock = netclock.new()
	h.eq(clock:tick(100), 16)
	h.eq(clock:tick(100), 33)
	h.eq(clock:tick(100), 50)
	local values = run(netclock.new(), 100, 3, 60)
	h.eq(values[#values] // 1000, 2)
	assert(values[#values] > 2900, "a normal-speed second covers about a second of clock")
end

tests["fast-forward never runs ahead of the wall clock"] = function()
	local values = run(netclock.new(), 100, 5, 60 * 8)
	for i, ms in ipairs(values) do
		local second = (i - 1) // (60 * 8)
		h.eq(ms // 1000, second)
		if i > 1 then assert(ms >= values[i - 1], "the clock went back") end
	end
end

tests["a slow or paused emulator catches up to the wall clock"] = function()
	local clock = netclock.new()
	clock:tick(100)
	h.eq(clock:tick(110), 10000)
	h.eq(clock:tick(110), 10016)
end

tests["setting the system clock back does not move the clock back"] = function()
	local clock = netclock.new()
	run(clock, 100, 2, 60)
	local before = clock:tick(101)
	local after = clock:tick(50)
	assert(after >= before, "the clock went back")
	h.eq(after // 1000, 1)
	h.eq(clock:tick(51) // 1000, 2)
end

tests["values are integers"] = function()
	local clock = netclock.new()
	for _ = 1, 100 do h.eq(math.type(clock:tick(7)), "integer") end
end

return tests
