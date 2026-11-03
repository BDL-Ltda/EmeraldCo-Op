-- The real bridge.lua relaying virtual-link packets (issue #81) between the
-- mailbox and the network, with injected mGBA adapters.
local h = require("helpers")
local mailbox = require("mailbox")
local fragments = require("fragments")
local protocol = require("protocol")
local vl = require("virtuallink")
local tests = {}

local function bridge(partner)
	local handlers, outbound, pushed, sent = {}, {}, {}, {}
	local buffer = { clear = function() end, setSize = function() end, moveCursor = function() end,
		print = function() end }
	local config = { SERVER_HOST = "localhost", SERVER_PORT = 8765, PLAYER_ID = "ana",
		JOIN_KEY = "test-only-key", DEBUG = false, TRADE_LINK_PARTNER = partner }
	local box = { connected = false }
	function box.check() return true, "mailbox ready" end
	function box.isInboundEmpty() return true end
	function box.watchReset() return true end
	function box.wasReset() return false end
	function box:isLuaConnected() return self.connected end
	function box:setLuaConnected(value) self.connected = value end
	function box.pop() return table.remove(outbound, 1) end
	function box.push(_, msgType, payload)
		pushed[#pushed + 1] = { type = msgType, payload = payload }
		return true
	end
	local client = {}
	function client.setPlayerState() end
	function client.update() end
	function client.close() end
	function client.sendTradeLink(_, message)
		sent[#sent + 1] = message
		return true
	end
	local env = setmetatable({
		console = {
			createBuffer = function() return buffer end,
			log = function() end,
			error = function() end,
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
			if name == "romcheck" then return { verify = function() return true, "ROM fixture" end } end
			if name == "mailbox" then
				return setmetatable({ new = function() return box end }, { __index = mailbox })
			end
			if name == "net" then return { new = function(_, adapter) client.adapter = adapter; return client end } end
			return require(name)
		end,
	}, { __index = _G })
	assert(loadfile("client/bridge.lua", "t", env))()
	local b = { handlers = handlers, outbound = outbound, pushed = pushed, sent = sent, box = box }
	function b.event(kind, data) client.adapter.onEvent(kind, data, 0) end
	-- Complete multi-slot messages the bridge pushed into the inbound ring.
	function b.romMessages()
		local reassembler, messages = fragments.newReassembler(), {}
		for _, slot in ipairs(pushed) do
			if slot.type == mailbox.MSG.FRAGMENT then
				local msgType, data = reassembler:feed(slot.payload)
				if msgType then messages[#messages + 1] = { type = msgType, data = data } end
			end
		end
		return messages
	end
	-- A complete message from the ROM in the outbound ring.
	function b.fromRom(msgType, data)
		for _, payload in ipairs(assert(fragments.split(msgType, data))) do
			outbound[#outbound + 1] = { type = mailbox.MSG.FRAGMENT, payload = payload }
		end
	end
	return b
end

tests["the debug trigger starts the ROM session and packets flow both ways"] = function()
	local b = bridge("bea")
	b.event("message", { v = 2, type = "welcome", players = { { playerId = "bea", trainerId = 1, gender = 0 } } })
	b.handlers.frame()
	b.handlers.frame()
	local messages = b.romMessages()
	h.eq(#messages, 1)
	h.eq(messages[1].type, mailbox.MSG.LINK)
	h.eq(messages[1].data, string.char(vl.START, 0, 3) .. "bea")

	b.fromRom(mailbox.MSG.LINK, string.char(vl.HELLO, 0, 0x42))
	b.handlers.frame()
	h.eq(#b.sent, 1)
	h.same(b.sent[1], { v = 2, type = "trade_link", playerId = "ana", targetId = "bea", seq = 0, data = "010042" })

	b.event("message", { v = 2, type = "trade_link", playerId = "bea", targetId = "ana", seq = 3,
		data = protocol.toHex(string.char(vl.HELLO, 1, 0x43)) })
	b.handlers.frame()
	messages = b.romMessages()
	h.eq(#messages, 2)
	h.eq(messages[2].data, string.char(vl.HELLO, 1, 0x43))

	-- The partner leaving tells the ROM at once.
	b.event("message", { v = 2, type = "leave", playerId = "bea", reason = "disconnected" })
	b.handlers.frame()
	messages = b.romMessages()
	h.eq(messages[3].data, string.char(vl.CANCEL, vl.CANCEL_LEFT))
end

tests["without a debug partner no session starts and link data is still dropped"] = function()
	local b = bridge(nil)
	b.event("message", { v = 2, type = "welcome", players = { { playerId = "bea", trainerId = 1, gender = 0 } } })
	b.handlers.frame()
	b.event("message", { v = 2, type = "trade_link", playerId = "bea", targetId = "ana", seq = 0, data = "0100" })
	b.fromRom(mailbox.MSG.LINK, string.char(vl.BLOCK, 1))
	b.handlers.frame()
	h.eq(#b.romMessages(), 0)
	h.eq(#b.sent, 0)
end

return tests
