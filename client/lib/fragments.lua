-- Multi-slot mailbox messages (mailbox layout v2).
--
-- A message of up to MAX_LENGTH bytes travels as consecutive COOP_MSG_FRAGMENT
-- slots. Each fragment payload is a 4-byte header followed by up to DATA_SIZE
-- data bytes (docs/memory-map.md#multi-slot-messages):
--   0x00 u8  type of the whole message (not NONE, not FRAGMENT)
--   0x01 u8  fragment index, 0 for the first
--   0x02 u16 total message length, little-endian
-- Mirrors CoopMailbox_SendMessage / CoopMailbox_Receive in src/coop/mailbox.c.
--
-- Pure: it only builds and reads byte strings. The sender gets a push function,
-- so it works with mailbox.lua (box:push) and with test doubles.

local mailbox = require("mailbox")

-- COOP_FRAGMENT_HEADER_SIZE, COOP_FRAGMENT_DATA_SIZE and COOP_MAILBOX_MESSAGE_MAX
-- in include/coop/mailbox.h.
local M = {
	HEADER_SIZE = 4,
	DATA_SIZE = 26,
	MAX_LENGTH = 1024,
	-- Messages a sender queues behind the one it is streaming.
	MAX_QUEUED = 16,
}

local HEADER_FORMAT = "<BBI2"

local function isMessageType(msgType)
	return math.type(msgType) == "integer" and msgType >= 1 and msgType <= 0xFF
		and msgType ~= mailbox.MSG.FRAGMENT
end

local function check(msgType, data)
	if not isMessageType(msgType) then
		return "message type must be an integer 1-255 other than FRAGMENT"
	end
	if type(data) ~= "string" or #data < 1 or #data > M.MAX_LENGTH then
		return string.format("message must be a string of 1-%d bytes", M.MAX_LENGTH)
	end
end

-- Returns the list of fragment payloads (byte strings) for one message, in
-- order, or nil and an error.
function M.split(msgType, data)
	local err = check(msgType, data)
	if err then return nil, err end
	local fragments = {}
	for offset = 1, #data, M.DATA_SIZE do
		fragments[#fragments + 1] = string.pack(HEADER_FORMAT, msgType, #fragments, #data)
			.. data:sub(offset, offset + M.DATA_SIZE - 1)
	end
	return fragments
end

-- Collects fragments into whole messages.
local Reassembler = {}
Reassembler.__index = Reassembler

function M.newReassembler()
	return setmetatable({ current = nil }, Reassembler)
end

-- Drops the message in progress, if any (disconnect, reset). Returns true if
-- there was one.
function Reassembler:reset()
	local had = self.current ~= nil
	self.current = nil
	return had
end

local function dropped(self, reason)
	self.current = nil
	return nil, nil, reason
end

-- Feeds one COOP_MSG_FRAGMENT payload. Returns type, data when it completes a
-- message; nil when more fragments are needed; nil, nil, reason when it
-- dropped an incomplete message or a bad fragment. A first fragment (index 0)
-- always starts a new message, dropping the one in progress.
function Reassembler:feed(payload)
	if type(payload) ~= "string" or #payload <= M.HEADER_SIZE then
		return dropped(self, "fragment shorter than its header plus one byte")
	end
	local msgType, index, length = string.unpack(HEADER_FORMAT, payload)
	local data = payload:sub(M.HEADER_SIZE + 1)
	local current = self.current
	local reason
	if index == 0 then
		reason = current and "incomplete message dropped: a new message started" or nil
		if not isMessageType(msgType) or length < 1 or length > M.MAX_LENGTH then
			return dropped(self, "first fragment has a bad type or length")
		end
		current = { type = msgType, length = length, nextIndex = 0, parts = {}, done = 0 }
		self.current = current
	elseif not current then
		return dropped(self, "fragment without a first fragment")
	elseif msgType ~= current.type or length ~= current.length or index ~= current.nextIndex then
		return dropped(self, "incomplete message dropped: fragment out of sequence")
	end
	if #data ~= math.min(M.DATA_SIZE, current.length - current.done) then
		return dropped(self, "incomplete message dropped: fragment has the wrong size")
	end
	current.parts[#current.parts + 1] = data
	current.done = current.done + #data
	current.nextIndex = current.nextIndex + 1
	if current.done < current.length then return nil, nil, reason end
	self.current = nil
	return current.type, table.concat(current.parts), reason
end

-- Streams queued messages into a ring, a fragment at a time, in order.
local Sender = {}
Sender.__index = Sender

function M.newSender()
	return setmetatable({ queue = {}, fragments = nil, nextFragment = 1 }, Sender)
end

-- Queues one message. Returns true, or false and a reason.
function Sender:send(msgType, data)
	local fragments, err = M.split(msgType, data)
	if not fragments then return false, err end
	if #self.queue >= M.MAX_QUEUED then return false, "too many queued mailbox messages" end
	self.queue[#self.queue + 1] = fragments
	return true
end

-- Drops every queued message, and the rest of the one being streamed: the
-- receiver drops its incomplete part when the next message starts.
function Sender:clear()
	self.queue, self.fragments, self.nextFragment = {}, nil, 1
end

function Sender:isIdle()
	return self.fragments == nil and #self.queue == 0
end

-- push(payload) -> ok, err: pushes one COOP_MSG_FRAGMENT payload. Pushes
-- fragments until push fails (ring full) or nothing is left; a failed fragment
-- is retried by the next pump. Returns the number pushed, and push's error.
function Sender:pump(push)
	local pushed = 0
	while true do
		if not self.fragments then
			if #self.queue == 0 then return pushed end
			self.fragments, self.nextFragment = table.remove(self.queue, 1), 1
		end
		local ok, err = push(self.fragments[self.nextFragment])
		if not ok then return pushed, err end
		pushed = pushed + 1
		self.nextFragment = self.nextFragment + 1
		if self.nextFragment > #self.fragments then self.fragments = nil end
	end
end

return M
