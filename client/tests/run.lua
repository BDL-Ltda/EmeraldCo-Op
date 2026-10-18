-- Run from the repository root: lua5.4 client/tests/run.lua
-- Suites return { ["test name"] = function() ... end }; no test framework.
package.path = "client/lib/?.lua;client/?.lua;client/tests/?.lua;" .. package.path

local windows = package.config:sub(1, 1) == "\\"
local command = windows and 'dir /b /a-d "client\\tests\\*_test.lua" 2>nul'
	or "find client/tests -maxdepth 1 -type f -name '*_test.lua'"
local pipe = assert(io.popen(command, "r"), "cannot discover test suites")
local files = {}
for line in pipe:lines() do
	local name = line:match("([^/\\]+_test%.lua)$")
	if name then files[#files + 1] = "client/tests/" .. name end
end
assert(pipe:close(), "test discovery failed")
assert(#files > 0, "no test suites found")
table.sort(files)

local passed, failed = 0, 0
local function run(name, fn)
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		passed = passed + 1
		print("PASS " .. name)
	else
		failed = failed + 1
		print("FAIL " .. name .. "\n" .. tostring(err))
	end
end

for _, file in ipairs(files) do
	local ok, suite = pcall(dofile, file)
	if not ok then
		run(file .. " (load)", function() error(suite, 0) end)
	elseif suite == nil then
		-- Compatibility with pre-runner standalone suites (such as #11).
		-- Their assertions/os.exit already make a failure non-zero.
		run(file .. " (standalone suite)", function() end)
	elseif type(suite) ~= "table" or next(suite) == nil then
		run(file .. " (suite)", function() error("expected a non-empty test table", 0) end)
	else
		local names = {}
		for name in pairs(suite) do names[#names + 1] = name end
		table.sort(names, function(a, b) return tostring(a) < tostring(b) end)
		for _, name in ipairs(names) do
			run(file .. ": " .. tostring(name), function()
				assert(type(name) == "string" and type(suite[name]) == "function", "invalid test entry")
				suite[name]()
			end)
		end
	end
end

print(string.format("%d passed, %d failed (%d suites)", passed, failed, #files))
os.exit(failed > 0 and 1 or 0)
