-- Serializer.lua
--
-- Messages to wire-safe bytes and back:
--   1. Profile codec   - table <-> compressed, channel-safe string
--   2. Envelope codec  - the "||"-delimited message header + data
--   3. Chunking        - split across the 255-byte message limit, reassemble
--
-- Profile data pipeline:
--   table --Serialize--> string --CompressDeflate--> bytes --EncodeForWoWAddonChannel--> safe string
--
-- The encoded string contains no NULL byte (the only byte the channel
-- forbids); it may contain "|" or ":", so framing parses positionally.

local _, ns = ...
local C = ns.Const

local Serializer = {}
ns.Serializer = Serializer

local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")

-- Profile data codec --------------------------------------------------------

--- Serialize+compress+encode an (opaque) profile data table into a wire-safe
-- string. Returns nil if the value cannot be serialized.
-- @param data table
-- @return string|nil
function Serializer.encodeProfile(data)
	-- pcall keeps a single unserializable profile from erroring the caller.
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
-- Wire layout (see doc/protocol.md):
--   SENDER || SUBJECT || NAME-REALM || ADDON || ORIGIN-TIME || CONTENT-VERSION
--        || PROTO-MAJOR || DATA
-- Receivers reject envelopes on a lower PROTO_MAJOR. DATA is always last so
-- "||" inside the payload is preserved.

local SEP_LEN = #C.SEPARATOR

--- Build the envelope string from a message table.
-- @param msg table { sender, subject, unitID, addon, originTime, contentVersion, data }
--   where `data` is the already-encoded profile string.
-- @return string
function Serializer.buildMessage(msg)
	local sep = C.SEPARATOR
	-- unitID is optional on the wire; "" means "not asserted". Our own unitID
	-- can be unknown when getUnitID cannot see the realm (issue #26).
	return msg.sender .. sep .. msg.subject .. sep .. (msg.unitID or "") .. sep
		.. msg.addon .. sep .. tostring(msg.originTime) .. sep
		.. msg.contentVersion .. sep .. C.PROTO_MAJOR .. sep .. msg.data
end

--- Parse an envelope string back into a message table. Returns nil if the
-- field count is wrong. Parsed positionally (seven separator finds, no split
-- table) to keep the inbound path allocation-light.
-- @param str string
-- @return table|nil
function Serializer.parseMessage(str)
	local sep = C.SEPARATOR
	local s1 = str:find(sep, 1, true)
	if not s1 then return nil end
	local s2 = str:find(sep, s1 + SEP_LEN, true)
	if not s2 then return nil end
	local s3 = str:find(sep, s2 + SEP_LEN, true)
	if not s3 then return nil end
	local s4 = str:find(sep, s3 + SEP_LEN, true)
	if not s4 then return nil end
	local s5 = str:find(sep, s4 + SEP_LEN, true)
	if not s5 then return nil end
	local s6 = str:find(sep, s5 + SEP_LEN, true)
	if not s6 then return nil end
	local s7 = str:find(sep, s6 + SEP_LEN, true)
	if not s7 then return nil end
	return {
		sender = str:sub(1, s1 - 1),
		subject = str:sub(s1 + SEP_LEN, s2 - 1),
		unitID = str:sub(s2 + SEP_LEN, s3 - 1),
		addon = str:sub(s3 + SEP_LEN, s4 - 1),
		originTime = tonumber(str:sub(s4 + SEP_LEN, s5 - 1)),
		contentVersion = str:sub(s5 + SEP_LEN, s6 - 1),
		protoVer = tonumber(str:sub(s6 + SEP_LEN, s7 - 1)),
		data = str:sub(s7 + SEP_LEN),
	}
end

-- Chunking ------------------------------------------------------------------
--
-- Wire chunk: "MSGID:INDEX:TOTAL:PIECE". Header fields are integers, so a
-- positional split recovers PIECE intact even when it contains ":".

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
		chunks[i] = msgId .. ":" .. i .. ":" .. total .. ":" .. piece
	end
	return chunks
end

-- ChunkReassembler: buffers chunks per (sender, msgId) until complete.
-- Buffers and piece tables are pooled so steady state allocates nothing.
local ChunkReassembler = ns.Class("ChunkReassembler")
Serializer.ChunkReassembler = ChunkReassembler

local BUF_POOL_CAP = 64

function ChunkReassembler:init()
	self.buffers = {} -- [sender] = { [msgId] = { total, count, dupes, pieces, time } }
	self.bufAcquire, self.bufRelease = ns.Util.newPool(BUF_POOL_CAP)
	self.pieceAcquire, self.pieceRelease = ns.Util.newPool(BUF_POOL_CAP)
end

--- Feed one received chunk. On the final missing chunk, returns the full
-- message plus chunk count, first->last elapsed seconds, and dupe count;
-- otherwise nil.
-- @param sender      string A stable identifier for the sender.
-- @param chunkString string The raw chunk as received.
-- @return string|nil, number|nil, number|nil, number|nil
function ChunkReassembler:add(sender, chunkString)
	-- Manual header parse ("MSGID:INDEX:TOTAL:PIECE"): three colon finds,
	-- no split-table allocation on the hottest inbound path.
	local c1 = chunkString:find(":", 1, true)
	if not c1 then
		return nil
	end
	local c2 = chunkString:find(":", c1 + 1, true)
	if not c2 then
		return nil
	end
	local c3 = chunkString:find(":", c2 + 1, true)
	if not c3 then
		return nil
	end
	local msgId = chunkString:sub(1, c1 - 1)
	local index = tonumber(chunkString:sub(c1 + 1, c2 - 1))
	local total = tonumber(chunkString:sub(c2 + 1, c3 - 1))
	local piece = chunkString:sub(c3 + 1)
	if not index or not total or total < 1 then
		return nil
	end

	-- Single-chunk messages need no buffering.
	if total == 1 then
		return piece, 1, 0, 0
	end

	local perSender = self.buffers[sender]
	if not perSender then
		perSender = {}
		self.buffers[sender] = perSender
	end
	local buf = perSender[msgId]
	if not buf then
		buf = self.bufAcquire()
		buf.total = total
		buf.count = 0
		buf.dupes = 0
		buf.pieces = self.pieceAcquire()
		buf.time = GetTime()
		perSender[msgId] = buf
	end
	if not buf.pieces[index] then
		buf.pieces[index] = piece
		buf.count = buf.count + 1
	else
		buf.dupes = buf.dupes + 1
	end

	if buf.count >= buf.total then
		perSender[msgId] = nil
		if not next(perSender) then
			self.buffers[sender] = nil
		end
		local full = table.concat(buf.pieces)
		local elapsed = GetTime() - buf.time
		local chunks, dupes = buf.total, buf.dupes
		self.pieceRelease(buf.pieces)
		buf.pieces = nil
		self.bufRelease(buf)
		return full, chunks, elapsed, dupes
	end
	return nil
end

--- Progress of the newest in-flight message from `sender`, for UI.
-- @return number|nil received chunk count, number|nil total chunk count
function ChunkReassembler:progress(sender)
	local perSender = self.buffers[sender]
	if not perSender then
		return nil
	end
	local newest
	for _, buf in pairs(perSender) do
		if not newest or buf.time > newest.time then
			newest = buf
		end
	end
	if newest then
		return newest.count, newest.total
	end
	return nil
end

--- Drop every partial buffer for one sender (e.g. a serve that stalled).
-- @return number How many buffers were dropped.
function ChunkReassembler:drop(sender)
	local perSender = self.buffers[sender]
	if not perSender then
		return 0
	end
	local dropped = 0
	for msgId, buf in pairs(perSender) do
		perSender[msgId] = nil
		self.pieceRelease(buf.pieces)
		self.bufRelease(buf)
		dropped = dropped + 1
	end
	self.buffers[sender] = nil
	return dropped
end

--- Drop partially-received messages older than `maxAge` seconds, so a lost
-- chunk cannot leak its buffer forever. Call periodically.
-- @param maxAge number Seconds.
-- @return number How many partial buffers were dropped.
function ChunkReassembler:prune(maxAge)
	local now = GetTime()
	local dropped = 0
	for sender, perSender in pairs(self.buffers) do
		for msgId, buf in pairs(perSender) do
			if (now - buf.time) > maxAge then
				perSender[msgId] = nil
				self.pieceRelease(buf.pieces)
				buf.pieces = nil
				self.bufRelease(buf)
				dropped = dropped + 1
			end
		end
		if not next(perSender) then
			self.buffers[sender] = nil
		end
	end
	return dropped
end
