-- Serializer.lua
--
-- Everything about turning messages into bytes safe for the wire, and back:
--   1. Profile codec   - table <-> compact, compressed, addon-channel-safe string
--   2. Envelope codec  - the "||"-delimited message header + data
--   3. Chunking         - splitting a message across the 255-byte addon-message
--                         limit, and reassembling it on the far side.
--
-- Pipeline for the profile data field (LibSerialize is designed to pair with
-- LibDeflate exactly this way):
--   table --Serialize--> string --CompressDeflate--> bytes --EncodeForWoWAddonChannel--> safe string
--
-- The encoded string is guaranteed to contain no NULL byte (the only byte the
-- addon channel forbids); it MAY still contain "|" or ":", so all framing below
-- parses positionally with numeric-only header fields that cannot collide.

local _, ns = ...
local C = ns.Const
local Util = ns.Util

local Serializer = {}
ns.Serializer = Serializer

local LibSerialize = LibStub and LibStub("LibSerialize")
local LibDeflate = LibStub and LibStub("LibDeflate")

-- Profile data codec --------------------------------------------------------

--- Serialize+compress+encode an (opaque) profile data table into a wire-safe
-- string. Returns nil if the value cannot be serialized.
-- @param data table
-- @return string|nil
function Serializer.encodeProfile(data)
	if not LibSerialize or not LibDeflate then
		return nil
	end
	-- pcall guards against unexpected unserializable values rather than letting
	-- a single bad profile error out the calling path.
	local ok, serialized = pcall(function()
		return LibSerialize:Serialize(data)
	end)
	if not ok or not serialized then
		return nil
	end
	local compressed = LibDeflate:CompressDeflate(serialized)
	return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

--- Reverse of encodeProfile. Returns nil on any decode/integrity failure.
-- @param encoded string
-- @return table|nil
function Serializer.decodeProfile(encoded)
	if not LibSerialize or not LibDeflate then
		return nil
	end
	local compressed = LibDeflate:DecodeForWoWAddonChannel(encoded)
	if not compressed then
		return nil
	end
	local serialized = LibDeflate:DecompressDeflate(compressed)
	if not serialized then
		return nil
	end
	local ok, value = LibSerialize:Deserialize(serialized)
	if not ok then
		return nil
	end
	return value
end

-- Envelope codec ------------------------------------------------------------
--
-- Wire layout (see README "Message Structure"):
--   SENDER || SUBJECT || NAME-REALM || ADDON || ORIGIN-TIME || CONTENT-VERSION || DATA
-- DATA is always last so any "||" inside the encoded payload is preserved.

local MESSAGE_FIELDS = 7

--- Build the envelope string from a message table.
-- @param msg table { sender, subject, unitID, addon, originTime, contentVersion, data }
--   where `data` is the already-encoded profile string.
-- @return string
function Serializer.buildMessage(msg)
	return Util.join({
		msg.sender,
		msg.subject,
		msg.unitID,
		msg.addon,
		tostring(msg.originTime),
		msg.contentVersion,
		msg.data,
	})
end

--- Parse an envelope string back into a message table. Returns nil if the
-- field count is wrong.
-- @param str string
-- @return table|nil
function Serializer.parseMessage(str)
	local f = Util.split(str, C.SEPARATOR, MESSAGE_FIELDS)
	if #f < MESSAGE_FIELDS then
		return nil
	end
	return {
		sender = f[1],
		subject = f[2],
		unitID = f[3],
		addon = f[4],
		originTime = tonumber(f[5]),
		contentVersion = f[6],
		data = f[7],
	}
end

-- Chunking ------------------------------------------------------------------
--
-- Each chunk on the wire is: "MSGID:INDEX:TOTAL:PIECE". The three header fields
-- are integers (never contain ":"), so a positional split with maxFields=4
-- recovers PIECE intact even when it contains ":".

local CHUNK_HEADER_FIELDS = 4
local chunkCounter = 0 -- per-session id, unique together with the sender

--- Split a full message string into wire chunks (each <= ~255 bytes including
-- its header). Always returns at least one chunk.
-- @param message string
-- @return table A list of chunk strings ready to send.
function Serializer.chunk(message)
	chunkCounter = chunkCounter + 1
	local msgId = chunkCounter
	local size = C.CHUNK_SIZE
	local total = math.max(1, math.ceil(#message / size))
	local chunks = {}
	for i = 1, total do
		local piece = message:sub((i - 1) * size + 1, i * size)
		chunks[i] = string.format("%d:%d:%d:%s", msgId, i, total, piece)
	end
	return chunks
end

-- ChunkReassembler: buffers incoming chunks per (sender, msgId) until complete.
local ChunkReassembler = ns.Class("ChunkReassembler")
Serializer.ChunkReassembler = ChunkReassembler

function ChunkReassembler:init()
	self.buffers = {} -- [sender\031msgId] = { total, count, pieces = {}, time }
end

--- Feed one received chunk. Returns the fully reassembled message string once
-- the final missing chunk arrives, otherwise nil.
-- @param sender      string A stable identifier for the sender.
-- @param chunkString string The raw chunk as received.
-- @return string|nil
function ChunkReassembler:add(sender, chunkString)
	local f = Util.split(chunkString, ":", CHUNK_HEADER_FIELDS)
	if #f < CHUNK_HEADER_FIELDS then
		return nil
	end
	local msgId = f[1]
	local index = tonumber(f[2])
	local total = tonumber(f[3])
	local piece = f[4]
	if not index or not total or total < 1 then
		return nil
	end

	-- Single-chunk messages need no buffering.
	if total == 1 then
		return piece
	end

	local key = sender .. "\031" .. msgId
	local buf = self.buffers[key]
	if not buf then
		buf = { total = total, count = 0, pieces = {}, time = GetTime() }
		self.buffers[key] = buf
	end
	if not buf.pieces[index] then
		buf.pieces[index] = piece
		buf.count = buf.count + 1
	end

	if buf.count >= buf.total then
		self.buffers[key] = nil
		return table.concat(buf.pieces)
	end
	return nil
end

--- Drop partially-received messages older than `maxAge` seconds, so a lost
-- chunk cannot leak its buffer forever. Call periodically.
-- @param maxAge number Seconds.
function ChunkReassembler:prune(maxAge)
	local now = GetTime()
	for key, buf in pairs(self.buffers) do
		if (now - buf.time) > maxAge then
			self.buffers[key] = nil
		end
	end
end
