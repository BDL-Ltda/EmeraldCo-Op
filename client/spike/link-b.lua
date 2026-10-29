-- Issue #80. Use only a disposable ROM/save copy. See docs/virtual-link-spike.md.
local DIR = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
dofile(DIR .. "link.lua")("spike_b", "spike_a", 1, 0, false)
