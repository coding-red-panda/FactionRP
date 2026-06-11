-- Comms.lua
--
-- The transport layer. It owns the addon-message prefix, the hidden same-
-- faction chat channel, Battle.net peer enumeration, a paced outbound queue
-- (so the client throttle does not silently drop messages), and chunk
-- reassembly of inbound traffic. It deals only in opaque wire strings; the
-- message envelope is built/parsed one layer up (Broadcast + Serializer).

local _, ns = ...
local C = ns.Const

local Comms = ns.Class("Comms")
ns.Comms = Comms

function Comms:init()
	self.prefix = C.MSG_PREFIX
	self.assembler = ns.Serializer.ChunkReassembler:new()
	self.queue = {} -- FIFO of pending send closures
	self.messageHandler = nil -- set by Broadcast: fn(rawMessage, context)
	self.started = false
end

-- Lifecycle -----------------------------------------------------------------

--- Begin transport: register prefix, hook receive events, join the channel,
-- and start the paced sender. Safe to call once.
function Comms:start()
	if self.started then
		return
	end
	self.started = true

	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		C_ChatInfo.RegisterAddonMessagePrefix(self.prefix)
	end

	ns.RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
		self:onChatMsgAddon(prefix, text, channel, sender)
	end)
	ns.RegisterEvent("BN_CHAT_MSG_ADDON", function(_, prefix, text, kind, bnetIDGameAccount)
		self:onBNChatMsgAddon(prefix, text, bnetIDGameAccount)
	end)

	-- (Re)join the hidden channel whenever we (re)enter the world.
	ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
		self:joinChannel()
	end)
	self:joinChannel()

	-- Paced sender and stale-buffer pruning.
	self.sendTicker = C_Timer.NewTicker(C.SEND_INTERVAL, function()
		self:flushQueue()
	end)
	self.pruneTicker = C_Timer.NewTicker(C.REASSEMBLY_TIMEOUT / 2, function()
		self.assembler:prune(C.REASSEMBLY_TIMEOUT)
	end)
end

--- Set the callback that receives fully-reassembled messages.
-- @param fn function Invoked as fn(rawMessage, context).
function Comms:setMessageHandler(fn)
	self.messageHandler = fn
end

-- Channel -------------------------------------------------------------------

--- Join the hidden same-faction relay channel (no chat tab).
function Comms:joinChannel()
	JoinTemporaryChannel(C.COMM_CHANNEL)
end

--- Current channel index for the relay channel, or nil if not joined.
function Comms:channelIndex()
	local id = GetChannelName(C.COMM_CHANNEL)
	if not id or id == 0 then
		return nil
	end
	return id
end

-- Outbound queue ------------------------------------------------------------

--- Queue a send closure for paced delivery.
function Comms:enqueue(fn)
	self.queue[#self.queue + 1] = fn
end

--- Release up to SEND_BURST queued sends. Invoked on a timer.
function Comms:flushQueue()
	local budget = C.SEND_BURST
	while budget > 0 and #self.queue > 0 do
		local fn = table.remove(self.queue, 1)
		fn()
		budget = budget - 1
	end
end

-- Send primitives (all paced via the queue) ---------------------------------

--- Send one raw chunk over an in-game addon channel.
-- @param text   string The chunk.
-- @param kind   string "CHANNEL" | "PARTY" | "RAID" | "INSTANCE_CHAT" | "WHISPER".
-- @param target any    Channel index (for CHANNEL) or player name (for WHISPER).
function Comms:sendAddon(text, kind, target)
	self:enqueue(function()
		if C_ChatInfo and C_ChatInfo.SendAddonMessage then
			C_ChatInfo.SendAddonMessage(self.prefix, text, kind, target)
		end
	end)
end

--- Send one raw chunk to a Battle.net game account.
function Comms:sendBNet(text, gameAccountID)
	self:enqueue(function()
		if BNSendGameData then
			BNSendGameData(gameAccountID, self.prefix, text)
		end
	end)
end

-- Convenience: send a list of chunks over a single medium ------------------

function Comms:sendChunksAddon(chunks, kind, target)
	for i = 1, #chunks do
		self:sendAddon(chunks[i], kind, target)
	end
end

function Comms:sendChunksBNet(chunks, gameAccountID)
	for i = 1, #chunks do
		self:sendBNet(chunks[i], gameAccountID)
	end
end

-- Peer enumeration ----------------------------------------------------------

--- The addon channel kind for the current group, or nil if solo.
-- Handles instanced groups, where PARTY/RAID do not deliver.
function Comms:groupChannel()
	if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		return "INSTANCE_CHAT"
	elseif IsInRaid() then
		return "RAID"
	elseif IsInGroup() then
		return "PARTY"
	end
	return nil
end

--- Invoke callback(gameAccountID) for every online WoW Battle.net friend in
-- the current region. These are our cross-faction relays.
function Comms:eachBNetGameAccount(callback)
	if BNFeaturesEnabledAndConnected and not BNFeaturesEnabledAndConnected() then
		return
	end
	local numFriends = BNGetNumFriends() or 0
	for i = 1, numFriends do
		local numAccounts = C_BattleNet.GetFriendNumGameAccounts(i) or 0
		for j = 1, numAccounts do
			local acct = C_BattleNet.GetFriendGameAccountInfo(i, j)
			if acct
				and acct.gameAccountID
				and acct.isOnline
				and acct.clientProgram == BNET_CLIENT_WOW
				and acct.isInCurrentRegion
			then
				callback(acct.gameAccountID)
			end
		end
	end
end

--- Invoke callback(characterName) for every online (same-faction) WoW friend.
function Comms:eachOnlineFriend(callback)
	if not C_FriendList then
		return
	end
	local num = C_FriendList.GetNumFriends() or 0
	for i = 1, num do
		local info = C_FriendList.GetFriendInfoByIndex(i)
		if info and info.connected and info.name then
			callback(info.name)
		end
	end
end

-- Inbound -------------------------------------------------------------------

function Comms:onChatMsgAddon(prefix, text, channel, sender)
	if prefix ~= self.prefix then
		return
	end
	self:handleIncoming(text, { medium = channel, senderName = sender })
end

function Comms:onBNChatMsgAddon(prefix, text, bnetIDGameAccount)
	if prefix ~= self.prefix then
		return
	end
	self:handleIncoming(text, { medium = "BNET", gameAccountID = bnetIDGameAccount })
end

--- Reassemble a chunk and, once a full message is available, hand it to the
-- registered message handler with transport context (used by Broadcast for
-- loop avoidance and to avoid echoing back to the source peer).
function Comms:handleIncoming(chunkString, context)
	-- Reassembly is keyed by a stable per-sender identity.
	local senderKey = context.senderName or ("bn:" .. tostring(context.gameAccountID))
	local full = self.assembler:add(senderKey, chunkString)
	if full and self.messageHandler then
		self.messageHandler(full, context)
	end
end

-- Singleton, started after login.
ns.comms = Comms:new()
ns.OnLogin(function()
	ns.comms:start()
end)
