-- Run the actual entry point with an injected emulator, console and config.
local h = require("helpers")
local tests = {}

local function bridge(debugEnabled, validRom)
	local handlers, lines, logs = {}, {}, {}
	local state = { visible = false }
	local buffer = {}
	function buffer.clear() lines[#lines + 1] = "" end
	function buffer.setSize(_, cols, rows) assert(cols >= 80 and rows >= 4) end
	function buffer.moveCursor(_, x, y) h.eq(x, 0); buffer.row = y end
	function buffer.print(_, text)
		assert(not text:find("\n"), "native buffer must receive explicitly positioned rows")
		lines[#lines] = lines[#lines] .. text .. "\n"
	end
	local config = { SERVER_HOST = "localhost", SERVER_PORT = 8765, PLAYER_ID = "me",
		JOIN_KEY = "test-only-key", DEBUG = debugEnabled }
	local env = setmetatable({
		console = {
			createBuffer = function(_, name) h.eq(name, "Emerald Co-Op"); return buffer end,
			log = function(_, text) logs[#logs + 1] = text end,
			error = function(_, text) logs[#logs + 1] = text end,
		},
		callbacks = { add = function(_, kind, fn) handlers[kind] = fn end },
		emu = { checksum = function() return "fixture" end },
		socket = { ERRORS = { AGAIN = "again" }, tcp = function() error("must wait for game") end },
		loadfile = function(path)
			if path:match("config%.lua$") then return function() return config end end
			if path:match("addresses%.lua$") then return function() return {} end end
			error("unexpected file")
		end,
		require = function(name)
			if name == "romcheck" then return { verify = function() return validRom, "ROM fixture" end } end
			if name == "memory" then
				return { new = function() return { getPlayerState = function() return state end } end,
					format = function() return "[state] fixture" end }
			end
			return require(name)
		end,
	}, { __index = _G })
	assert(loadfile("client/bridge.lua", "t", env))()
	return { handlers = handlers, lines = lines, logs = logs }
end

tests["quiet bridge updates the real panel adapter and hides per-state logs"] = function()
	local b = bridge(false, true)
	b.handlers.keysRead()
	b.handlers.frame()
	assert(b.lines[#b.lines]:find("Me:    no position  hidden", 1, true))
	for _, line in ipairs(b.logs) do assert(not line:find("[state]", 1, true)) end
	local count = #b.lines
	for _ = 1, 40 do b.handlers.frame() end
	h.eq(#b.lines, count)
	b.handlers.shutdown()
	assert(b.lines[#b.lines]:find("waiting for game", 1, true))
end

tests["debug mode keeps state diagnostics"] = function()
	local b = bridge(true, true)
	b.handlers.keysRead()
	h.eq(b.logs[#b.logs], "[state] fixture")
end

tests["a mismatched ROM shows its status without reading game state"] = function()
	local b = bridge(false, false)
	b.handlers.keysRead()
	b.handlers.frame()
	assert(b.lines[#b.lines]:find("ROM not verified", 1, true))
end

return tests
