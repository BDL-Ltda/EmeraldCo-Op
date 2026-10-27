-- Tests for client/lib/protocol.lua: message builders and server message validation.
local protocol, json, h = require("protocol"), require("json"), require("helpers")
local tests = {}

local function line(fields)
	local message = { v = 2 }
	for k, v in pairs(fields) do message[k] = v end
	return assert(json.encode(json.object(message)))
end

local function rejected(text, wantReason)
	local m, err = protocol.decode(text)
	h.eq(m, nil)
	assert(type(err) == "string" and err:find(wantReason, 1, true), "got error " .. tostring(err))
end

tests["every documented server message decodes"] = function()
	local file = assert(io.open("docs/protocol.md", "r"))
	local seen = {}
	local inJSON = false
	for text in file:lines() do
		if text == "```json" then
			inJSON = true
		elseif text == "```" then
			inJSON = false
		elseif inJSON and text:match("%S") then
			local m, err = protocol.decode(text)
			assert(m, err)
			seen[m.type] = true
		end
	end
	file:close()
	for _, kind in ipairs({ "welcome", "join", "presence", "leave", "pong", "error", "trade_available",
		"trade_invite", "trade_accept", "trade_decline", "trade_cancel", "trade_link", "trade_confirm" }) do
		assert(seen[kind], "no documented example for " .. kind)
	end
end

tests["a welcome with presence is validated"] = function()
	local m = assert(protocol.decode('{"v":2,"type":"welcome","players":[{"playerId":"leo","trainerId":12345,'
		.. '"gender":1,"presence":{"mapGroup":0,"mapNum":9,"x":7,"y":5,"facing":1,"visible":true}}]}'))
	h.eq(m.players[1].presence.x, 7)
	rejected('{"v":2,"type":"welcome","players":[{"playerId":"leo","trainerId":1,"gender":1,'
		.. '"presence":{"mapGroup":0,"mapNum":9,"x":7,"y":5,"facing":5,"visible":true}}]}',
		"players[0].presence.facing must be 1-4")
	rejected('{"v":2,"type":"welcome","players":[{"playerId":"a","trainerId":1,"gender":0},'
		.. '{"playerId":"a","trainerId":2,"gender":0}]}', "players[1].playerId is listed twice")
	rejected('{"v":2,"type":"welcome","players":{}}', "players must be an array")
	rejected('{"v":2,"type":"welcome","players":null}', "players must be an array")
	local five = {}
	for i = 1, 5 do five[i] = json.object({ playerId = "p" .. i, trainerId = i, gender = 0 }) end
	rejected(line({ type = "welcome", players = json.array(five) }), "more than 4 entries")
end

tests["field rules are enforced"] = function()
	local presence = '{"v":2,"type":"presence","playerId":"leo","mapGroup":0,"mapNum":9,"x":8,"y":5,'
	assert(protocol.decode(presence .. '"facing":4,"visible":true}'))
	rejected(presence .. '"facing":0,"visible":true}', "facing must be 1-4")
	rejected(presence .. '"facing":4,"visible":1}', "visible must be a boolean")
	rejected(presence .. '"facing":4}', "visible must be a boolean")
	rejected('{"v":2,"type":"presence","playerId":"leo","mapGroup":256,"mapNum":9,"x":8,"y":5,"facing":4,'
		.. '"visible":true}', "mapGroup must be 0-255")
	rejected('{"v":2,"type":"presence","playerId":"leo","mapGroup":0,"mapNum":9,"x":32768,"y":5,"facing":4,'
		.. '"visible":true}', "x must be")
	rejected('{"v":2,"type":"presence","playerId":"bad id","mapGroup":0,"mapNum":9,"x":8,"y":5,"facing":4,'
		.. '"visible":true}', "playerId may only contain")
	rejected('{"v":2,"type":"join","playerId":"davi","trainerId":4294967296,"gender":0}', "trainerId must be")
	rejected('{"v":2,"type":"join","playerId":"davi","trainerId":1,"gender":2}', "gender must be 0 or 1")
	rejected('{"v":2,"type":"join","playerId":"","trainerId":1,"gender":0}', "playerId must be 1-16")
	rejected('{"v":2,"type":"leave","playerId":"davi","reason":"bored"}', "reason is not a known reason")
	rejected('{"v":2,"type":"pong","t":-1}', "t must be")
	rejected('{"v":2,"type":"pong","t":"1"}', "t must be")
	rejected('{"v":2,"type":"error","code":"nope","message":""}', "code is not a known code")
	rejected('{"v":2,"type":"error","code":"bad_key","message":"a\\u0007b"}', "control character")
	rejected('{"v":2,"type":"error","code":"bad_key","message":"\\u0085"}', "control character")
	rejected(line({ type = "error", code = "bad_key", message = string.rep("x", 257) }), "0-256 characters")
	assert(protocol.decode(line({ type = "error", code = "bad_key", message = string.rep("é", 256) })))
end

tests["envelope problems are reported"] = function()
	local m, err, mismatch = protocol.decode('{"v":1,"type":"pong","t":1}')
	h.eq(m, nil)
	h.eq(mismatch, true)
	assert(err:find("version"))
	h.eq(select(3, protocol.decode('{"type":"pong","t":1}')), nil)
	rejected('{"type":"pong","t":1}', "v is missing")
	rejected('{"v":2,"type":3}', "type must be a string")
	rejected('[1]', "not a JSON object")
	rejected('{"v":2,', "not valid JSON")
	rejected('{"v":1.5,"type":"pong","t":1}', "not valid JSON")
end

tests["unknown types and fields are accepted"] = function()
	local m = assert(protocol.decode('{"v":2,"type":"emote","name":"wave"}'))
	h.eq(m.unknown, true)
	m = assert(protocol.decode('{"v":2,"type":"pong","t":5,"extra":"ignored"}'))
	h.eq(m.t, 5)
	h.eq(m.unknown, nil)
end

tests["client messages encode with the envelope first"] = function()
	h.eq(protocol.encode(protocol.hello("bernardo", "example-key", 2882400001, 0, "0.2.0")),
		'{"v":2,"type":"hello","clientVersion":"0.2.0","gender":0,"joinKey":"example-key",'
		.. '"playerId":"bernardo","trainerId":2882400001}')
	h.eq(protocol.encode(protocol.presence("leo", { mapGroup = 0, mapNum = 9, x = 8, y = 5, facing = 4,
		visible = true, trainerId = 1, gender = 1 })),
		'{"v":2,"type":"presence","facing":4,"mapGroup":0,"mapNum":9,"playerId":"leo","visible":true,"x":8,"y":5}')
	h.eq(protocol.encode(protocol.ping(1712345678901)), '{"v":2,"type":"ping","t":1712345678901}')
end

local POKEMON = string.rep("a5", protocol.POKEMON_BYTES)

-- Every trade builder, as the Go codec would encode it after relaying.
local function tradeMessages()
	return {
		protocol.tradeAvailable("leo", true),
		protocol.tradeAvailable("leo", false),
		protocol.tradeInvite("leo", "davi"),
		protocol.tradeAccept("davi", "leo"),
		protocol.tradeDecline("davi", "leo", "declined"),
		protocol.tradeDecline("davi", "leo", "timeout"),
		protocol.tradeDecline("davi", "leo", "busy"),
		protocol.tradeCancel("leo", "davi", "canceled"),
		protocol.tradeCancel("leo", "davi", "timeout"),
		protocol.tradeCancel("leo", "davi", "disconnected"),
		protocol.tradeLink("leo", "davi", 0, ""),
		protocol.tradeLink("0123456789abcdef", "fedcba9876543210", protocol.MAX_TRADE_SEQ,
			string.rep("ff", protocol.MAX_TRADE_LINK_BYTES)),
		protocol.tradeConfirm("leo", "davi", POKEMON),
	}
end

tests["trade messages round-trip through encode and decode"] = function()
	for _, message in ipairs(tradeMessages()) do
		h.eq(protocol.check(message), nil)
		local text = assert(protocol.encode(message))
		assert(text:match('^{"v":2,"type":"' .. message.type .. '",'), text)
		assert(#text <= 4096, "trade line over the limit")
		local decoded = assert(protocol.decode(text))
		h.eq(decoded.unknown, nil)
		for k, v in pairs(message) do h.eq(decoded[k], v) end
		h.eq(assert(protocol.encode(decoded)), text)
	end
	h.eq(protocol.encode(protocol.tradeLink("leo", "davi", 7, "00ff")),
		'{"v":2,"type":"trade_link","data":"00ff","playerId":"leo","seq":7,"targetId":"davi"}')
end

tests["trade field rules are enforced"] = function()
	local pair = '"playerId":"leo","targetId":"davi"'
	rejected('{"v":2,"type":"trade_available","playerId":"leo"}', "available must be a boolean")
	rejected('{"v":2,"type":"trade_available","playerId":"leo","available":1}', "available must be a boolean")
	rejected('{"v":2,"type":"trade_invite","playerId":"leo"}', "targetId must be 1-16")
	rejected('{"v":2,"type":"trade_invite","playerId":"leo","targetId":"a b"}', "targetId may only contain")
	rejected('{"v":2,"type":"trade_accept","targetId":"davi"}', "playerId must be 1-16")
	rejected('{"v":2,"type":"trade_decline",' .. pair .. ',"reason":"canceled"}', "reason is not a known reason")
	rejected('{"v":2,"type":"trade_decline",' .. pair .. '}', "reason is not a known reason")
	rejected('{"v":2,"type":"trade_cancel",' .. pair .. ',"reason":"busy"}', "reason is not a known reason")
	local link = '{"v":2,"type":"trade_link",' .. pair
	rejected(link .. ',"data":""}', "seq must be 0-4294967295")
	rejected(link .. ',"seq":-1,"data":""}', "seq must be")
	rejected(link .. ',"seq":4294967296,"data":""}', "seq must be")
	rejected(link .. ',"seq":0}', "data must be 0-1024 bytes of hex")
	rejected(link .. ',"seq":0,"data":"abc"}', "data must be 0-1024 bytes of hex")
	rejected(link .. ',"seq":0,"data":"AB"}', "data may only contain 0-9 and a-f")
	rejected(link .. ',"seq":0,"data":"' .. string.rep("00", 1025) .. '"}', "data must be 0-1024 bytes")
	local confirm = '{"v":2,"type":"trade_confirm",' .. pair
	rejected(confirm .. ',"pokemon":"' .. string.rep("00", 99) .. '"}', "pokemon must be 100 bytes of hex")
	rejected(confirm .. ',"pokemon":"' .. string.rep("00", 101) .. '"}', "pokemon must be 100 bytes of hex")
	rejected(confirm .. ',"pokemon":"' .. string.rep("0g", 100) .. '"}', "pokemon may only contain")
	h.eq(protocol.check(protocol.tradeLink("leo", "davi", 1.5, "")), "invalid trade_link: seq must be 0-4294967295")
	h.eq(protocol.check(protocol.ping(1)), "type ping has no field rules")
end

tests["hex helpers convert raw bytes"] = function()
	h.eq(protocol.toHex("\0\1\127\128\255"), "00017f80ff")
	h.eq(protocol.toHex(""), "")
	h.eq(protocol.fromHex("00017f80ff"), "\0\1\127\128\255")
	h.eq(protocol.fromHex(""), "")
	h.eq(protocol.fromHex("abc"), nil)
	h.eq(protocol.fromHex("AB"), nil)
	h.eq(protocol.fromHex("zz"), nil)
	local bytes = {}
	for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
	bytes = table.concat(bytes)
	h.eq(protocol.fromHex(protocol.toHex(bytes)), bytes)
end

tests["local values are checked before sending"] = function()
	h.eq(protocol.checkHelloIdentity("leo", "k", 0, 1, "0.2.0"), nil)
	h.eq(protocol.checkHelloIdentity("leo", "", 0, 1, "0.2.0"), "joinKey must be 1-64 characters")
	h.eq(protocol.checkHelloIdentity("leo", "k\n", 0, 1, "0.2.0"), "joinKey contains a control character")
	h.eq(protocol.checkHelloIdentity("leo", "k", -1, 1, "0.2.0"), "trainerId must be 0-4294967295")
	h.eq(protocol.checkPresenceState({ mapGroup = 0, mapNum = 9, x = -1, y = 3, facing = 2, visible = false }), nil)
	h.eq(protocol.checkPresenceState({ mapGroup = 0, mapNum = 9, x = 1, y = 3, facing = 0, visible = true }),
		"facing must be 1-4")
	h.eq(protocol.facingName(3), "WEST")
end

return tests
