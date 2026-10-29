-- Comms.lua
--
-- The transport layer: addon prefix, the hidden faction channel, BNet peer
-- enumeration, a paced outbound queue, and inbound chunk reassembly.
-- Envelope build/parse lives one layer up (Broadcast + Serializer).

local _, ns = ...
local C = ns.Const

local Comms = ns.Class("Comms")
ns.Comms = Comms

local bnKeys = {} -- [gameAccountID] = "bn:<id>" senderKey (persistent)

local function noteRestrictedResponses()
-- //edit:we may drop the answer during our own loading. Keep the contact later
	if not ns.broadcast then
		return
	end
	for _, request in pairs(ns.broadcast.requests) do
		if request.state == "contact" and request.sentAt then
			request.responseRestricted = true
		end
	end
end

function Comms:init()
	self.prefix = C.MSG_PREFIX
	self.assembler = ns.Serializer.ChunkReassembler:new()
	-- The queue holds pooled descriptor records, not closures, so a send at
	-- steady state allocates nothing.
	self.queue = { head = 1, tail = 0 }
	self.sendCredit = 0 -- token bucket: chunks release at C.SEND_RATE/sec
	self.descAcquire, self.descRelease = ns.Util.newPool(C.POOL_SEND_DESC)
	self.messageHandler = nil -- set by Broadcast: fn(rawMessage, context)
	self.started = false
	-- Memoized online WoW BNet account ids (see bnetAccounts).
	self.bnetAcctMemo = { ids = {}, at = 0 }
	-- FRP1 BNet peer confirmation state, session-only, reset in place:
	--   [gameAccountID] = { confirmedAt, probeSentAt, ignoredAt, lastHi, version }
	self.bnetPeers = {}
	self.probeCursor = 0
	-- [senderKey] = GetTime() expiry; chunks from senders whose messages
	-- failed the version/malformed gates are dropped before reassembly.
	self.rejectedSenders = {}
	-- [senderKey] = GetTime() of the last accepted chunk; Broadcast uses it
	-- to stall-detect granted serves.
	self.lastChunkFrom = {}
	-- Member count of the comms channel, pushed by CHANNEL_COUNT_UPDATE.
	self.meshSize = 0
	-- Loading-screen flag: realm names resolve unreliably mid-transition
	-- (issue #26), so roster/name work pauses while it is up.
	self.loading = IsLoggedIn ~= nil and not IsLoggedIn()
	self.initialLoading = self.loading
	self.resumeAt = 0
	self.loadGeneration = 0
	self.activityPaused = false
	self.whisperBackoff = {}
	self.whisperAttempts = {}
	self.restricted = false -- edge flag: partials pruned once per restriction
	-- Scratch transport contexts, mutated per inbound event. Valid only
	-- for the duration of the synchronous handler call; do not retain.
	self.chatCtx = { medium = nil, senderName = nil, senderKey = nil, gameAccountID = nil }
	self.bnCtx = { medium = "BNET", senderName = nil, senderKey = nil, gameAccountID = nil }
end

-- Lifecycle -----------------------------------------------------------------

--- Begin transport: register prefix, hook receive events, join the channel,
-- and start the paced sender. Safe to call once.
function Comms:start()
	if self.started then
		return
	end
	self.started = true
	self:updateActivityState()

	-- Channel/group addon traffic echoes back to the sender; remember our
	-- normalized name so the echo can be dropped at intake.
	if not ns.Util.isPaused() then
		local ownName = GetUnitName("player", true)
		if ns.Util.canWeUse(ownName) then
			self.ownName = ns.Util.normalizeUnitName(ownName)
		end
	end

	C_ChatInfo.RegisterAddonMessagePrefix(self.prefix)

	ns.RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
		self:onChatMsgAddon(prefix, text, channel, sender)
	end)
	ns.RegisterEvent("BN_CHAT_MSG_ADDON", function(_, prefix, text, kind, bnetIDGameAccount)
		self:onBNChatMsgAddon(prefix, text, bnetIDGameAccount)
	end)

	-- (Re)join the hidden channel whenever we (re)enter the world.
	if not ns.Util.isPaused() then
		self:joinChannel()
	end

	-- Member counts feed meshSize, which scales the serve cooldown and
	-- gates REQ sampling. Roster updates carry the same count and signal
	-- that member data (sampled-REQ targets) has streamed in.
	local function onChannelCount(_, displayIndex, count)
		if displayIndex == self:channelIndex() then
			self.meshSize = count or self.meshSize
		end
	end
	ns.RegisterEvent("CHANNEL_COUNT_UPDATE", onChannelCount)
	ns.RegisterEvent("CHANNEL_ROSTER_UPDATE", onChannelCount)

	ns.RegisterEvent("CHAT_MSG_SYSTEM", function(_, message)
		self:onWhisperError(message)
	end)

	-- Every presence event refreshes the account memo, but only an account
	-- coming online re-opens probing; INFO_CHANGED/FRIENDLIST_UPDATE fire
	-- on zone churn and would resurrect ignored accounts before their TTL.
	local function onFriendPresence()
		self.bnetAcctMemo.at = 0
	end
	-- A friend coming online earns a fresh probe slate on just their WoW
	-- game account — one login must not un-ignore everyone else. The event
	-- carries friendId (a bnet account id); resolve it to the online
	-- gameAccountID. Unresolvable lookups leave ignores alone — the TTL
	-- decay path still applies.
	local function onFriendOnline(_, friendId)
		self.bnetAcctMemo.at = 0
		local ok, info = pcall(C_BattleNet.GetAccountInfoByID, friendId)
		local acct = ok and ns.Util.fieldsUsable(info, "gameAccountInfo")
			and info.gameAccountInfo or nil
		local gid = ns.Util.fieldsUsable(acct, "gameAccountID")
			and acct.gameAccountID or nil
		local p = gid and self.bnetPeers[gid]
		if p then
			p.ignoredAt = 0
			p.probeSentAt = 0
		end
	end
	ns.RegisterEvent("BN_FRIEND_ACCOUNT_ONLINE", onFriendOnline)
	ns.RegisterEvent("BN_FRIEND_INFO_CHANGED", onFriendPresence)
	ns.RegisterEvent("FRIENDLIST_UPDATE", onFriendPresence)
	ns.RegisterEvent("BN_DISCONNECTED", function()
		for id in pairs(self.bnetPeers) do
			self.bnetPeers[id] = nil
		end
		self.bnetAcctMemo.at = 0
	end)

	-- Paced sender and stale-buffer pruning.
	self.sendTicker = C_Timer.NewTicker(C.SEND_INTERVAL, function()
		self:flushQueue()
	end)
	self.pruneTicker = C_Timer.NewTicker(C.REASSEMBLY_TIMEOUT / 2, function()
		if ns.Util.isPaused() then
			return
		end
		local dropped = self.assembler:prune(C.REASSEMBLY_TIMEOUT)
		if dropped > 0 and ns.statsPruned then
			ns.statsPruned(dropped)
		end
		local cutoff = GetTime() - C.REASSEMBLY_TIMEOUT
		for key, at in pairs(self.lastChunkFrom) do
			if at < cutoff then
				self.lastChunkFrom[key] = nil
			end
		end

		for key, at in pairs(self.whisperAttempts) do
			if GetTime() - at > C.WHISPER_ERROR_WINDOW then
				self.whisperAttempts[key] = nil
			end
		end
		for key, untilAt in pairs(self.whisperBackoff) do
			if GetTime() >= untilAt then
				self.whisperBackoff[key] = nil
			end
		end

	end)
end

function Comms:pauseForLoading()
	self.loading = true
	self.initialLoading = false
	self.resumeAt = 0
	self.loadGeneration = self.loadGeneration + 1

	self:clearTransfers()
end

function Comms:clearTransfers()
-- //edit: Old transfered data should not start sending after we finish the teleport
	local q = self.queue
	for i = q.head, q.tail do
		self.descRelease(q[i])
		q[i] = nil
	end

	q.head, q.tail = 1, 0
	self.sendCredit = 0

	for sender in pairs(self.assembler.buffers) do
		self.assembler:drop(sender)
	end

	wipe(self.lastChunkFrom)
	ns.Util.pauseForLoading()

	for _, peer in pairs(self.bnetPeers) do
		if peer.ignoredAt == 0 then
			peer.probeSentAt = 0
		end
	end

	if ns.broadcast then
		ns.broadcast:pauseForLoading()
	end
	if ns.scanner then
		ns.scanner:cancelHover()
	end
end

function Comms:updateActivityState()
	local paused = ns.Util.isActivityPaused()
	if paused == self.activityPaused then
		return
	end

	self.activityPaused = paused
	if paused then
		self.loadGeneration = self.loadGeneration + 1
		self.resumeAt = 0

		-- //edit: Cancel our old requests instead of saving a burst for after the fight
		self:clearTransfers()
		wipe(self.whisperAttempts)

		if ns.scanner then
			ns.scanner:pauseForActivity()
		end
		if ns.broadcast then
			wipe(ns.broadcast.injectQueue)
			wipe(ns.broadcast.injectOrder)
			ns.broadcast.injectOrder.head, ns.broadcast.injectOrder.tail = 1, 0
		end
	elseif not self.loading then
		self:resumeAfterLoading()
	end
end

function Comms:resumeAfterLoading()
	self.loadGeneration = self.loadGeneration + 1
	local generation = self.loadGeneration
	self.resumeAt = GetTime() + C.LOADING_RESUME_DELAY

	C_Timer.After(C.LOADING_RESUME_DELAY, function()
		if self.loading or generation ~= self.loadGeneration or ns.Util.isActivityPaused() then
			return
		end

		self.resumeAt = 0
		local ownName = GetUnitName("player", true)

		if ns.Util.canWeUse(ownName) then
			self.ownName = ns.Util.normalizeUnitName(ownName)
		end

		self:joinChannel()
		ns.Util.refreshClubRoster()

		if ns.scanner then
			ns.scanner:shareSelf()
		end

		if ns.broadcast and ns.broadcast.versionPending then
			ns.broadcast:broadcastVersion()
		end

	end)
end

function Comms:canWhisper(target)
	local key = ns.Util.normalizeUnitName(target)

	if not key or GetTime() < (self.whisperBackoff[key] or 0)
		or ns.Util.isClubMemberOffline(target)
	then
		return false
	end

	local relay = ns.broadcast and ns.broadcast.relays[key]
	return relay == nil or ns.Util.isClubMemberOnline(target)

end

function Comms:backoffWhisper(target)

	local key = ns.Util.normalizeUnitName(target)

	if key then
		self.whisperBackoff[key] = GetTime() + C.WHISPER_FAILURE_TTL
	end
end

function Comms:onWhisperError(message)
	if ns.Util.isPaused() then
		return
	end

	local format = ERR_CHAT_PLAYER_NOT_FOUND_S

	if type(message) ~= "string" or type(format) ~= "string"
		or not ns.Util.canWeUse(message)
	then
		return
	end

	local first, last = format:find("%s", 1, true)

	if not first then
		first, last = format:find("%1$s", 1, true)
	end

	if not first then
		return
	end

	local prefix, suffix = format:sub(1, first - 1), format:sub(last + 1)

	if message:sub(1, #prefix) ~= prefix
		or (#suffix > 0 and message:sub(-#suffix) ~= suffix)
	then

		return
	end

	local name = message:sub(#prefix + 1, #message - #suffix)
	local matched

	for target, at in pairs(self.whisperAttempts) do
		if GetTime() - at <= C.WHISPER_ERROR_WINDOW
			and (target == ns.Util.normalizeUnitName(name)
				or (not name:find("-", 1, true) and target:match("^([^-]+)") == name:lower()))
		then
			if matched then
				return
			end
			matched = target
		end
	end

-- //Edit: only react to whisper errors we actually sent recently
	if matched then
		self:backoffWhisper(matched)
		self.whisperAttempts[matched] = nil
	end
end

--- Set the callback that receives fully-reassembled messages.
-- @param fn function Invoked as fn(rawMessage, context).
function Comms:setMessageHandler(fn)
	self.messageHandler = fn
end

-- Channel -------------------------------------------------------------------

--- Leave any FactionRP channel that is not our protocol generation. Channel
-- membership survives /reload, so an upgraded client would otherwise keep
-- hearing old-protocol traffic for the session.
function Comms:leaveForeignChannels()
	local current = C.COMM_CHANNEL:lower()
	-- Direct check for the legacy channel; hidden channels may not
	-- enumerate in GetChannelList.
	local legacyId = GetChannelName("FactionRP")
	if legacyId and legacyId ~= 0 then
		LeaveChannelByName("FactionRP")
	end
	local n = GetNumDisplayChannels()
	for i = 1, n do
		local _, name = GetChannelList(i)
		if type(name) == "string" then
			local lower = name:lower()
			local gen = lower:match("^frp(%d+)comms$")
			if (lower == "factionrp" or (gen and tonumber(gen) ~= C.PROTO_MAJOR))
				and lower ~= current
			then
				LeaveChannelByName(name)
			end
		end
	end
end

--- Join the hidden same-faction channel. Joining fires CHANNEL_UI_UPDATE
-- churn in the client even when already joined, so skip when we are in.
function Comms:joinChannel()
	if ns.Util.isPaused() then
		return
	end

	self:leaveForeignChannels()
	if self:channelIndex() then
		return -- already in the channel; nothing to do
	end
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

--- Live member count of the comms channel: 0 while not joined, and until
-- the first CHANNEL_COUNT_UPDATE arrives after a join.
function Comms:meshCount()
	if not self:channelIndex() then
		return 0
	end
	return self.meshSize
end

--- Member names of the comms channel for REQ sampling, or nil while not
-- joined. May be partial while the roster streams.
function Comms:meshRoster()
	if ns.Util.isPaused() then
		return nil -- member names are unreliable mid-transition
	end
	local idx = self:channelIndex()
	if not idx then
		return nil
	end
	local names, n = {}, 0
	for i = 1, self.meshSize do
		local name = C_ChatInfo.GetChannelRosterInfo(idx, i)
		if name then
			n = n + 1
			names[n] = name
		end
	end
	return names
end

-- Register an event so we can update our channel on reorder over the pipe.
hooksecurefunc(C_ChatInfo, "SwapChatChannelsByChannelIndex", function()
	C_Timer.After(0, function() 
-- //edit: data thats waiting still need the right channel during a pause
		ns.Util.fixChompChannelTargets(Comms:channelIndex())
	end)
end)


-- Outbound queue ------------------------------------------------------------

--- Number of sends currently queued.
function Comms:queueDepth()
	local q = self.queue
	return q.tail - q.head + 1
end

--- Queue a send descriptor for paced delivery.
function Comms:enqueue(desc)
	if ns.Util.isPaused() then
		self.descRelease(desc)
		return false
	end

	local q = self.queue
	q.tail = q.tail + 1
	q[q.tail] = desc
	if ns.statsQueue then
		ns.statsQueue(q.tail - q.head + 1)
	end
end

--- Dispatch a queued descriptor through Chomp (or the raw fallback),
-- recording stats hooks. The descriptor is released after dispatch.
function Comms:sendDescriptor(desc)
	if ns.Util.isPaused() then
		return
	end

	local request = desc.contactRequest

	if request and (not ns.broadcast
		or ns.broadcast.requests[desc.contactSubject] ~= request
		or request.state ~= "contact" or request.sendFailed)
	then
		return
	end

	if request and not request.sentAt and request.sendDeadline
		and GetTime() > request.sendDeadline
	then
		request.sendFailed = true
		return
	end

	if desc.kind == "WHISPER" then
		if not self:canWhisper(desc.target) then
			if request then
				request.sendFailed = true
			end
			return
		end

		local key = ns.Util.normalizeUnitName(desc.target)
		self.whisperAttempts[key] = GetTime()

	end

	local text = desc.text
	if desc.kind == "CHANNEL" then
		-- Resolve the index at dispatch; a reorder between enqueue and
		-- dispatch can otherwise re-point a leg at a stale index.
		if desc.channelName then
			desc.target = GetChannelName(desc.channelName)
		else
			desc.target = self:channelIndex()
		end
		if not desc.target or desc.target == 0 then
			return
		end
	end
	if ns.statsChunkOut then
		ns.statsChunkOut(desc.kind, #text, GetTime() - desc.enqueuedAt)
	end
	if ns.debugChunk then
		ns.debugChunk("out", desc.kind, desc.target, #text)
	end
	-- The final chunk carries leg-completion fields so stats can time the
	-- full message drain.
	if desc.legTotal and ns.statsOutLeg then
		ns.statsOutLeg(desc.kind, desc.target, desc.legBytes, desc.legTotal, GetTime() - desc.legStartedAt)
	end

	if request and desc.contactLast then
		request.sentAt = GetTime()
		request.at = request.sentAt
	end

	local chomp = AddOn_Chomp
	if desc.mode == "bnet" then
		-- BNet sends share ChatThrottleLib's queue via Chomp when present.
		if chomp and chomp.BNSendGameData then
			chomp.BNSendGameData(desc.target, self.prefix, text, "LOW")
			return
		end
		C_BattleNet.SendGameData(desc.target, self.prefix, text)
		return
	end
	-- Chomp coalesces our sends into ChatThrottleLib's global queues. Raw
	-- SendAddonMessage bursts can stall other addons' CHANNEL sends
	-- (TRP3's unthrottled C_SCAN map-scan requests, notably).
	if chomp and chomp.SendAddonMessage then
		chomp.SendAddonMessage(self.prefix, text, desc.kind, desc.target, "LOW")
		return
	end
	C_ChatInfo.SendAddonMessage(self.prefix, text, desc.kind, desc.target)
end

--- Release queued sends at C.SEND_RATE chunks/second via a fractional
-- token bucket. Credit caps at one send's worth so an idle queue cannot
-- bank an unbounded burst; the 1e-6 tolerance absorbs float accrual.
function Comms:flushQueue()
	self:updateActivityState()
	-- Hold all sends while restricted; the queue drains after. On entry,
	-- drop partial inbound buffers: their missing chunks can never arrive.
	if ns.Util.commsRestricted() then
		noteRestrictedResponses()
		if not self.restricted then
			self.restricted = true
			self.assembler:prune(0)
		end
		return
	end
	self.restricted = nil
	-- Hold all sends while our own GUID is unreadable.
	if not ns.Util.canWeUse(UnitGUID("player")) then
		return
	end
	local q = self.queue
	local head = q.head
	self.sendCredit = math.min(self.sendCredit + C.SEND_RATE * C.SEND_INTERVAL, math.max(C.SEND_RATE, 1))
	local sent = 0
	while (self.sendCredit - sent) >= (1 - 1e-6) and head <= q.tail do
		local desc = q[head]
		q[head] = nil
		head = head + 1
		self:sendDescriptor(desc)
		self.descRelease(desc)
		sent = sent + 1
	end
	self.sendCredit = self.sendCredit - sent
	q.head = head
	if head > q.tail then
		-- Queue drained: reset indices to keep the array small.
		q.head, q.tail = 1, 0
	end
end

-- Send primitives (all paced via the queue) ---------------------------------

--- Send one raw chunk over an in-game addon channel.
-- @param text   string The chunk.
-- @param kind   string "CHANNEL" | "PARTY" | "RAID" | "INSTANCE_CHAT" | "WHISPER".
-- @param target any    Channel index (for CHANNEL) or player name (for WHISPER).
-- @return table The queued descriptor (callers may stamp leg-completion fields).
function Comms:sendAddon(text, kind, target)

	if ns.Util.isPaused() then
		return
	end

	local desc = self.descAcquire()
	desc.mode = "addon"
	desc.text = text
	desc.kind = kind
	desc.target = target
	desc.channelName = nil
	desc.enqueuedAt = GetTime()
	self:enqueue(desc)
	return desc
end

--- Send one raw chunk to a Battle.net game account.
function Comms:sendBNet(text, gameAccountID)
	if ns.Util.isPaused() then
		return

	end
	local desc = self.descAcquire()
	desc.mode = "bnet"
	desc.text = text
	desc.kind = "BNET"
	desc.target = gameAccountID
	desc.enqueuedAt = GetTime()
	self:enqueue(desc)
	return desc
end

-- Convenience: send a list of chunks over a single medium ------------------
-- The final chunk's descriptor carries leg-completion fields for stats.

--- Whether a leg of `n` chunks fits the queue bound. Legs drop whole: a
-- partial send is an incomplete at the far end plus wasted siblings.
local function legFits(comms, n)
	return comms:queueDepth() + n <= C.SEND_QUEUE_CAP
end

-- @return number|false Chunk count queued, or false when the whole leg was
--   dropped for capacity. Callers must not mark work as sent on false.
function Comms:sendChunksAddon(chunks, kind, target)
	if ns.Util.isPaused() or (kind == "WHISPER" and not self:canWhisper(target)) then
		return false
	end

	local n = #chunks
	if not legFits(self, n) then
		if ns.statsError then
			ns.statsError("send_queue_drop")
		end
		return false
	end
	local bytes, startedAt = 0, GetTime()
	for i = 1, n do
		bytes = bytes + #chunks[i]
	end
	for i = 1, n do
		local desc = self:sendAddon(chunks[i], kind, target)
		if i == n then
			desc.legStartedAt = startedAt
			desc.legBytes = bytes
			desc.legTotal = n
		end
	end
	return n
end

--- Send a chunk list over a named custom channel (e.g. a previous-generation
-- channel for the version announcement). Resolves to an index at dispatch.
function Comms:sendChunksChannel(chunks, channelName)
	if ns.Util.isPaused() then
		return false
	end

	local n = #chunks
	if not legFits(self, n) then
		if ns.statsError then
			ns.statsError("send_queue_drop")
		end
		return false
	end
	local bytes, startedAt = 0, GetTime()
	for i = 1, n do
		bytes = bytes + #chunks[i]
	end
	for i = 1, n do
		local desc = self:sendAddon(chunks[i], "CHANNEL", nil)
		desc.channelName = channelName
		if i == n then
			desc.legStartedAt = startedAt
			desc.legBytes = bytes
			desc.legTotal = n
		end
	end
	return n
end

function Comms:sendChunksBNet(chunks, gameAccountID)
	if ns.Util.isPaused() then
		return false

	end
	local n = #chunks
	if not legFits(self, n) then
		if ns.statsError then
			ns.statsError("send_queue_drop")
		end
		return false
	end
	local bytes, startedAt = 0, GetTime()
	for i = 1, n do
		bytes = bytes + #chunks[i]
	end
	for i = 1, n do
		local desc = self:sendBNet(chunks[i], gameAccountID)
		if i == n then
			desc.legStartedAt = startedAt
			desc.legBytes = bytes
			desc.legTotal = n
		end
	end
	return n
end

-- Peer enumeration ----------------------------------------------------------

--- Whether a BNet game account's character is our own faction. A
-- same-faction friend is reachable on the comm channel already — the BNet
-- leg exists to bridge factions, so they are not a valid relay. Unknown
-- or unreadable factions stay candidates.
local function sameFactionAccount(acct)
	local fname = acct.factionName
	if not ns.Util.canWeUse(fname) or not fname then
		return false
	end
	local en, loc = UnitFactionGroup("player")
	if not ns.Util.canWeUse(en, loc) then
		return false
	end
	return fname == en or fname == loc
end

--- Invoke callback(gameAccountID) for every online WoW Battle.net friend in
-- the current region whose character is opposite-faction. These are our
-- cross-faction relays.
function Comms:eachBNetGameAccount(callback)
	if ns.Util.isPaused() then
		return
	end

	if not BNFeaturesEnabledAndConnected() then
		return
	end
	local numFriends = BNGetNumFriends()
	if not ns.Util.canWeUse(numFriends) then
		return
	end
	for i = 1, numFriends or 0 do
		local numAccounts = C_BattleNet.GetFriendNumGameAccounts(i)
		if ns.Util.canWeUse(numAccounts) then
			for j = 1, numAccounts or 0 do
				local acct = C_BattleNet.GetFriendGameAccountInfo(i, j)
				if ns.Util.fieldsUsable(acct,
						"gameAccountID", "isOnline", "clientProgram", "isInCurrentRegion")
					and acct.gameAccountID
					and acct.isOnline
					and acct.clientProgram == BNET_CLIENT_WOW
					and acct.isInCurrentRegion
					and not sameFactionAccount(acct)
				then
					callback(acct.gameAccountID)
				end
			end
		end
	end
end

--- Online WoW Battle.net game account ids, memoized for C.BNET_MEMO
-- seconds; enumeration allocates client tables per account.
-- @return table List of gameAccountIDs (do not mutate, shared reference).
function Comms:bnetAccounts()
	local memo = self.bnetAcctMemo
	if ns.Util.isPaused() then
		return memo.ids
	end
	local now = GetTime()
	if (now - memo.at) > C.BNET_MEMO then
		local ids = memo.ids
		for i = #ids, 1, -1 do
			ids[i] = nil
		end
		self:eachBNetGameAccount(function(id)
			ids[#ids + 1] = id
		end)
		memo.at = now
	end
	return memo.ids
end

-- BNet peer confirmation (FRP1 handshake) -----------------------------------
-- Lifecycle per account: unconfirmed -> probing -> ignored | confirmed.
-- Any parseable FactionRP message over BNet confirms the account.
-- Entries are reset in place; the map is bounded by the friends list.

local function peerEntry(peers, id)
	local p = peers[id]
	if not p then
		p = { confirmedAt = 0, probeSentAt = 0, ignoredAt = 0, lastHi = 0, version = nil }
		peers[id] = p
	end
	return p
end

--- Stamp `id` as confirmed: it sent us a parseable FRP message. Records
-- the remote addon version when control messages carry it.
function Comms:bnetPeerSeen(id, version)
	if not id then
		return
	end
	local p = peerEntry(self.bnetPeers, id)
	local was = p.confirmedAt
	p.confirmedAt = GetTime()
	p.probeSentAt = 0
	p.ignoredAt = 0
	if version and version ~= "" then
		p.version = version
	end
	if was == 0 and ns.debugPeer then
		ns.debugPeer("bnet " .. id .. " confirmed" .. (p.version and (" v" .. p.version) or ""))
	end
end

--- Whether `id` holds a live confirmation (proof seen within the TTL).
function Comms:isBNetConfirmed(id, now)
	local p = self.bnetPeers[id]
	return p ~= nil and (now - p.confirmedAt) < C.BNET_CONFIRM_TTL
end

--- Pick the next online account due for a HELLO probe, round-robin over the
-- memoized list. Does not stamp; the caller marks the probe if it queued.
-- @return number|nil gameAccountID
function Comms:probeTarget(now)
	local ids = self:bnetAccounts()
	local n = #ids
	if n == 0 then
		return nil
	end
	self.probeCursor = self.probeCursor + 1
	local offset = ((self.probeCursor - 1) % n) + 1
	for i = 0, n - 1 do
		local id = ids[((offset + i - 1) % n) + 1]
		local p = self.bnetPeers[id]
		if p
			and p.ignoredAt ~= 0
			and (now - p.ignoredAt) >= C.BNET_IGNORE_TTL
		then
			-- Ignore decayed: let the account re-enter probe rotation.
			p.ignoredAt = 0
			p.probeSentAt = 0
		end
		if p
			and p.probeSentAt ~= 0
			and p.ignoredAt == 0
			and (now - p.probeSentAt) >= C.BNET_PROBE_DEADLINE
		then
			-- One shot missed its window: bench the account.
			p.ignoredAt = now
			p.probeSentAt = 0
			if ns.debugPeer then
				ns.debugPeer("bnet " .. id .. " ignored (unanswered probe)")
			end
		end
		local awaiting = p and p.probeSentAt ~= 0
		local ignored = p and p.ignoredAt ~= 0
		if not awaiting
			and not ignored
			and not self:isBNetConfirmed(id, now)
		then
			return id
		end
	end
	return nil
end

--- Record that a HELLO probe was queued to `id`; the account is awaiting
-- an answer until BNET_PROBE_DEADLINE benches it.
function Comms:markAwaiting(id, now)
	peerEntry(self.bnetPeers, id).probeSentAt = now
end

--- Whether we may send another HI reply to `id` (rate-limit vs spam).
function Comms:canHi(id, now)
	local p = self.bnetPeers[id]
	return not p or (now - p.lastHi) >= C.BNET_HI_COOLDOWN
end

function Comms:markHi(id, now)
	peerEntry(self.bnetPeers, id).lastHi = now
end

--- Peer buckets for inspection (/frp relays). Command-time tables.
function Comms:bnetPeerLists()
	local now = GetTime()
	local lists = { confirmed = {}, probing = {}, ignored = {} }
	for id, p in pairs(self.bnetPeers) do
		if p.ignoredAt ~= 0 and (now - p.ignoredAt) < C.BNET_IGNORE_TTL then
			lists.ignored[#lists.ignored + 1] = id
		elseif (now - p.confirmedAt) < C.BNET_CONFIRM_TTL then
			lists.confirmed[#lists.confirmed + 1] = id
		elseif p.probeSentAt ~= 0 then
			lists.probing[#lists.probing + 1] = id
		end
	end
	return lists
end

--- confirmed, probing, ignored counts (census).
function Comms:bnetPeerCounts()
	local lists = self:bnetPeerLists()
	return #lists.confirmed, #lists.probing, #lists.ignored
end

-- Inbound -------------------------------------------------------------------

function Comms:onChatMsgAddon(prefix, text, channel, sender)
	if prefix ~= self.prefix then
		return
	end
	if ns.Util.commsRestricted() then
		noteRestrictedResponses()
		return
	end

	-- Our own channel/group echo does not need to be read.
	if self.ownName and ns.Util.normalizeUnitName(sender) == self.ownName then
		if ns.statsError then
			ns.statsError("self_echo")
		end
		return
	end
	local ctx = self.chatCtx
	ctx.medium = channel
	ctx.senderName = sender
	ctx.senderKey = sender
	ctx.gameAccountID = nil
	self:handleIncoming(text, ctx)
end

function Comms:onBNChatMsgAddon(prefix, text, bnetIDGameAccount)
	if prefix ~= self.prefix then
		return
	end
	if ns.Util.commsRestricted() then
		noteRestrictedResponses()
		return
	end

	local key = bnetIDGameAccount and bnKeys[bnetIDGameAccount]
	if not key then
		key = "bn:" .. tostring(bnetIDGameAccount)
		if bnetIDGameAccount then
			bnKeys[bnetIDGameAccount] = key
		end
	end
	local ctx = self.bnCtx
	ctx.medium = "BNET"
	ctx.senderName = nil
	ctx.senderKey = key
	ctx.gameAccountID = bnetIDGameAccount
	self:handleIncoming(text, ctx)
end

--- Drop `senderKey`'s chunks before reassembly for REJECTED_SENDER_TTL.
-- The protocol version lives inside the envelope, so version-rejected
-- senders need this marker to stop their chunk stream early.
function Comms:blockSender(senderKey)
	if self.rejectedSenders[senderKey] then
		return
	end
	self.rejectedSenders[senderKey] = GetTime() + C.REJECTED_SENDER_TTL
	if ns.debugPeer then
		ns.debugPeer("blocked " .. tostring(senderKey) .. " (rejected protocol)")
	end
end

--- Reassemble a chunk; hand full messages to the message handler with
-- `context` (a shared scratch table, valid only for this call chain).
--- The reassembly senderKey for a (medium, target) pair: BNet accounts
-- key as "bn:<id>", chat media key by raw sender name.
function Comms:senderKeyFor(medium, target)
	if medium == "BNET" then
		return "bn:" .. tostring(target)
	end
	return target
end

function Comms:handleIncoming(chunkString, context)
	if ns.Util.commsRestricted() then
		noteRestrictedResponses()
		return -- inbound chunks are dropped outright while restricted
	end
	-- Reassembly is keyed by a stable per-sender identity.
	local senderKey = context.senderKey
	if ns.statsChunkIn then
		ns.statsChunkIn(context.medium, #chunkString)
	end
	local blockedUntil = senderKey and self.rejectedSenders[senderKey]
	if blockedUntil then
		if GetTime() < blockedUntil then
			return -- old-protocol/garbage stream: never reassembled
		end
		self.rejectedSenders[senderKey] = nil -- block decayed
	end
	if senderKey then
		self.lastChunkFrom[senderKey] = GetTime()
	end
	if ns.debugChunk then
		ns.debugChunk("in", context.medium, senderKey, #chunkString)
	end
	local full, chunks, elapsed, dupes = self.assembler:add(senderKey, chunkString)
	if full then
		if ns.statsIn then
			ns.statsIn(full, senderKey, context.medium, chunks, elapsed, dupes)
		end
		if self.messageHandler then
			self.messageHandler(full, context)
		end
	end
end

-- Singleton, started after login.
ns.comms = Comms:new()

-- //edit: registering events to update when we pause/resume
for _, event in ipairs({
	"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
	"CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED", "CHALLENGE_MODE_RESET",
	"ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD",
}) do
	ns.RegisterEvent(event, function()
		ns.comms:updateActivityState()
	end)
end

-- //edit: register before the login so we also get this loading screen
ns.RegisterEvent("LOADING_SCREEN_ENABLED", function()
	ns.comms:pauseForLoading()
end)

ns.RegisterEvent("LOADING_SCREEN_DISABLED", function()
	ns.comms.loading = false
	ns.comms.initialLoading = false
	ns.comms:resumeAfterLoading()
end)

ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
	local comms = ns.comms
	if comms.initialLoading or not comms.loading then
		comms:pauseForLoading()
		comms.loading = false
	end

	comms:resumeAfterLoading()

end)

ns.OnLogin(function()
	ns.comms:start()
end)
