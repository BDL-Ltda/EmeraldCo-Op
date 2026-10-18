local json, h = require("json"), require("helpers")
local tests = {}

tests["scalars and signed 64-bit integers round trip exactly"] = function()
	for _, value in ipairs({ true, false, 0, -1, 4294967295, 1712345678901,
		9007199254740993, math.maxinteger, math.mininteger, json.null, "" }) do
		local text = assert(json.encode(value))
		local decoded, err = json.decode(text)
		h.eq(err, nil)
		h.eq(decoded, value)
	end
	h.eq(assert(json.encode(nil)), "null")
	local decoded, err = json.decode("false") -- false is a valid result, not an error
	h.eq(err, nil)
	h.eq(decoded, false)
end

tests["empty objects and arrays stay distinct"] = function()
	h.eq(assert(json.encode({})), "{}")
	h.eq(assert(json.encode(json.array())), "[]")
	for _, text in ipairs({ "{}", "[]", '[{},[],null,false]' }) do
		h.eq(assert(json.encode(assert(json.decode(text)))), text)
	end
end

tests["null preserves object fields and array indices"] = function()
	local result = assert(json.decode('{"missing":null,"items":[null,1,null]}'))
	h.eq(result.missing, json.null)
	h.eq(#result.items, 3)
	h.eq(result.items[1], json.null)
	h.eq(result.items[3], json.null)
	h.eq(assert(json.encode(result)), '{"items":[null,1,null],"missing":null}')
end

tests["strings escape all control bytes and JSON delimiters"] = function()
	local controls = {}
	for i = 0, 31 do controls[#controls + 1] = string.char(i) end
	local value = table.concat(controls) .. '\\"/<>&'
	local text = assert(json.encode(value))
	assert(not text:find("[%z\1-\31]"))
	h.eq(assert(json.decode(text)), value)
	h.eq(assert(json.decode('"\\\"\\\\\\/\\b\\f\\n\\r\\t"')), '"\\/\b\f\n\r\t')
	h.eq(assert(json.encode("<>&")), '"<>&"')
end

tests["Unicode escapes include surrogate pairs and embedded NUL"] = function()
	h.eq(assert(json.decode('"Pok\\u00e9mon \\u6771\\u4eac \\ud83d\\ude00 \\u0000"')),
		"Pokémon 東京 😀 \0")
	local text = '"Pokémon 東京 😀"'
	h.eq(assert(json.encode(assert(json.decode(text)))), text)
	h.eq(assert(json.decode('"\\uDBFF\\uDFFF"')), utf8.char(0x10FFFF))
end

tests["objects use string keys and a stable protocol envelope"] = function()
	local value = json.object({ z = true, type = "ping", v = 1, a = { 1, false } })
	h.eq(assert(json.encode(value)), '{"v":1,"type":"ping","a":[1,false],"z":true}')
	h.eq(assert(json.decode(' \r\n\t {"x":-2,"y":0} \n')).x, -2)
	h.eq(assert(json.encode(json.object({ ["1"] = "a" }))), '{"1":"a"}')
end

local invalid = {
	"", " ", "nil", "True", "truefalse", "nullx", "1 2", "-", "+1", "01", "-01",
	"1.0", "1.5", "1e3", "1E+3", "0x10", "NaN", "Infinity",
	"9223372036854775808", "-9223372036854775809",
	"[", "{", "[1,]", '{"a":1,}', "[,1]", "[1 2]", '{"a" 1}', '{1:2}',
	'{"a":1,"a":2}', '{"a":null,"a":2}', '"unclosed', '"\\x"', '"\\u12"',
	'"\\uZZZZ"', '"\\uD800"', '"\\uDC00"', '"\\uD800\\u0041"',
	'"\\uD800\\uD800"', '"\n"', '"\0"', '"\255"', '"\192\175"', '"\237\160\128"',
}
for i, text in ipairs(invalid) do
	tests[string.format("reject malformed JSON %02d", i)] = function()
		h.rejected(json.decode(text))
	end
end

tests["unsupported Lua values are rejected without lossy coercion"] = function()
	for _, value in ipairs({ 1.5, 1.0, math.huge, -math.huge, 0/0,
		function() end, coroutine.create(function() end), { [1] = true, [3] = true },
		{ [1] = true, name = "mixed" }, { [false] = true }, json.array({ named = true }),
		json.object({ true }), "\255" }) do
		h.rejected(json.encode(value))
	end
	h.rejected(json.decode({}))
end

tests["cycles fail but shared non-cyclic children work"] = function()
	local cyclic = {}
	cyclic.self = cyclic
	h.rejected(json.encode(cyclic))
	local child = { value = 1 }
	h.eq(assert(json.encode({ child, child })), '[{"value":1},{"value":1}]')
end

tests["nesting is bounded for encoding and decoding"] = function()
	local atLimit = string.rep("[", 64) .. "0" .. string.rep("]", 64)
	h.eq(assert(json.encode(assert(json.decode(atLimit)))), atLimit)
	h.rejected(json.decode("[" .. atLimit .. "]"))
	local value = 0
	for _ = 1, 65 do value = { value } end
	h.rejected(json.encode(value))
end

tests["errors never include input payloads"] = function()
	local _, err = json.decode('{"private-fixture":')
	assert(not err:find("private-fixture", 1, true))
end

return tests
