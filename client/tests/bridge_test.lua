-- Exercise the real entry point with injected mGBA adapters.
local h = require("helpers")
local mailbox = require("mailbox")
local tests = {}

local function bridge(validRom)
	local handlers, lines, logs, outbound, states = {}, {}, {}, {}, {}
	local buffer = {}
	function buffer.clear() lines[#lines + 1] = "" end
	function buffer.setSize(_, cols, rows) assert(cols >= 80 and rows >= 4) end
	function buffer.moveCursor(_, x, y) h.eq(x, 0); buffer.row = y end
	function buffer.print(_, text)
		assert(not text:find("\n"), "native buffer must receive explicitly positioned rows")
		lines[#lines] = lines[#lines] .. text .. "\n"
	end
	local config = { SERVER_HOST = "localhost", SERVER_PORT = 8765, PLAYER_ID = "me",
		JOIN_KEY = "test-only-key", DEBUG = false }
	local box = { connected = true }
	function box.check(_) return true, "mailbox ready" end
	function box:isLuaConnected() return self.connected end
	function box:setLuaConnected(value) self.connected = value end
	function box.pop(_)
		if #outbound == 0 then return nil end
		return table.remove(outbound, 1)
	end
	function box.push(_) return true end
	local client = {}
	function client.setPlayerState(_, state) states[#states + 1] = state end
	function client.update(_) end
	function client.close(_) end
	local env = setmetatable({
		console = {
			createBuffer = function(_, name) h.eq(name, "Emerald Co-Op"); return buffer end,
			log = function(_, text) logs[#logs + 1] = text end,
			error = function(_, text) logs[#logs + 1] = text end,
		},
		callbacks = { add = function(_, kind, fn) handlers[kind] = fn end },
		emu = { checksum = function() return "fixture" end },
		socket = { ERRORS = { AGAIN = "again" } },
		loadfile = function(path)
			if path:match("config%.lua$") then return function() return config end end
			if path:match("addresses%.lua$") then
				return function() return { symbols = { gCoopMailbox = { addr = 123 } } } end
			end
			error("unexpected file")
		end,
		require = function(name)
			if name == "romcheck" then return { verify = function() return validRom, "ROM fixture" end } end
			if name == "mailbox" then
				return setmetatable({ new = function() return box end }, { __index = mailbox })
			end
			if name == "net" then return { new = function(_, adapter) client.adapter = adapter; return client end } end
			return require(name)
		end,
	}, { __index = _G })
	assert(loadfile("client/bridge.lua", "t", env))()
	return { handlers = handlers, lines = lines, logs = logs, box = box,
		outbound = outbound, client = client, states = states }
end

tests["the bridge reads the mailbox every frame and updates its panel"] = function()
	local b = bridge(true)
	h.eq(b.box.connected, false)
	h.eq(b.handlers.keysRead, nil)
	b.outbound[1] = { type = mailbox.MSG.PRESENCE, payload = assert(mailbox.encodePresence({
		mapGroup = 0, mapNum = 9, x = 5, y = 3, facing = 1, visible = true,
		gender = 0, trainerId = 42,
	})) }
	b.handlers.frame()
	h.eq(b.states[1].trainerId, 42)
	assert(b.lines[#b.lines]:find("Me:    0:9  5,3  SOUTH  visible", 1, true))
	b.client.adapter.onEvent("message", { type = "welcome", players = {} }, 0)
	h.eq(b.box.connected, true)
	b.client.adapter.onEvent("status", "Retrying", 0)
	h.eq(b.box.connected, false)
	b.handlers.shutdown()
	assert(b.lines[#b.lines]:find("waiting for game", 1, true))
end

tests["a mismatched ROM never opens the mailbox"] = function()
	local b = bridge(false)
	h.eq(b.box.connected, true)
	b.handlers.frame()
	assert(b.lines[#b.lines]:find("ROM not verified", 1, true))
end

return tests
