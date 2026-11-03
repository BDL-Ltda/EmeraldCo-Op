-- The virtual-link relay (issue #81) with a fake network and mailbox.
local h = require("helpers")
local protocol = require("protocol")
local vl = require("virtuallink")
local tests = {}

local function setup(selfId)
	local t = { net = {}, rom = {}, logs = {}, netOk = true, romOk = true }
	t.link = vl.new(selfId or "ana", {
		sendLink = function(message)
			if not t.netOk then return false end
			assert(not protocol.check(message), "invalid trade_link")
			t.net[#t.net + 1] = message
			return true
		end,
		toRom = function(bytes)
			if not t.romOk then return false end
			t.rom[#t.rom + 1] = bytes
			return true
		end,
		log = function(line) t.logs[#t.logs + 1] = line end,
	})
	function t.message(m) t.link.onEvent("message", m) end
	function t.peer(seq, bytes, from, target)
		t.message({ v = 2, type = "trade_link", playerId = from or "bea", targetId = target or "ana",
			seq = seq, data = protocol.toHex(bytes) })
	end
	return t
end

local function started(selfId)
	local t = setup(selfId)
	assert(t.link.start("bea"))
	t.link.update()
	t.rom = {}
	return t
end

tests["roles come from the player IDs and START carries the partner ID"] = function()
	h.eq(vl.role("ana", "bea"), 0)
	h.eq(vl.role("bea", "ana"), 1)
	h.eq(vl.startPacket("bea", "ana"), string.char(vl.START, 1, 3) .. "ana")
	local t = setup()
	assert(t.link.start("bea"))
	t.link.update()
	h.eq(#t.rom, 1)
	h.eq(t.rom[1], string.char(vl.START, 0, 3) .. "bea")
	h.eq(t.link.isActive(), true)
	h.eq(t.link.partner(), "bea")
end

tests["start refuses invalid partners and a second session"] = function()
	local t = setup()
	local function refused(ok, err)
		h.eq(ok, false)
		assert(type(err) == "string" and #err > 0, "expected a reason")
	end
	refused(t.link.start("bad id"))
	refused(t.link.start("ana"))
	assert(t.link.start("bea"))
	refused(t.link.start("cid"))
end

tests["ROM peer packets go to the partner in sequence, controls never"] = function()
	local t = started()
	t.link.onRomMessage(string.char(vl.HELLO, 0, 0xAB))
	t.link.onRomMessage(string.char(vl.START, 1, 1) .. "x")
	t.link.onRomMessage(string.char(vl.CANCEL, 1))
	t.link.onRomMessage(string.char(vl.KEEPALIVE))
	t.link.update()
	h.eq(#t.net, 2)
	h.same(t.net[1], { v = 2, type = "trade_link", playerId = "ana", targetId = "bea", seq = 0, data = "0100ab" })
	h.eq(t.net[2].seq, 1)
	h.eq(t.net[2].data, "09")
end

tests["a throttled network keeps packets and their sequence numbers"] = function()
	local t = started()
	t.netOk = false
	t.link.onRomMessage(string.char(vl.BLOCK, 1, 2, 3))
	t.link.onRomMessage(string.char(vl.BARRIER, 1))
	t.link.update()
	h.eq(#t.net, 0)
	t.netOk = true
	t.link.update()
	h.eq(#t.net, 2)
	h.eq(t.net[1].seq, 0)
	h.eq(t.net[1].data, "02010203")
	h.eq(t.net[2].seq, 1)
end

tests["nothing is relayed outside a session"] = function()
	local t = setup()
	t.link.onRomMessage(string.char(vl.BLOCK, 1))
	t.peer(0, string.char(vl.BLOCK, 1))
	t.link.update()
	h.eq(#t.net, 0)
	h.eq(#t.rom, 0)
end

tests["only the partner's packets for us reach the ROM"] = function()
	local t = started()
	t.peer(7, string.char(vl.BLOCK, 1), "cid")
	t.peer(8, string.char(vl.BLOCK, 2), "bea", "cid")
	t.peer(5, string.char(vl.HELLO, 0, 1))
	t.peer(6, string.char(vl.BLOCK, 9, 9))
	t.link.update()
	h.eq(#t.rom, 2)
	h.eq(t.rom[1], string.char(vl.HELLO, 0, 1))
	h.eq(t.rom[2], string.char(vl.BLOCK, 9, 9))
end

tests["a partner can't send our ROM its own controls"] = function()
	local t = started()
	t.peer(1, string.char(vl.START, 0, 1) .. "x")
	t.peer(2, string.char(vl.CANCEL, 1))
	t.peer(3, string.char(vl.END, 0))
	t.peer(4, "")
	t.peer(5, string.char(vl.ABORT))
	t.link.update()
	h.eq(#t.rom, 1)
	h.eq(t.rom[1], string.char(vl.ABORT))
end

tests["a gap in the partner's sequence cancels and drops the rest"] = function()
	local t = started()
	t.peer(10, string.char(vl.KEEPALIVE))
	t.peer(12, string.char(vl.BLOCK, 1))
	t.peer(13, string.char(vl.BLOCK, 2))
	t.link.update()
	h.eq(#t.rom, 1)
	h.eq(t.rom[1], string.char(vl.CANCEL, vl.CANCEL_BROKEN))
	-- The session stays open until the ROM's END: its ABORT still goes out.
	t.link.onRomMessage(string.char(vl.ABORT))
	h.eq(t.link.onRomMessage(string.char(vl.END, vl.END_CANCELED)), vl.END_CANCELED)
	t.link.update()
	h.eq(t.link.isActive(), false)
	h.eq(#t.net, 1)
	h.eq(t.net[1].data, "07")
end

tests["packets from an earlier session are dropped"] = function()
	local t = setup()
	t.peer(4, string.char(vl.ABORT)) -- Late, from a session that already ended here.
	assert(t.link.start("bea"))
	t.link.update()
	t.rom = {}
	t.peer(4, string.char(vl.ABORT))
	t.peer(5, string.char(vl.HELLO, 0))
	t.link.update()
	h.eq(#t.rom, 1)
	h.eq(t.rom[1], string.char(vl.HELLO, 0))
	-- A reconnected partner starts again at 0.
	t = started()
	t.peer(4, string.char(vl.KEEPALIVE))
	t.link.onRomMessage(string.char(vl.END, vl.END_DONE))
	t.message({ v = 2, type = "leave", playerId = "bea", reason = "disconnected" })
	t.message({ v = 2, type = "join", playerId = "bea", trainerId = 1, gender = 0 })
	assert(t.link.start("bea"))
	t.link.update()
	t.rom = {}
	t.peer(0, string.char(vl.HELLO, 0))
	t.link.update()
	h.eq(#t.rom, 1)
end

tests["the partner leaving cancels at once; others leaving doesn't"] = function()
	local t = started()
	t.message({ v = 2, type = "leave", playerId = "cid", reason = "disconnected" })
	t.link.update()
	h.eq(#t.rom, 0)
	t.message({ v = 2, type = "leave", playerId = "bea", reason = "timeout" })
	t.message({ v = 2, type = "leave", playerId = "bea", reason = "timeout" })
	t.link.update()
	h.eq(#t.rom, 1)
	h.eq(t.rom[1], string.char(vl.CANCEL, vl.CANCEL_LEFT))
end

tests["a full mailbox is retried; overflowing queues cancel"] = function()
	local t = started()
	t.romOk = false
	for seq = 0, vl.MAX_QUEUED do t.peer(seq, string.char(vl.KEEPALIVE)) end
	t.romOk = true
	t.link.update()
	h.eq(#t.rom, 1)
	h.eq(t.rom[1], string.char(vl.CANCEL, vl.CANCEL_BROKEN))

	t = started()
	t.netOk = false
	for _ = 0, vl.MAX_QUEUED do t.link.onRomMessage(string.char(vl.KEEPALIVE)) end
	t.link.update()
	h.eq(t.rom[1], string.char(vl.CANCEL, vl.CANCEL_BROKEN))
end

tests["losing the socket ends the session; a new connection restarts sequences"] = function()
	local t = started()
	t.link.onRomMessage(string.char(vl.KEEPALIVE))
	t.link.update()
	h.eq(t.net[1].seq, 0)
	t.link.onRomMessage(string.char(vl.KEEPALIVE))
	t.link.onEvent("status", "Retrying")
	t.link.update()
	h.eq(t.link.isActive(), false)
	h.eq(#t.net, 1)
	t.message({ v = 2, type = "welcome", players = {} })
	assert(t.link.start("bea"))
	t.link.onRomMessage(string.char(vl.KEEPALIVE))
	t.link.update()
	h.eq(t.net[2].seq, 0)
	t.link.reset()
	h.eq(t.link.isActive(), false)
	h.eq(t.link.partner(), nil)
end

tests["the debug trigger starts one session once the partner is online"] = function()
	local t = setup()
	local trigger = vl.newDebugTrigger(t.link, "bea")
	trigger.update(0)
	h.eq(t.link.isActive(), false)
	trigger.onEvent("message", { v = 2, type = "welcome", players = { { playerId = "cid" } } })
	trigger.update(10)
	h.eq(t.link.isActive(), false)
	trigger.onEvent("message", { v = 2, type = "join", playerId = "bea" })
	trigger.update(20)
	h.eq(t.link.isActive(), true)
	-- Refused outside the free overworld: tried again after START_RETRY_MS.
	h.eq(t.link.onRomMessage(string.char(vl.END, vl.END_REFUSED)), vl.END_REFUSED)
	trigger.onEnd(vl.END_REFUSED)
	trigger.update(30)
	trigger.update(30 + vl.START_RETRY_MS - 1)
	h.eq(t.link.isActive(), false)
	trigger.update(30 + vl.START_RETRY_MS)
	h.eq(t.link.isActive(), true)
	-- A session that ran (done or canceled) isn't started again.
	t.link.onRomMessage(string.char(vl.END, vl.END_CANCELED))
	trigger.onEnd(vl.END_CANCELED)
	trigger.update(100000)
	h.eq(t.link.isActive(), false)
end

tests["the debug trigger waits while the partner is offline"] = function()
	local t = setup()
	local trigger = vl.newDebugTrigger(t.link, "bea")
	trigger.onEvent("message", { v = 2, type = "welcome", players = { { playerId = "bea" } } })
	trigger.onEvent("message", { v = 2, type = "leave", playerId = "bea", reason = "disconnected" })
	trigger.update(0)
	h.eq(t.link.isActive(), false)
	trigger.onEvent("message", { v = 2, type = "welcome", players = { { playerId = "bea" } } })
	trigger.update(1)
	h.eq(t.link.isActive(), true)
end

return tests
