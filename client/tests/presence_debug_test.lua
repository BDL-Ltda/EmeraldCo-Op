local h = require("helpers")
local mailbox = require("mailbox")
local tests = {}

local function setup(validRom, hasSymbol)
	local handlers, logs, errors, queue = {}, {}, {}, {}
	local reads, wrappers = 0, 0
	local ready, reason = true, "ready"
	local box = {}
	function box.check() reads = reads + 1; return ready, reason end
	function box.pop() return table.remove(queue, 1) end
	local env = setmetatable({
		console = {
			log = function(_, line) logs[#logs + 1] = line end,
			error = function(_, line) errors[#errors + 1] = line end,
		},
		callbacks = { add = function(_, kind, fn) handlers[kind] = fn end },
		emu = { checksum = function() return "\x01\x02\x03\x04" end },
		loadfile = function(path)
			assert(path:match("addresses%.lua$"), "debug script must not load private config")
			return function() return {
				romCrc32 = validRom and "01020304" or "ffffffff",
				symbols = hasSymbol and { gCoopMailbox = { addr = 0 } } or {},
			} end
		end,
		require = function(name)
			if name == "mailbox" then
				return { MSG = mailbox.MSG, decodePresence = mailbox.decodePresence,
					new = function() wrappers = wrappers + 1; return box end }
			end
			return require(name)
		end,
	}, { __index = _G })
	assert(loadfile("client/debug/presence.lua", "t", env))()
	return { handlers = handlers, logs = logs, errors = errors, queue = queue,
		reads = function() return reads, wrappers end,
		readiness = function(value) ready, reason = value, "mailbox not ready" end }
end

tests["debug reader refuses mismatched ROMs before touching memory"] = function()
	local w = setup(false, true)
	w.handlers.frame()
	h.eq(w.reads(), 0)
	local _, wrappers = w.reads()
	h.eq(wrappers, 0)
	assert(w.errors[1]:find("ROM mismatch", 1, true))
end

tests["debug reader reports missing generated mailbox symbol"] = function()
	local w = setup(true, false)
	w.handlers.frame()
	h.eq(w.reads(), 0)
	assert(w.errors[1]:find("gCoopMailbox missing", 1, true))
end

tests["debug reader decodes messages then reports quiet idle intervals"] = function()
	local w = setup(true, true)
	local presence = { mapGroup = 0, mapNum = 9, x = 7, y = -1, facing = 4,
		visible = true, gender = 1, trainerId = 0xDEADBEEF }
	w.queue[1] = { type = mailbox.MSG.PRESENCE, payload = assert(mailbox.encodePresence(presence)) }
	presence.visible = false
	w.queue[2] = { type = mailbox.MSG.PRESENCE, payload = assert(mailbox.encodePresence(presence)) }
	for _ = 1, 600 do w.handlers.frame() end
	h.eq(#w.errors, 0)
	h.eq(#w.queue, 0)
	assert(w.logs[2]:find("0:9 7,-1 EAST visible gender=1 trainerId=3735928559", 1, true))
	assert(w.logs[3]:find("EAST hidden", 1, true))
	assert(w.logs[#w.logs]:find("last 300 frames: 0 messages; total=2", 1, true))
end

tests["debug reader waits for initialized mailbox without repeated errors"] = function()
	local w = setup(true, true)
	w.readiness(false)
	for _ = 1, 10 do w.handlers.frame() end
	h.eq(#w.errors, 0)
	h.eq(#w.logs, 2)
	assert(w.logs[2]:find("waiting for mailbox initialization", 1, true))
	w.readiness(true)
	for _ = 1, 300 do w.handlers.frame() end
	assert(w.logs[#w.logs]:find("0 messages", 1, true))
end

tests["debug reader still reports persistent invalid headers"] = function()
	local w = setup(true, true)
	w.readiness(false)
	for _ = 1, 600 do w.handlers.frame() end
	h.eq(#w.errors, 1)
	assert(w.errors[1]:find("unavailable after 300 frames", 1, true))
	w.readiness(true)
	w.handlers.frame()
	w.readiness(false)
	for _ = 1, 300 do w.handlers.frame() end
	h.eq(#w.errors, 2)
end

tests["debug reader stops polling until a verified game starts again"] = function()
	local w = setup(true, true)
	w.handlers.frame()
	local count = w.reads()
	w.handlers.stop()
	w.handlers.frame()
	h.eq(w.reads(), count)
	w.handlers.start()
	w.handlers.frame()
	h.eq(w.reads(), count + 1)
	w.handlers.shutdown()
	w.handlers.frame()
	h.eq(w.reads(), count + 1)
end

return tests
