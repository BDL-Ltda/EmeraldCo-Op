-- Issue #80. Use only a disposable ROM/save copy. See docs/virtual-link-spike.md.
local DIR = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
-- One-way delay in milliseconds: 0, 25, 50 or 100 (both sides use the same value).
-- Last argument: fixture party opt-in; changes the party and may save it.
dofile(DIR .. "link.lua")("spike_a", "spike_b", 0, 0, false)
