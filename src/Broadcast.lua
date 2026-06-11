-- Broadcast.lua
--
-- The gossip engine. It turns a locally-extracted profile into a wire message
-- and floods it, and it processes inbound messages: loop avoidance, version
-- de-duplication (via the Cache), storage, and re-broadcast to everyone except
-- the peer/medium we received it from.
--
-- SENDER vs SUBJECT: SENDER is always the *immediate* sender (us, whenever we
-- originate or relay) and is used purely for loop avoidance. SUBJECT is the
-- profile owner and never changes as a message is relayed.

local _, ns = ...
local C = ns.Const
local Serializer = ns.Serializer

local Broadcast = ns.Class("Broadcast")
ns.Broadcast = Broadcast

function Broadcast:init()
	self.playerGUID = nil -- resolved at login
end

function Broadcast:start()
	self.playerGUID = UnitGUID("player")
	ns.comms:setMessageHandler(function(raw, context)
		self:onMessage(raw, context)
	end)
end

-- Helpers -------------------------------------------------------------------

local function isGroupMedium(medium)
	return medium == "PARTY" or medium == "RAID" or medium == "INSTANCE_CHAT"
end

-- Fan a list of chunks out across every medium, skipping the medium/peer the
-- message arrived on (broadcast mediums need no relay back to themselves).
-- @param context table|nil Transport context of the inbound message, or nil
--   when we are the origin (then we send everywhere).
function Broadcast:fanOut(chunks, context)
	local comms = ns.comms
	local srcMedium = context and context.medium

	-- Same-faction channel: skip if the message already came over the channel
	-- (every channel member already received it directly).
	if srcMedium ~= "CHANNEL" then
		local idx = comms:channelIndex()
		if idx then
			comms:sendChunksAddon(chunks, "CHANNEL", idx)
		end
	end

	-- Party/raid: skip if it already came through the group.
	local groupKind = comms:groupChannel()
	if groupKind and not isGroupMedium(srcMedium) then
		comms:sendChunksAddon(chunks, groupKind)
	end

	-- Battle.net (cross-faction relays): every eligible account except the one
	-- we received this from.
	comms:eachBNetGameAccount(function(gameAccountID)
		if srcMedium == "BNET" and context.gameAccountID == gameAccountID then
			return
		end
		comms:sendChunksBNet(chunks, gameAccountID)
	end)

	-- Regular friends: optional (see C.RELAY_TO_FRIENDS), redundant with channel.
	if C.RELAY_TO_FRIENDS then
		comms:eachOnlineFriend(function(name)
			if srcMedium == "WHISPER" and context.senderName == name then
				return
			end
			comms:sendChunksAddon(chunks, "WHISPER", name)
		end)
	end
end

-- Origination ---------------------------------------------------------------

--- Originate a broadcast for a profile we just extracted from real local data.
-- Stamps the authoritative origin-time, stores it (which applies de-dup), and
-- floods only if it represents new/changed content.
-- @param guid    string The subject's GUID.
-- @param unitID  string The subject's "Name-Realm".
-- @param profile table  { addon, contentVersion, data } from an adapter.
function Broadcast:originate(guid, unitID, profile)
	local encoded = Serializer.encodeProfile(profile.data)
	if not encoded then
		return
	end

	local candidate = {
		guid = guid,
		unitID = unitID,
		addon = profile.addon,
		originTime = time(), -- we are the origin: authoritative timestamp
		contentVersion = profile.contentVersion,
		data = profile.data,
	}
	local result = ns.cache:tryStore(candidate)
	if ns.debugStore then
		ns.debugStore(result, guid)
	end
	if result ~= ns.Cache.RESULT.NEW and result ~= ns.Cache.RESULT.UPDATED then
		return -- nothing new to share
	end

	local message = Serializer.buildMessage({
		sender = self.playerGUID,
		subject = guid,
		unitID = unitID,
		addon = profile.addon,
		originTime = candidate.originTime,
		contentVersion = profile.contentVersion,
		data = encoded,
	})
	if ns.debugBroadcast then
		ns.debugBroadcast(guid)
	end
	self:fanOut(Serializer.chunk(message), nil)
end

-- Reception -----------------------------------------------------------------

--- Handle a fully-reassembled inbound message.
function Broadcast:onMessage(raw, context)
	local msg = Serializer.parseMessage(raw)
	-- Reject malformed messages, including a non-numeric origin-time which would
	-- otherwise break the Cache's ordering comparison.
	if not msg or type(msg.originTime) ~= "number" then
		return
	end

	-- Loop avoidance: ignore our own traffic echoed back to us.
	if msg.sender == self.playerGUID then
		return
	end
	if ns.debugReceive then
		ns.debugReceive(msg.sender, msg.subject)
	end

	-- Decode the opaque profile payload.
	local profileData = Serializer.decodeProfile(msg.data)
	if not profileData then
		return -- corrupt or undecodable
	end

	local result = ns.cache:tryStore({
		guid = msg.subject,
		unitID = msg.unitID,
		addon = msg.addon,
		originTime = msg.originTime,
		contentVersion = msg.contentVersion,
		data = profileData,
	})
	if ns.debugStore then
		ns.debugStore(result, msg.subject)
	end

	-- Only relay genuinely new/changed content; this is what converges the flood.
	if result ~= ns.Cache.RESULT.NEW and result ~= ns.Cache.RESULT.UPDATED then
		return
	end

	-- Relay unchanged except for SENDER (now us). Re-use the already-encoded
	-- data verbatim rather than re-encoding.
	local relay = Serializer.buildMessage({
		sender = self.playerGUID,
		subject = msg.subject,
		unitID = msg.unitID,
		addon = msg.addon,
		originTime = msg.originTime,
		contentVersion = msg.contentVersion,
		data = msg.data,
	})
	self:fanOut(Serializer.chunk(relay), context)
end

-- Singleton.
ns.broadcast = Broadcast:new()
ns.OnLogin(function()
	ns.broadcast:start()
end)
