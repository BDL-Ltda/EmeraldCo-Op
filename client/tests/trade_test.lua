local trade, protocol, h = require("trade"), require("protocol"), require("helpers")
local C, S, N = trade.COMMAND, trade.STATE, trade.NOTICE
local tests = {}

local function world(playerIds)
	local w = { now = 0, peers = {}, transit = {}, sent = {}, blocked = false, publishBlocked = false }
	for _, id in ipairs(playerIds or { "alice", "bob", "carol" }) do
		local peer = { token = 0, disconnected = false }
		peer.model = trade.new(id, {
			send = function(message)
				if w.blocked then return false end
				assert(not protocol.check(message))
				w.transit[#w.transit + 1] = message
				w.sent[#w.sent + 1] = message
				return true
			end,
			publish = function(bytes)
				if w.publishBlocked then return false end
				peer.snapshot = bytes
				return true
			end,
			disconnect = function() peer.disconnected = true end,
		})
		w.peers[id] = peer
	end
	function w.event(id, message) w.peers[id].model.onEvent("message", message, w.now) end
	for id in pairs(w.peers) do
		local players = {}
		for other in pairs(w.peers) do
			if other ~= id then players[#players + 1] = { playerId = other } end
		end
		w.event(id, { type = "welcome", players = players })
	end
	function w.command(id, command, target, token)
		local peer = w.peers[id]
		if command == C.OPEN then peer.token = peer.token + 1 end
		peer.model.command(string.pack("<BI2", command, token or peer.token) .. (target or ""), w.now)
	end
	function w.pump()
		for _ = 1, 20 do
			for _, peer in pairs(w.peers) do peer.model.update(w.now) end
			local messages = w.transit
			w.transit = {}
			if #messages == 0 then return end
			for _, message in ipairs(messages) do
				for id in pairs(w.peers) do
					if id ~= message.playerId then w.event(id, message) end
				end
			end
		end
		error("trade relay did not settle")
	end
	function w.state(id)
		local bytes = w.peers[id].model.snapshot()
		local token, state, notice, count = string.unpack("<I2BBB", bytes)
		local ids = {}
		for i = 0, count - 1 do
			ids[#ids + 1] = bytes:sub(22 + i * 16, 37 + i * 16):gsub("%z+$", "")
		end
		return state, notice, ids, token
	end
	function w.waiting(...)
		for _, id in ipairs({ ... }) do w.command(id, C.OPEN) end
		w.pump()
	end
	function w.expect(id, state, notice)
		local actual, why = w.state(id)
		h.eq(actual, state)
		if notice then h.eq(why, notice) end
	end
	return w
end

tests["only waiting peers appear, independent of presence or town"] = function()
	local w = world()
	w.waiting("alice", "bob")
	local _, _, ids = w.state("alice")
	h.same(ids, { "bob" })
	w.event("alice", { type = "presence", playerId = "bob", mapGroup = 99, visible = false })
	local _, _, after = w.state("alice")
	h.same(after, ids)
	w.command("bob", C.CANCEL)
	w.pump()
	local _, _, empty = w.state("alice")
	h.eq(#empty, 0)
	w.expect("bob", S.CLOSED)
end

tests["accept reaches the same session handoff on exactly two peers"] = function()
	local w = world()
	w.waiting("alice", "bob", "carol")
	w.command("alice", C.INVITE, "bob")
	w.pump()
	w.expect("alice", S.INVITING)
	w.expect("bob", S.INVITED)
	w.expect("carol", S.WAITING)
	local _, _, ids = w.state("carol")
	h.eq(#ids, 0) -- Both ends of an invitation are busy.
	w.command("bob", C.ACCEPT)
	w.pump()
	w.expect("alice", S.READY)
	w.expect("bob", S.READY)
	h.same(w.peers.alice.model.getSession(), { partnerId = "bob", initiator = true })
	h.same(w.peers.bob.model.getSession(), { partnerId = "alice", initiator = false })
	assert(not w.peers.carol.model.getSession())
	w.command("bob", C.CANCEL)
	w.pump()
	w.expect("bob", S.CLOSED)
	w.expect("alice", S.WAITING, N.CANCELED)
end

tests["decline and B notify the inviter and return cleanly"] = function()
	local w = world()
	w.waiting("alice", "bob")
	w.command("alice", C.INVITE, "bob")
	w.pump()
	w.command("bob", C.DECLINE)
	w.pump()
	w.expect("alice", S.WAITING, N.DECLINED)
	w.expect("bob", S.WAITING)
	w.command("alice", C.INVITE, "bob")
	w.pump()
	w.command("alice", C.CANCEL)
	w.pump()
	w.expect("alice", S.CLOSED)
	w.expect("bob", S.WAITING, N.CANCELED)
end

tests["30 seconds expires both sides and ignores a late acceptance"] = function()
	local w = world()
	w.waiting("alice", "bob")
	w.command("alice", C.INVITE, "bob")
	w.pump()
	w.now = 29999
	w.pump()
	w.expect("alice", S.INVITING)
	w.expect("bob", S.INVITED)
	w.now = 30000
	w.command("bob", C.ACCEPT) -- Deadline is checked before input, too.
	w.pump()
	w.expect("alice", S.WAITING, N.TIMEOUT)
	w.expect("bob", S.WAITING, N.TIMEOUT)
	w.event("alice", protocol.tradeAccept("bob", "alice"))
	w.expect("alice", S.WAITING)
end

tests["only the selected known target can accept, decline or cancel"] = function()
	local w = world()
	w.waiting("alice", "bob", "carol")
	w.command("alice", C.INVITE, "bob")
	w.pump()
	w.event("alice", protocol.tradeAccept("carol", "alice"))
	w.event("alice", protocol.tradeDecline("bob", "carol", "declined"))
	w.event("alice", protocol.tradeCancel("stranger", "alice", "canceled"))
	w.expect("alice", S.INVITING)
	w.event("bob", protocol.tradeInvite("carol", "bob"))
	w.pump()
	w.expect("bob", S.INVITED)
	w.expect("alice", S.INVITING)
end

tests["crossing invitations use a deterministic initiator"] = function()
	for _, ids in ipairs({ { "alice", "bob" }, { "z", "a" } }) do
		local w = world(ids)
		w.waiting(table.unpack(ids))
		w.command(ids[1], C.INVITE, ids[2])
		w.command(ids[2], C.INVITE, ids[1])
		w.pump()
		table.sort(ids)
		w.expect(ids[1], S.INVITING)
		w.expect(ids[2], S.INVITED)
		w.command(ids[2], C.ACCEPT)
		w.pump()
		w.expect(ids[1], S.READY)
		w.expect(ids[2], S.READY)
	end
end

tests["leave or replacement removes a waiting peer and clears an invitation"] = function()
	for _, kind in ipairs({ "leave", "join" }) do
		local w = world()
		w.waiting("alice", "bob")
		w.command("alice", C.INVITE, "bob")
		w.pump()
		w.event("alice", { type = kind, playerId = "bob" })
		w.expect("alice", S.WAITING, N.DISCONNECTED)
		local _, _, ids = w.state("alice")
		h.eq(#ids, 0)
	end
end

tests["disconnect and reconnect require a new attendant entry"] = function()
	local w = world()
	w.waiting("alice", "bob")
	w.peers.alice.model.onEvent("status", "Retrying", w.now)
	w.expect("alice", S.CLOSED, N.DISCONNECTED)
	w.event("alice", { type = "welcome", players = { { playerId = "bob" } } })
	w.command("alice", C.INVITE, "bob")
	w.expect("alice", S.CLOSED)
	w.command("alice", C.OPEN)
	w.expect("alice", S.WAITING)
end

tests["new joins get an existing waiting advertisement"] = function()
	local w = world()
	w.waiting("alice")
	w.event("bob", { type = "welcome", players = { { playerId = "alice" } } })
	w.event("alice", { type = "join", playerId = "bob" })
	w.pump()
	w.command("bob", C.OPEN)
	local _, _, ids = w.state("bob")
	h.same(ids, { "alice" })
end

tests["invalid commands, stale tokens, unavailable peers and strangers are ignored"] = function()
	local w = world()
	w.waiting("alice")
	for _, bytes in ipairs({ "", "\1", "\2\1", string.pack("<BI2", C.INVITE, 1) .. "bad!" }) do
		w.peers.alice.model.command(bytes, 0)
	end
	w.command("alice", C.INVITE, "bob")
	w.command("alice", C.INVITE, "stranger")
	w.command("alice", C.CANCEL, nil, 999)
	w.event("alice", protocol.tradeAvailable("stranger", true))
	w.event("alice", protocol.tradeInvite("stranger", "alice"))
	w.expect("alice", S.WAITING)
	local _, _, ids = w.state("alice")
	h.eq(#ids, 0)
end

tests["backpressure retains controls and publishes the latest snapshot"] = function()
	local w = world()
	w.blocked, w.publishBlocked = true, true
	w.waiting("alice")
	w.command("alice", C.CANCEL)
	w.pump()
	h.eq(#w.sent, 0)
	assert(not w.peers.alice.snapshot)
	w.blocked, w.publishBlocked = false, false
	w.pump()
	h.eq(w.sent[1].available, true)
	h.eq(w.sent[2].available, false)
	h.eq(w.peers.alice.snapshot:byte(3), S.CLOSED)
end

tests["a flooded blocked socket fails closed with bounded memory"] = function()
	local w = world()
	w.blocked = true
	for _ = 1, trade.MAX_QUEUED + 1 do
		w.event("alice", protocol.tradeInvite("bob", "alice"))
	end
	w.pump()
	assert(w.peers.alice.disconnected)
	w.expect("alice", S.CLOSED)
end

tests["an old accept cannot become the acceptance of a later invitation"] = function()
	local w = world()
	w.waiting("alice", "bob")
	w.command("alice", C.INVITE, "bob")
	w.pump()
	w.command("bob", C.ACCEPT)
	w.peers.bob.model.update(w.now) -- Hold this accept in the simulated network.
	w.now = 30000
	w.peers.alice.model.update(w.now)
	w.expect("alice", S.WAITING, N.TIMEOUT)
	w.command("alice", C.OPEN)
	w.event("alice", protocol.tradeAvailable("bob", true)) -- Stale advertisement.
	w.command("alice", C.INVITE, "bob")
	w.expect("alice", S.WAITING)
	w.pump() -- Old accept, cancel and terminal acknowledgment drain in order.
	w.expect("alice", S.WAITING)
	w.expect("bob", S.WAITING)
	w.command("alice", C.INVITE, "bob")
	w.pump()
	w.expect("alice", S.INVITING)
	w.expect("bob", S.INVITED)
	assert(not w.peers.alice.model.getSession())
	w.command("bob", C.ACCEPT)
	w.pump()
	w.expect("alice", S.READY)
end

tests["a duplicate invite from the partner does not reject their active invitation"] = function()
	local w = world()
	w.waiting("alice", "bob")
	w.command("alice", C.INVITE, "bob")
	w.pump()
	w.event("bob", protocol.tradeInvite("alice", "bob"))
	w.pump()
	w.expect("alice", S.INVITING)
	w.expect("bob", S.INVITED)
end

return tests
