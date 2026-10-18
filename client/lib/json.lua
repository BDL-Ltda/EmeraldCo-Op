-- Integer-only JSON for the protocol subset. No platform globals or dependencies.
local M = { null = {} }
local ARRAY, OBJECT = {}, {}
local MAX_DEPTH = 64

function M.array(value) return setmetatable(value or {}, ARRAY) end
function M.object(value) return setmetatable(value or {}, OBJECT) end

local function fail(message) error(message, 0) end
local function validString(value)
	if not utf8.len(value) then fail("invalid UTF-8 string") end
end

local ESCAPES = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
	['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function quote(value)
	validString(value)
	return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
		return ESCAPES[char] or string.format("\\u%04x", char:byte())
	end) .. '"'
end

local function encode(value, depth, active)
	if value == M.null or value == nil then return "null" end
	local kind = type(value)
	if kind == "string" then return quote(value) end
	if kind == "boolean" then return tostring(value) end
	if kind == "number" then
		if math.type(value) ~= "integer" then fail("expected a Lua integer") end
		return tostring(value)
	end
	if kind ~= "table" then fail("unsupported JSON value") end
	if depth > MAX_DEPTH then fail("JSON nesting limit exceeded") end
	if active[value] then fail("cyclic table") end
	active[value] = true
	local count, maximum, numeric, keys = 0, 0, true, {}
	for key in next, value do
		count = count + 1
		if math.type(key) == "integer" and key >= 1 then
			maximum = math.max(maximum, key)
		else
			numeric = false
		end
		keys[#keys + 1] = key
	end
	local meta = getmetatable(value)
	local isArray = meta == ARRAY or (meta ~= OBJECT and count > 0 and numeric)
	local parts = {}
	if isArray then
		if not numeric or maximum ~= count then fail("expected a dense array") end
		for i = 1, count do parts[i] = encode(value[i], depth + 1, active) end
	else
		for _, key in ipairs(keys) do
			if type(key) ~= "string" then fail("expected string object keys") end
		end
		-- Preserve the protocol envelope's v/type-first convention, then sort keys.
		local priority = { v = 1, type = 2 }
		table.sort(keys, function(a, b)
			local pa, pb = priority[a] or 3, priority[b] or 3
			if pa ~= pb then return pa < pb end
			return a < b
		end)
		for i, key in ipairs(keys) do
			parts[i] = quote(key) .. ":" .. encode(value[key], depth + 1, active)
		end
	end
	active[value] = nil
	return (isArray and "[" or "{") .. table.concat(parts, ",") .. (isArray and "]" or "}")
end

function M.encode(value)
	local ok, result = pcall(encode, value, 1, {})
	if ok then return result end
	return nil, result
end

local function decode(source)
	if type(source) ~= "string" then fail("expected JSON text") end
	local pos, length = 1, #source
	local function bad(message) fail(message .. " at byte " .. pos) end
	local function skip() pos = source:find("[^ \t\r\n]", pos) or (length + 1) end
	local function hex4()
		local digits = source:sub(pos, pos + 3)
		if #digits ~= 4 or digits:find("[^%da-fA-F]") then bad("invalid Unicode escape") end
		pos = pos + 4
		return tonumber(digits, 16)
	end
	local function readString()
		pos = pos + 1 -- opening quote
		local parts, start = {}, pos
		while pos <= length do
			local char = source:sub(pos, pos)
			if char == '"' or char == "\\" then
				parts[#parts + 1] = source:sub(start, pos - 1)
				pos = pos + 1
				if char == '"' then
					local result = table.concat(parts)
					validString(result)
					return result
				end
				local escaped = source:sub(pos, pos)
				pos = pos + 1
				if escaped == "u" then
					local code = hex4()
					if code >= 0xD800 and code <= 0xDBFF then
						if source:sub(pos, pos + 1) ~= "\\u" then bad("missing low surrogate") end
						pos = pos + 2
						local low = hex4()
						if low < 0xDC00 or low > 0xDFFF then bad("invalid low surrogate") end
						code = 0x10000 + (code - 0xD800) * 0x400 + low - 0xDC00
					elseif code >= 0xDC00 and code <= 0xDFFF then
						bad("unexpected low surrogate")
					end
					parts[#parts + 1] = utf8.char(code)
				else
					local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
						f = '\f', n = '\n', r = '\r', t = '\t' }
					if not escapes[escaped] then bad("invalid string escape") end
					parts[#parts + 1] = escapes[escaped]
				end
				start = pos
			else
				if char:byte() < 32 then bad("unescaped control character") end
				pos = pos + 1
			end
		end
		bad("unterminated string")
	end
	local readValue
	local function container(isArray, depth)
		if depth > MAX_DEPTH then bad("JSON nesting limit exceeded") end
		local result, closing = isArray and M.array() or M.object(), isArray and "]" or "}"
		pos = pos + 1
		skip()
		if source:sub(pos, pos) == closing then pos = pos + 1; return result end
		while true do
			local key = #result + 1
			if not isArray then
				if source:sub(pos, pos) ~= '"' then bad("expected object key") end
				key = readString()
				if result[key] ~= nil then bad("duplicate object key") end
				skip()
				if source:sub(pos, pos) ~= ":" then bad("expected colon") end
				pos = pos + 1
			end
			result[key] = readValue(depth + 1)
			skip()
			local char = source:sub(pos, pos)
			pos = pos + 1
			if char == closing then return result end
			if char ~= "," then bad("expected comma or closing delimiter") end
			skip()
		end
	end
	function readValue(depth)
		skip()
		local char = source:sub(pos, pos)
		if char == '"' then return readString() end
		if char == "{" then return container(false, depth) end
		if char == "[" then return container(true, depth) end
		for text, value in pairs({ ["true"] = true, ["false"] = false, ["null"] = M.null }) do
			if source:sub(pos, pos + #text - 1) == text then pos = pos + #text; return value end
		end
		if char == "-" or char:match("%d") then
			local start = pos
			if char == "-" then pos = pos + 1 end
			local first = source:sub(pos, pos)
			if first == "0" then
				pos = pos + 1
			elseif first:match("[1-9]") then
				repeat pos = pos + 1 until not source:sub(pos, pos):match("%d")
			else
				bad("invalid integer")
			end
			local value = tonumber(source:sub(start, pos - 1))
			if math.type(value) ~= "integer" then bad("integer out of range") end
			return value
		end
		bad("expected JSON value")
	end
	local result = readValue(1)
	skip()
	if pos <= length then bad("trailing JSON data") end
	return result
end

function M.decode(source)
	local ok, result = pcall(decode, source)
	if ok then return result end
	return nil, result
end

return M
