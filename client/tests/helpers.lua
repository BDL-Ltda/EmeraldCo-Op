local M = {}

function M.eq(got, want)
	assert(got == want, string.format("got %q, want %q", tostring(got), tostring(want)))
end

function M.same(got, want)
	if type(got) ~= "table" or type(want) ~= "table" then return M.eq(got, want) end
	for key, value in pairs(want) do M.same(got[key], value) end
	for key in pairs(got) do assert(want[key] ~= nil, "unexpected table key") end
end

function M.rejected(value, err)
	M.eq(value, nil)
	assert(type(err) == "string" and #err > 0, "expected an error string")
end

return M
