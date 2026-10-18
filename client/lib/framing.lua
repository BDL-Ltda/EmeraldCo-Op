-- Newline framing over arbitrary byte chunks; limits exclude the LF byte.
local M = { MAX_LINE_LENGTH = 4096 }

function M.new(limit)
	if limit == nil then limit = M.MAX_LINE_LENGTH end
	if math.type(limit) ~= "integer" or limit < 1 then
		return nil, "line limit must be a positive integer"
	end
	local fragments, size, failed = {}, 0, false
	local framer = {}

	-- A framing error is terminal: discard this batch and all buffered data.
	-- Create a new framer for a new stream; never resume the rejected stream.
	function framer.feed(_, chunk)
		if failed then return nil, "framer is failed" end
		if type(chunk) ~= "string" then return nil, "expected a byte string" end
		local lines, start = {}, 1
		while start <= #chunk do
			local newline = chunk:find("\n", start, true)
			local last = (newline or (#chunk + 1)) - 1
			local length = last - start + 1
			if size + length > limit then
				fragments, size, failed = {}, 0, true
				return nil, "line exceeds maximum length"
			end
			if length > 0 then
				fragments[#fragments + 1] = chunk:sub(start, last)
				size = size + length
			end
			if not newline then break end
			lines[#lines + 1] = table.concat(fragments)
			fragments, size = {}, 0
			start = newline + 1
		end
		return lines
	end

	-- Call on EOF: a final unterminated line is not a protocol message.
	function framer.finish(_)
		if failed then return nil, "framer is failed" end
		if size > 0 then
			fragments, size, failed = {}, 0, true
			return nil, "unterminated line"
		end
		return true
	end
	return framer
end

return M
