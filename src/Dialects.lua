-- Dialects.lua
--
-- Per-generation wire dialects: frozen tables describing how each supported
-- protocol generation shapes its control arguments and profile payloads.
-- A dialect is written once at bump time and never edited later; dropping a
-- generation means deleting its entry (and its LEGACY_CHANNELS bridge).
--
-- Negotiation rules (see doc/protocol.md):
--   outbound: each leg encodes at min(own generation, peer generation)
--   inbound:  payloads decode via DIALECTS[min(stamped gen, own generation)]
--   handshake verbs (FRP1 HELLO/HI/VER) are frozen and parse from any gen
--
-- The envelope's protoMajor always stamps the sender's true generation,
-- never the payload dialect. Receivers derive the payload dialect from it.

local _, ns = ...
local C = ns.Const
local Serializer = ns.Serializer

local Dialect = {}
ns.Dialect = Dialect

local DEFLATE = Enum.CompressionMethod.Deflate
local MAX_SIZE = Enum.CompressionLevel.OptimizeForSize

-- Profile codec pipeline ------------------------------------------------------
-- serializer output -> deflate -> channel-escape; decode reverses it.

local function packWire(serialized)
	if not serialized then
		return nil
	end
	local compressed = C_EncodingUtil.CompressString(serialized,
		DEFLATE, MAX_SIZE)
	if not compressed then
		return nil
	end
	return Serializer.channelEncode(compressed)
end

local function unpackWire(encoded)
	local compressed = Serializer.channelDecode(encoded)
	if not compressed then
		return nil
	end
	-- Malformed wire input may error rather than return nil.
	local ok, serialized = pcall(C_EncodingUtil.DecompressString,
		compressed, DEFLATE)
	if ok then
		return serialized
	end
end

-- Generation 6: native CBOR payloads ------------------------------------------

local function encodeProfile6(data)
	local ok, serialized = pcall(C_EncodingUtil.SerializeCBOR, data)
	if not ok then
		return nil
	end
	return packWire(serialized)
end

local function decodeProfile6(encoded)
	local serialized = unpackWire(encoded)
	if not serialized then
		return nil
	end
	local ok, value = pcall(C_EncodingUtil.DeserializeCBOR, serialized)
	if not ok or type(value) ~= "table" then
		return nil
	end
	return value
end

-- Control-verb argument schemas ------------------------------------------------
-- Field list order is the wire order. Fields:
--   name      canonical record key
--   optional  absent wire args / empty fields are tolerated
--   num       tonumber'd on parse; non-numeric tokens become nil
--   gatesTail when empty at encode, this field and everything after it is
--             omitted (REQ: unitID absent means guid travels alone)
-- Trailing args beyond the schema are ignored on parse, the append-only
-- compatibility trick older readers rely on.

local REQ_SCHEMA = {
	{ name = "guid" },
	{ name = "unitID", optional = true, gatesTail = true },
	{ name = "seenAt", optional = true, num = true },
	{ name = "pid",    optional = true },
	{ name = "cvHash", optional = true },
	{ name = "flag",   optional = true },
}
local ACK_SCHEMA = {
	{ name = "guid" },
	{ name = "seenAt", num = true },
	{ name = "dirSeenAt", optional = true, num = true },
}
local GUID_SCHEMA = {
	{ name = "guid" },
}

Dialect.DIALECTS = {
	[6] = {
		ctlProto = "FRP1",
		verbs = {
			REQ = REQ_SCHEMA,
			ACK = ACK_SCHEMA,
			OK = GUID_SCHEMA,
			NOK = GUID_SCHEMA,
		},
		encodeProfile = encodeProfile6,
		decodeProfile = decodeProfile6,
	},
}

-- Frozen handshake vocabulary shared by every generation so peers are
-- discoverable before their generation is known.
local HANDSHAKE_VERBS = { HELLO = true, HI = true, VER = true }

local floorGen = math.huge
for gen in pairs(Dialect.DIALECTS) do
	if gen < floorGen then
		floorGen = gen
	end
end

-- Our own generation must always be encodable.
assert(Dialect.DIALECTS[C.PROTO_MAJOR],
	"no dialect table for PROTO_MAJOR " .. tostring(C.PROTO_MAJOR))

-- Negotiation ------------------------------------------------------------------

--- Lowest generation with a dialect table. Stamps below it are rejected.
function Dialect.floor()
	return floorGen
end

--- Generation a `stamp`-stamped payload decodes in: min(stamp, own), when a
-- dialect exists for it. Senders encode min(their gen, ours) and stamp their
-- true gen, so the clamp recovers exactly what they wrote.
-- @return number|nil
function Dialect.decodeGen(stamp)
	local gen = math.min(stamp or 0, C.PROTO_MAJOR)
	if Dialect.DIALECTS[gen] then
		return gen
	end
end

--- Generation to encode a leg for a peer of known generation: min(own,
-- peerGen). nil peerGen means no information (channel send, unrecorded
-- peer): own gen. Returns nil when no dialect can carry the leg.
-- @return number|nil
function Dialect.sendGen(peerGen)
	local gen = math.min(C.PROTO_MAJOR, peerGen or C.PROTO_MAJOR)
	if Dialect.DIALECTS[gen] then
		return gen
	end
end

-- Control codec -----------------------------------------------------------------

--- Serialize a control verb + named fields into the wire `data` string for
-- generation `gen`. Handshake verbs always emit the frozen FRP1 form.
-- @return string|nil nil when the dialect or verb is unknown, or a required
--   field is absent.
function Dialect.buildCtlData(verb, fields, gen)
	if HANDSHAKE_VERBS[verb] then
		if fields.version and fields.version ~= "" then
			return C.CTL_PROTO .. " " .. verb .. " " .. fields.version
		end
		return C.CTL_PROTO .. " " .. verb
	end
	local dialect = Dialect.DIALECTS[gen]
	local schema = dialect and dialect.verbs[verb]
	if not schema then
		return nil
	end
	local parts = { dialect.ctlProto, verb }
	-- Absent optionals emit "-" placeholders mid-list but are trimmed at the
	-- tail; an explicit "-" field value counts as real content.
	local lastReal = 1
	for _, field in ipairs(schema) do
		local v = fields[field.name]
		local placeholder = false
		if v == nil or v == "" then
			if field.gatesTail then
				break
			elseif field.optional then
				v, placeholder = "-", true
			else
				return nil
			end
		end
		parts[#parts + 1] = tostring(v)
		if not placeholder then
			lastReal = #parts
		end
	end
	return table.concat(parts, " ", 1, lastReal)
end

--- Parse a control envelope's data field into a canonical record.
-- Handshake verbs parse under the frozen FRP1 rule; negotiated verbs parse
-- via the dialect selected by min(msg.protoVer, own).
-- @return table|nil { proto, verb, args = { <named fields> }, gen, handshake }
--   gen is the inbound decode generation: the dialect for replying.
function Dialect.parseCtl(msg)
	local proto, verb, rest = msg.data:match("^(%S+)%s+(%S+)%s*(.*)$")
	if not verb then
		return nil
	end
	if proto == C.CTL_PROTO and HANDSHAKE_VERBS[verb] then
		local version = rest:match("^(%S*)")
		if verb == "VER" and version == "" then
			return nil
		end
		return {
			proto = proto, verb = verb, handshake = true,
			gen = Dialect.decodeGen(msg.protoVer),
			args = { version = version },
		}
	end
	local gen = Dialect.decodeGen(msg.protoVer)
	local dialect = gen and Dialect.DIALECTS[gen]
	local schema = dialect and dialect.ctlProto == proto
		and dialect.verbs[verb]
	if not schema then
		return nil
	end
	local args, n = {}, 0
	for token in rest:gmatch("%S+") do
		n = n + 1
		local field = schema[n]
		if not field then
			break
		end
		args[field.name] = field.num and tonumber(token) or token
	end
	for i, field in ipairs(schema) do
		if not field.optional and i > n then
			return nil
		end
	end
	return { proto = proto, verb = verb, args = args, gen = gen }
end

-- Profile codec -----------------------------------------------------------------

--- Encode a profile table into a wire-safe string for generation `gen`.
-- @return string|nil
function Dialect.encodeProfile(data, gen)
	local dialect = Dialect.DIALECTS[gen]
	if dialect then
		return dialect.encodeProfile(data)
	end
end

--- Decode a wire payload stamped `stamp`: clamps to min(stamp, own) and
-- dispatches to that dialect's codec.
-- @return table|nil
function Dialect.decodeProfile(encoded, stamp)
	local gen = Dialect.decodeGen(stamp)
	if gen then
		return Dialect.DIALECTS[gen].decodeProfile(encoded)
	end
end
