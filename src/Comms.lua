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

local bnKeys = {} -- [gameAccountID] = "bn:<id>" senderKey (persistent)

function Comms:init()
	self.prefix = C.MSG_PREFIX
	self.assembler = ns.Serializer.ChunkReassembler:new()
	-- The paced outbound queue holds *descriptors* (pooled records), not
	-- closures: a send at steady state allocates nothing.
	self.queue = { head = 1, tail = 0 }
	self.sendCredit = 0 -- token bucket: chunks release at C.SEND_RATE/sec
	self.descAcquire, self.descRelease = ns.Util.newPool(C.POOL_SEND_DESC)
	self.messageHandler = nil -- set by Broadcast: fn(rawMessage, context)
	self.started = false
	-- Memoized online WoW BNet account ids (see bnetAccounts).
	self.bnetAcctMemo = { ids = {}, at = 0 }
	-- FRP1 BNet peer confirmation state, session-only, reset in place:
	--   [gameAccountID] = { confirmedAt, lastProbe, probes, ignoredAt, lastHi, version }
	self.bnetPeers = {}
	self.probeCursor = 0
	-- [senderKey] = GetTime() expiry — chunks from senders whose messages
	-- failed the version/malformed gates are dropped before reassembly.
	self.rejectedSenders = {}
	-- Scratch transport contexts, mutated per inbound event. Passed to the
	-- message handler — valid only for the duration of that synchronous call
	-- (scratch: do not retain).
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

	-- Friend presence churn: every event refreshes the online-account memo,
	-- but only an actual account coming online re-opens probing — INFO_CHANGED
	-- and FRIENDLIST_UPDATE fire on zone/status churn constantly and would
	-- otherwise keep resurrecting ignored accounts before their TTL.
	local function onFriendPresence()
		self.bnetAcctMemo.at = 0
	end
	local function onFriendOnline()
		self.bnetAcctMemo.at = 0
		for _, p in pairs(self.bnetPeers) do
			p.ignoredAt = 0
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
		local dropped = self.assembler:prune(C.REASSEMBLY_TIMEOUT)
		if dropped > 0 and ns.statsPruned then
			ns.statsPruned(dropped)
		end
	end)
end

--- Set the callback that receives fully-reassembled messages.
-- @param fn function Invoked as fn(rawMessage, context).
function Comms:setMessageHandler(fn)
	self.messageHandler = fn
end

-- Channel -------------------------------------------------------------------

--- Leave any FactionRP channel that is not our protocol generation: the
-- legacy "FactionRP" channel and "frp<N>comms" with a different N. Channel
-- membership survives /reload (it lives in the chat layer until logout), so
-- without this sweep an upgraded client keeps receiving old-protocol traffic
-- for the rest of the session.
function Comms:leaveForeignChannels()
	local current = C.COMM_CHANNEL:lower()
	-- Direct check for the legacy channel: cheap and independent of whether
	-- hidden channels enumerate in GetChannelList.
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

--- Join the hidden same-faction relay channel (no chat tab).
-- Joining is idempotent (client no-ops when already joined), but every join
-- still fires CHANNEL_UI_UPDATE/CHANNEL_COUNT_UPDATE toggles in the client.
-- Other add-ons listening to those events (notably TRP3's broadcast channel
-- manager, which repeatedly re-evaluates its own channel index while the list
-- churns) see extra work and can transiently resolve the wrong index.
function Comms:joinChannel()
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

-- Register an event so we can update our channel on reorder over the pipe.
hooksecurefunc(C_ChatInfo, "SwapChatChannelsByChannelIndex", function()
	C_Timer.After(0, function() 
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
	local q = self.queue
	q.tail = q.tail + 1
	q[q.tail] = desc
	if ns.statsQueue then
		ns.statsQueue(q.tail - q.head + 1)
	end
end

--- Interpret a queued descriptor and dispatch it through Chomp (or the raw
-- API fallback), recording the chunk/leg stats hooks. After dispatch the
-- descriptor is released back to the pool.
function Comms:sendDescriptor(desc)
	local text = desc.text
	if desc.kind == "CHANNEL" then
		desc.target = self:channelIndex() -- always refresh channelindex.
		if not desc.target then
			return
		end
	end
	if ns.statsChunkOut then
		ns.statsChunkOut(desc.kind, #text, GetTime() - desc.enqueuedAt)
	end
	if ns.debugChunk then
		ns.debugChunk("out", desc.kind, desc.target, #text)
	end
	-- The final chunk of a leg carries leg-completion fields so the stats
	-- collector can time the full message drain — no callback closure needed.
	if desc.legTotal and ns.statsOutLeg then
		ns.statsOutLeg(desc.kind, desc.target, desc.legBytes, desc.legTotal, GetTime() - desc.legStartedAt)
	end
	local chomp = AddOn_Chomp
	if desc.mode == "bnet" then
		if chomp and chomp.BNSendGameData then
			chomp.BNSendGameData(desc.target, self.prefix, text, "LOW")
			return
		end
		if BNSendGameData then
			BNSendGameData(desc.target, self.prefix, text)
		end
		return
	end
	-- Routing through Chomp (shipped by TRP3, and hence by every client
	-- running any major RP AddOn) means our bulk addon traffic is coalesced
	-- into the same global ChatThrottleLib queues as everyone else's addon
	-- traffic. Raw C_ChatInfo.SendAddonMessage bursts from the queue can
	-- stall other add-ons' queued CHANNEL messages (notably TRP3's C_SCAN
	-- map-scan requests, which are sent unthrottled at scan time and are
	-- sensitive to chat-frame send backoff).
	if chomp and chomp.SendAddonMessage then
		chomp.SendAddonMessage(self.prefix, text, desc.kind, desc.target, "LOW")
		return
	end
	if C_ChatInfo and C_ChatInfo.SendAddonMessage then
		C_ChatInfo.SendAddonMessage(self.prefix, text, desc.kind, desc.target)
	end
end

--- Release queued sends at C.SEND_RATE chunks/second. A fractional token
--- bucket keeps fractional rates smooth (7.5/s releases 1,2,1,2,... per
--- 0.2s tick); credit is capped at max(SEND_RATE, 1) -- one send's worth --
--- so an idle queue cannot bank an unbounded burst and sub-1/s rates can
--- still accumulate a send. The 1e-6 tolerance absorbs float accrual
--- (0.1*10 ~= 1.0 in binary). Invoked on a timer.
function Comms:flushQueue()
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
		-- Queue drained: reset indices so the array part stays small.
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
	local desc = self.descAcquire()
	desc.mode = "addon"
	desc.text = text
	desc.kind = kind
	desc.target = target
	desc.enqueuedAt = GetTime()
	self:enqueue(desc)
	return desc
end

--- Send one raw chunk to a Battle.net game account.
function Comms:sendBNet(text, gameAccountID)
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
-- The final chunk's descriptor carries leg-completion fields so the stats
-- collector can time how long a full message took to drain to this leg.

--- Whether a leg of `n` chunks fits within the queue bound. Legs drop whole:
-- a partial message is an incomplete at the far end plus wasted sibling sends.
local function legFits(comms, n)
	return comms:queueDepth() + n <= C.SEND_QUEUE_CAP
end

-- @return number|false Chunk count queued, or false when the whole leg was
--   dropped for capacity. Callers must not mark work as sent on false.
function Comms:sendChunksAddon(chunks, kind, target)
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

function Comms:sendChunksBNet(chunks, gameAccountID)
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
				then
					callback(acct.gameAccountID)
				end
			end
		end
	end
end

--- Online WoW Battle.net game account ids, memoized for C.BNET_MEMO seconds.
-- Enumerating friends allocates client tables per account; the fanout uses
-- this memoized list instead of a full scan per message.
-- @return table List of gameAccountIDs (do not mutate — shared reference).
function Comms:bnetAccounts()
	local memo = self.bnetAcctMemo
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
-- Any complete, parseable FactionRP message arriving over BNet confirms the
-- account (bnetPeerSeen).
-- Entries are reset in place; the map is bounded by the friends list.

local function peerEntry(peers, id)
	local p = peers[id]
	if not p then
		p = { confirmedAt = 0, lastProbe = 0, probes = 0, ignoredAt = 0, lastHi = 0, version = nil }
		peers[id] = p
	end
	return p
end

--- Stamp `id` as confirmed: it demonstrably runs FactionRP (it sent us a
-- parseable FRP message). Clears probe/ignore state and records the remote
-- addon version when supplied (control messages carry it).
function Comms:bnetPeerSeen(id, version)
	if not id then
		return
	end
	local p = peerEntry(self.bnetPeers, id)
	local was = p.confirmedAt
	p.confirmedAt = GetTime()
	p.probes = 0
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

--- Pick the next online account due for a HELLO probe (round-robin over the
-- memoized account list). Skips confirmed and ignored accounts; expired
-- ignores re-enter rotation. Does not stamp — the caller marks the probe
-- only if it actually queued.
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
			p.probes = 0
		end
		local ignored = p and p.ignoredAt ~= 0
		if not ignored
			and not self:isBNetConfirmed(id, now)
			and (not p or (now - p.lastProbe) >= C.BNET_PROBE_COOLDOWN)
		then
			return id
		end
	end
	return nil
end

--- Record that a HELLO probe was actually queued to `id`. Past
-- BNET_PROBE_MAX unanswered probes the account is ignored until
-- BNET_IGNORE_TTL (or a friend-presence event) re-opens it.
function Comms:markProbed(id, now)
	local p = peerEntry(self.bnetPeers, id)
	p.lastProbe = now
	p.probes = p.probes + 1
	if p.probes > C.BNET_PROBE_MAX and p.ignoredAt == 0 then
		p.ignoredAt = now
		if ns.debugPeer then
			ns.debugPeer("bnet " .. id .. " ignored (" .. p.probes .. " unanswered probes)")
		end
	end
end

--- Whether we may send another HI handshake reply to `id` (rate-limit so a
-- HELLO-spamming peer cannot drain our queue).
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
		elseif p.lastProbe ~= 0 then
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

--- Reassemble a chunk and, once a full message is available, hand it to the
-- registered message handler with transport context (used by Broadcast for
-- loop avoidance and to avoid echoing back to the source peer).
-- NOTE: `context` is a shared scratch table which is valid only for the duration of
-- this synchronous call chain (incl. messageHandler).
--- Mark a sender as rejected: their chunks are dropped before reassembly for
-- REJECTED_SENDER_TTL seconds. Called by the message layer when a complete
-- message fails the protocol-version or malformed gates — the version lives
-- inside the envelope, so chunk-level filtering is impossible without this
-- marker. Wire accounting (statsChunkIn) still counts their traffic.
function Comms:blockSender(senderKey)
	if self.rejectedSenders[senderKey] then
		return
	end
	self.rejectedSenders[senderKey] = GetTime() + C.REJECTED_SENDER_TTL
	if ns.debugPeer then
		ns.debugPeer("blocked " .. tostring(senderKey) .. " (rejected protocol)")
	end
end

function Comms:handleIncoming(chunkString, context)
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
ns.OnLogin(function()
	ns.comms:start()
end)
