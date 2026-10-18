-- Tests for client/lib/romcheck.lua, discovered by client/tests/run.lua.

package.path = "client/lib/?.lua;" .. package.path
local romcheck = require("romcheck")

local tests = {}
local function test(name, fn)
	tests[name] = fn
end
local function eq(got, want)
	if got ~= want then error(string.format("got %q, want %q", tostring(got), tostring(want)), 2) end
end

-- emu:checksum() returns the CRC32 as 4 big-endian bytes.
local CRC = "\x45\x32\x02\xb6"

test("toHex pads and lowercases", function()
	eq(romcheck.toHex("\x00\x0a\xff"), "000aff")
end)

test("matching CRC is verified", function()
	local ok, msg = romcheck.verify("453202b6", CRC)
	eq(ok, true)
	eq(msg, "ROM verified (453202b6)")
end)

test("expected CRC is case-insensitive", function()
	eq((romcheck.verify("453202B6", CRC)), true)
end)

test("different ROM is a mismatch with both hashes", function()
	local ok, msg = romcheck.verify("453202b6", "\xde\xad\xbe\xef")
	eq(ok, false)
	eq(msg, "ROM mismatch: expected 453202b6, got deadbeef. Apply the matching .bps patch.")
end)

test("missing romCrc32 asks to regenerate addresses.lua", function()
	local ok, msg = romcheck.verify(nil, CRC)
	eq(ok, false)
	assert(msg:find("regenerate", 1, true) or msg:find("Regenerate", 1, true), msg)
end)

test("malformed romCrc32 is rejected", function()
	eq((romcheck.verify("4532", CRC)), false)
	eq((romcheck.verify("zz3202b6", CRC)), false)
end)

test("no checksum from mGBA is rejected", function()
	eq((romcheck.verify("453202b6", nil)), false)
	eq((romcheck.verify("453202b6", "\x45\x32")), false)
end)

return tests
