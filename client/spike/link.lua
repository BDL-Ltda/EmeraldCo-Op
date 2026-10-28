-- Opt-in issue #80 harness. Load link-a.lua / link-b.lua instead of bridge.lua.
-- Deliberately no reconnect or production session negotiation (#81/#83).
local DIR = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = DIR .. "../lib/?.lua;" .. package.path
local mailbox = require("mailbox")
local fragments = require("fragments")
local protocol = require("protocol")
local framing = require("framing")
local json = require("json")
local romcheck = require("romcheck")
local clocklib = require("netclock")

return function(id, peer, role, delayMs, fixtureParty)
	local config = assert(loadfile(DIR .. "../config.lua"))()
	local addresses = assert(loadfile(DIR .. "../addresses.lua"))()
	local box, sock, identity
	local pending, outbox, delayed = {}, "", {}
	local sender, receiver = fragments.newSender(), fragments.newReassembler()
	local decoder = framing.new()
	local clock = clocklib.new()
	local frames, now, lastPing, lastOffer = 0, 0, 0, -1000
	local seq, remoteSeq = 0, 0
	local joined, peerReady, started, stopped = false, false, false, false
	local function log(text) console:log("[link-spike] " .. text) end
	local function stop(reason, forget)
		if stopped then return end
		stopped = true
		if box and not forget then box:setLuaConnected(false) end
		if sock then sock:close() end
		console:error("[link-spike] stopped: " .. reason .. "; restart both test instances")
	end
	local function send(message)
		if message.type:match("^trade_") then
			local reason = protocol.check(message)
			if reason then stop(reason); return end
		end
		local line, err = json.encode(message)
		if not line then stop(err); return end
		if #outbox + #line > 32768 then stop("send queue full"); return end
		outbox = outbox .. line .. "\n"
	end
	local function flush()
		if outbox == "" or not sock then return end
		local n, err = sock:send(outbox)
		if n then outbox = outbox:sub(n + 1)
		elseif err ~= socket.ERRORS.AGAIN then stop("send failed") end
	end
	local function receiveMessage(m)
		if m.type == "welcome" then joined = true; log("joined as " .. id)
		elseif m.type == "error" then stop("server rejected connection: " .. m.code)
		elseif m.type == "leave" and m.playerId == peer then stop("partner left")
		elseif m.type == "trade_available" and m.playerId == peer then peerReady = m.available
		elseif m.type == "trade_link" and m.playerId == peer and m.targetId == id then
			if m.seq ~= remoteSeq + 1 then stop("partner sequence mismatch"); return end
			remoteSeq = m.seq
			local data = assert(protocol.fromHex(m.data))
			if #pending == 16 then stop("inbound queue full"); return end
			pending[#pending + 1] = data
		end
	end
	local function receive()
		for _ = 1, 8 do
			local data, err = sock:receive(4096)
			if not data then
				if err ~= socket.ERRORS.AGAIN then stop("receive failed") end
				return
			end
			if #data == 0 then stop("server closed connection"); return end
			local lines, frameError = decoder:feed(data)
			if not lines then stop(frameError); return end
			for _, line in ipairs(lines) do
				local m, decodeError = protocol.decode(line)
				if not m then stop(decodeError); return end
				receiveMessage(m)
				if stopped then return end
			end
		end
	end
	local function connect()
		sock = socket.tcp()
		local ok = sock:connect(config.SERVER_HOST, config.SERVER_PORT)
		if not ok then stop("cannot connect to configured server"); return end
		sock:add("received", receive)
		sock:add("error", function() stop("socket error") end)
		send(assert(protocol.hello(id, config.JOIN_KEY, identity.trainerId, identity.gender, "spike-80")))
		flush()
	end
	local function poll()
		if stopped then return end
		frames = frames + 1
		now = clock:tick(os.time())
		local ready = box:check()
		if not ready then return end
		-- No production bridge attaches: this script is the only Lua ring owner.
		box:setLuaConnected(true)
		for _ = 1, 15 do
			local message, err = box:pop()
			if err then stop(err); return end
			if not message then break end
			if message.type == mailbox.MSG.PRESENCE then
				local state = mailbox.decodePresence(message.payload)
				if state and state.visible then identity = state end
			elseif message.type == mailbox.MSG.FRAGMENT then
				local kind, data, dropped = receiver:feed(message.payload)
				if dropped then stop(dropped); return end
				if kind == 5 then
					if #delayed == 16 then stop("delay queue full"); return end
					delayed[#delayed + 1] = { at = now + delayMs, data = data }
				end
			elseif message.type == 6 and #message.payload == 3 then
				local stage, value = string.unpack("<I1I2", message.payload)
				log(string.format("frame %d stage %d state %d", frames, stage, value))
			end
		end
		if identity and not sock then connect() end
		if not sock or stopped then return end
		if joined then
			if not started and now - lastOffer >= 1000 then
				send(protocol.tradeAvailable(id, true))
				lastOffer = now
			end
			if peerReady and not started then
				assert(sender:send(5, string.char(0, role, fixtureParty and 1 or 0)))
				started = true
				log(string.format("start role %d; injected one-way delay %d ms", role, delayMs))
			end
			if started then
				while #pending > 0 do
					local ok = sender:send(5, pending[1])
					if not ok then break end
					table.remove(pending, 1)
				end
			end
			while delayed[1] and delayed[1].at <= now do
				seq = seq + 1
				send(protocol.tradeLink(id, peer, seq, protocol.toHex(table.remove(delayed, 1).data)))
			end
			if now - lastPing >= 5000 then send(protocol.ping(now)); lastPing = now end
		end
		local _, err = sender:pump(function(payload) return box:push(mailbox.MSG.FRAGMENT, payload) end)
		if err and err ~= "mailbox inbound ring full" then stop(err) end
		flush()
	end
	local ok, reason = romcheck.verify(addresses.romCrc32, emu:checksum())
	if not ok then console:error("[link-spike] " .. reason); return end
	box = mailbox.new(emu, addresses.symbols.gCoopMailbox.addr)
	log(reason .. "; experimental trade, disposable saves only")
	callbacks:add("frame", poll)
	-- A new ROM may already occupy RAM: never clear a flag at the old address.
	callbacks:add("start", function() stop("a game was loaded; reload the spike script", true) end)
	callbacks:add("stop", function() stop("script stopped") end)
	callbacks:add("shutdown", function() stop("emulator stopped") end)
end
