local debugview, h = require("debugview"), require("helpers")
local tests = {}

local function position(extra)
	local p = { mapGroup = 0, mapNum = 9, x = 5, y = 3, facing = 1, visible = true }
	for k, v in pairs(extra or {}) do p[k] = v end
	return p
end

local function message(view, kind, fields, now)
	local m = { type = kind }
	for k, v in pairs(fields or {}) do m[k] = v end
	view:onEvent("message", m, now or 0)
end

local function joined()
	local v = debugview.new("localhost", "me")
	v:setPlayerState(position())
	message(v, "welcome", { players = {
		{ playerId = "zoe", trainerId = 1, gender = 1, presence = position() },
		{ playerId = "amy", trainerId = 2, gender = 0 },
	} })
	return v
end

tests["welcome copies identities and positions and renders sorted players"] = function()
	local v = joined()
	h.eq(v.remotePlayers.zoe.trainerId, 1)
	h.eq(v.remotePlayers.zoe.gender, 1)
	h.eq(v.remotePlayers.zoe.lastUpdate, 0)
	local text = v:update(0)
	assert(text:find("Connected to localhost  as me", 1, true))
	assert(text:find("Me:    0:9  5,3  SOUTH  visible", 1, true))
	assert(text:find("Remote players: 2", 1, true))
	assert(text:find("amy", 1, true) < text:find("zoe", 1, true))
	assert(text:find("awaiting presence", 1, true))
	assert(text:find("same map", 1, true))
end

tests["presence updates keep identity and classify both map fields and visibility"] = function()
	local v = joined()
	local p = position({ playerId = "zoe", mapNum = 10, x = 7, y = 8, facing = 4, visible = false })
	message(v, "presence", p, 100)
	h.eq(v.remotePlayers.zoe.lastUpdate, 100)
	h.eq(v.remotePlayers.zoe.trainerId, 1)
	local text = v:update(100)
	assert(text:find("zoe  0:10  7,8  EAST  hidden  different map", 1, true))
	v:setPlayerState(position({ mapNum = 10 }))
	assert(v:update(350):find("hidden  same map", 1, true))
	message(v, "presence", position({ playerId = "zoe", mapGroup = 1, mapNum = 10 }), 400)
	assert(v:update(600):find("different map", 1, true))
end

tests["join replacement and leave discard old positions"] = function()
	local v = joined()
	message(v, "join", { playerId = "zoe", trainerId = 42, gender = 0 }, 1)
	h.eq(v.remotePlayers.zoe.trainerId, 42)
	h.eq(v.remotePlayers.zoe.mapNum, nil)
	message(v, "leave", { playerId = "amy", reason = "disconnect" }, 2)
	h.eq(v.remotePlayers.amy, nil)
	assert(v:update(2):find("Remote players: 1", 1, true))
end

tests["disconnection clears peers and latency and welcome replaces the snapshot"] = function()
	local v = joined()
	message(v, "pong", { t = 0 }, 42)
	assert(v:update(42):find("latency 42 ms", 1, true))
	v:onEvent("status", "Retrying", 43)
	h.eq(next(v.remotePlayers), nil)
	local text = v:update(300)
	assert(text:find("Retrying", 1, true))
	assert(not text:find("latency", 1, true))
	message(v, "presence", position({ playerId = "stale" }), 400)
	h.eq(next(v.remotePlayers), nil)
	message(v, "welcome", { players = {} }, 500)
	assert(v:update(550):find("Remote players: 0", 1, true))
end

tests["stale peers expire at 30 seconds even while pongs continue"] = function()
	local v = joined()
	v:update(0)
	message(v, "presence", position({ playerId = "zoe" }), 1000)
	message(v, "pong", { t = 29000 }, 29999)
	v:update(29999)
	assert(v.remotePlayers.amy)
	v:update(30000)
	h.eq(v.remotePlayers.amy, nil)
	assert(v.remotePlayers.zoe)
	v:update(31000)
	h.eq(v.remotePlayers.zoe, nil)
	message(v, "presence", position({ playerId = "zoe" }), 31001)
	assert(v.remotePlayers.zoe)
end

tests["unchanged peer activity refreshes expiry without redrawing"] = function()
	local v = joined()
	v:update(0)
	message(v, "presence", position({ playerId = "zoe" }), 10000)
	h.eq(v:update(10000), nil)
	v:update(30000)
	assert(v.remotePlayers.zoe)
	v:update(40000)
	h.eq(v.remotePlayers.zoe, nil)
end

tests["redraws coalesce to four per second with the latest state"] = function()
	local v = joined()
	v:update(0)
	for i = 1, 249 do
		message(v, "presence", position({ playerId = "zoe", x = i }), i)
		h.eq(v:update(i), nil)
	end
	assert(v:update(250):find("249,3", 1, true))
	h.eq(v:update(500), nil)
end

tests["no-position samples and unconfigured settings render safely"] = function()
	local v = debugview.new(nil, nil)
	v:setPlayerState({ visible = false })
	local text = v:update(0)
	assert(text:find("(unconfigured)", 1, true))
	assert(text:find("no position  hidden", 1, true))
	v:onEvent("status", "Network disabled", 1)
	assert(v:update(250):find("Network disabled", 1, true))
end

tests["state is copied and does not retain arbitrary message fields"] = function()
	local v = joined()
	local p = position({ playerId = "zoe", joinKey = "do-not-retain" })
	message(v, "presence", p, 10)
	p.x = 999
	h.eq(v.remotePlayers.zoe.x, 5)
	h.eq(v.remotePlayers.zoe.joinKey, nil)
	local localState = position()
	v:setPlayerState(localState)
	localState.x = 888
	assert(v:update(10):find("Me:    0:9  5,3", 1, true))
end

tests["peer table is bounded and never includes the local ID"] = function()
	local v = joined()
	for _, id in ipairs({ "me", "third", "fourth", "fifth" }) do
		message(v, "join", { playerId = id, trainerId = 1, gender = 0 })
	end
	h.eq(v.remotePlayers.me, nil)
	h.eq(v.remotePlayers.fifth, nil)
	assert(v:update(0):find("Remote players: 4", 1, true))
end

tests["forced shutdown draw does not prevent later frame updates"] = function()
	local v = joined()
	v:update(1000)
	v:onEvent("status", "Waiting for game", 1001)
	v:setPlayerState(nil)
	assert(v:update(1001, true):find("Remote players: 0", 1, true))
	message(v, "welcome", { players = {} }, 1002)
	assert(v:update(1251):find("Connected", 1, true))
end

return tests
