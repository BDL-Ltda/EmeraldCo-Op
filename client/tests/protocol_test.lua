local json, framing, h = require("json"), require("framing"), require("helpers")
local tests, examples = {}, {}
local file = assert(io.open("docs/protocol.md", "r"))
local inJSON = false
for line in file:lines() do
	if line == "```json" then
		inJSON = true
	elseif line == "```" then
		inJSON = false
	elseif inJSON and line:match("%S") then
		examples[#examples + 1] = line
	end
end
file:close()
assert(#examples > 0, "protocol.md contains no JSON examples")

for i, example in ipairs(examples) do
	tests[string.format("protocol documentation example %02d", i)] = function()
		local value = assert(json.decode(example))
		local encoded = assert(json.encode(value))
		assert(encoded:match('^{"v":2,"type":'))
		h.same(assert(json.decode(encoded)), value)
		h.eq(assert(json.encode(assert(json.decode(encoded)))), encoded)
		assert(#encoded <= framing.MAX_LINE_LENGTH)
	end
end

tests["all documentation messages survive arbitrary stream splits"] = function()
	local stream = table.concat(examples, "\n") .. "\n"
	for _, chunkSize in ipairs({ 1, 2, 3, 7, 64, #stream }) do
		local framer, received = assert(framing.new()), {}
		for pos = 1, #stream, chunkSize do
			for _, line in ipairs(assert(framer:feed(stream:sub(pos, pos + chunkSize - 1)))) do
				received[#received + 1] = line
				assert(json.decode(line))
			end
		end
		h.same(received, examples)
		h.eq(framer:finish(), true)
	end
end

tests["pure transport modules do not mention platform globals"] = function()
	for _, path in ipairs({ "client/lib/json.lua", "client/lib/framing.lua", "client/lib/protocol.lua" }) do
		local source = assert(io.open(path, "r"))
		local text = source:read("a")
		source:close()
		for _, forbidden in ipairs({ "emu", "socket", "callbacks" }) do
			assert(not text:match("%f[%w_]" .. forbidden .. "%f[^%w_]"), path .. " refers to " .. forbidden)
		end
	end
end

return tests
