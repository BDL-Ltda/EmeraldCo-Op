local framing, h = require("framing"), require("helpers")
local tests = {}

tests["partial chunks produce only complete lines"] = function()
	local framer = assert(framing.new())
	h.same(framer:feed("hel"), {})
	h.same(framer:feed("lo\nwor"), { "hello" })
	h.same(framer:feed("ld\n"), { "world" })
	h.eq(framer:finish(), true)
end

tests["several lines, empty lines and empty chunks are preserved"] = function()
	local framer = assert(framing.new())
	h.same(framer:feed(""), {})
	h.same(framer:feed("a\n\nb\nc\n"), { "a", "", "b", "c" })
	h.same(framer:feed(""), {})
	h.eq(framer:finish(), true)
end

tests["framing treats UTF-8, CR and NUL as bytes"] = function()
	local framer = assert(framing.new())
	local text, lines = "é😀\0\r\n", {}
	for i = 1, #text do
		for _, line in ipairs(assert(framer:feed(text:sub(i, i)))) do lines[#lines + 1] = line end
	end
	h.same(lines, { "é😀\0\r" })
end

tests["exact maximum works with a separately arriving newline"] = function()
	local framer, line = assert(framing.new()), string.rep("x", 4096)
	h.same(framer:feed(line), {})
	h.same(framer:feed("\n" .. line .. "\n"), { line, line })
	h.eq(framer:finish(), true)
end

tests["limit counts bytes, not characters"] = function()
	local framer = assert(framing.new(2))
	h.same(framer:feed("é\n"), { "é" })
	h.rejected(framer:feed("éx"))
end

tests["oversize chunk is rejected and poisons the stream"] = function()
	local framer = assert(framing.new(4))
	h.rejected(framer:feed(string.rep("x", 1000000)))
	h.rejected(framer:feed("ok\n"))
	h.rejected(framer:finish())
end

tests["oversize partial line discards earlier lines in the same batch"] = function()
	local framer = assert(framing.new(4))
	h.same(framer:feed("1234"), {})
	h.rejected(framer:feed("5\n"))
	framer = assert(framing.new(4))
	h.rejected(framer:feed("ok\n12345\n"))
end

tests["EOF rejects an unterminated line but accepts an empty stream"] = function()
	local framer = assert(framing.new())
	h.eq(framer:finish(), true)
	h.same(framer:feed("partial"), {})
	h.rejected(framer:finish())
	h.rejected(framer:feed("\n"))
end

tests["invalid arguments return errors"] = function()
	for _, limit in ipairs({ false, "4", 0, -1, 1.5, math.huge }) do h.rejected(framing.new(limit)) end
	local framer = assert(framing.new())
	h.rejected(framer:feed(false))
	h.same(framer:feed("ok\n"), { "ok" })
end

return tests
