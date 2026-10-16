-- Compares the loaded ROM with the build client/addresses.lua was generated from.
-- Pure: no emu, socket or callbacks, so it can be tested outside mGBA.

local M = {}

-- Raw bytes to lowercase hex, e.g. "\x45\x32" -> "4532".
function M.toHex(bytes)
	return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- expected: addresses.romCrc32 (8 lowercase hex digits, from symgen).
-- actualBytes: emu:checksum(), the loaded ROM's CRC32 as 4 big-endian bytes.
-- Returns ok, message. On false the client must not touch game memory.
function M.verify(expected, actualBytes)
	if type(expected) ~= "string" or not expected:match("^%x%x%x%x%x%x%x%x$") then
		return false, "addresses.lua has no valid romCrc32. Regenerate it with cmd/symgen (see README.md)."
	end
	if type(actualBytes) ~= "string" or #actualBytes ~= 4 then
		return false, "mGBA did not return a CRC32 for the loaded ROM. Use mGBA 0.10.5 with a game loaded."
	end
	local actual = M.toHex(actualBytes)
	expected = expected:lower()
	if actual ~= expected then
		return false, string.format("ROM mismatch: expected %s, got %s. Apply the matching .bps patch.", expected, actual)
	end
	return true, string.format("ROM verified (%s)", actual)
end

return M
