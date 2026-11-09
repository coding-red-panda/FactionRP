-- Broadcast.lua
--
-- The pull-exchange engine. Requests are serial: one subject at a time,
-- REQ'd to a single contact, falling back to the faction channel on
-- silence. Every leg keeps REQ -> ACK -> OK -> data arbitration: only a
-- granted server serves, so denied or obsolete offers cost no data leg.
--
-- SENDER vs SUBJECT: SENDER is the immediate sender, used for loop
-- avoidance. SUBJECT is the profile owner.

local _, ns = ...
local C = ns.Const
local Serializer = ns.Serializer
local Util = ns.Util

local Broadcast = ns.Class("Broadcast")
ns.Broadcast = Broadcast

function Broadcast:init()
	self.playerGUID = nil -- refreshed per use by senderGUID()
	-- Cross-faction relay lifecycle (session-only), keyed by normalized
	-- "name-realm"; same probe/confirm/ignore shape as BNet peers.
	--   relays[key] = {
	--     name    display "Name-Realm" for sending/debugging,
	--     conf    last inbound-proof time (confirmed relay while fresh),
	--     lp      last probe sent        pr   consecutive unanswered probes,
	--     ign     ignored-since time     lastHi last HI we sent them,
	--     version peer's addon version (when seen)
	--     proto   peer's protocol generation (latest envelope stamp)
	--   }
	--   xfacContacts: proven cross-faction reachable RP-AddOn users, not
	--     necessarily FRP. Receipts also seed the probe rotation.
	self.relays = {}
	self.xfacContacts = {}

	-- Profiles queued for injection into the RP AddOn's register, drained
	-- at a bounded rate.
	self.injectQueue = {} -- [guid] = candidate
	self.injectOrder = { head = 1, tail = 0 } -- FIFO of guids

	-- Pinned whisper targets for testing (/frp debug target), keyed by
	-- normalized name; sent a copy of every issued REQ.
	self.forcedTargets = {}

	-- Pull-exchange state (session-only). At most one subject is in flight.
	--   requests[guid]  = { state, at, unitID,
	--     medium, target  -- unicast contact leg
	--     winner          -- granted server { medium, target }
	--     channeled       -- the one channel attempt was spent
	--     deadTarget      -- winner whose serve failed (excluded on rebroadcast)
	--     acks, waitAt    -- collected offers / chan-wait start
	--   }
	--   states: "contact" (unicast REQ awaiting ACK),
	--     "chan-wait" (channel REQ parked on REQ_CHANNEL_INTERVAL),
	--     "broadcast" (channel REQ collecting whispered ACKs),
	--     "awaiting-data" (grant issued, data expected)
	--   recentReqs[guid] = last request time (per-subject cooldown)
	--   reqMissed[guid] = last failed-pull time (tooltip "no response")
	--   reqQueued[guid] + reqQueueOrder: deduped FIFO of waiting subjects
	--   contactDecks: 3-tier draw/spent piles for unicast picks (BNet,
	--     guild, community). Entries { medium, target, key }. Pops move a
	--     served contact to spent and once every tier's draw is drained
	--     all spent piles reshuffle back, so order decorrelates across
	--     clients and each contact serves at most once per cycle.
	--   pendingServes[key] = { subject, unitID, medium, target, at, mesh, ok,
	--     peerGen }
	--     key = "<peer>:<guid>". ACK'd serves awaiting the requester's OK
	--     ok = grant already received while a serve-side refresh pends
	--     peerGen = requester's protocol generation (its REQ's clamped stamp)
	--   freshenPending[key] = { mode, subject, unitID, medium, target,
	--                           reqAt, reqPid, reqCvh, peerGen }
	--     mode "ack": channel REQ whose ACK waits on an RP-AddOn refresh
	--     mode "serve": unicast REQ whose serve waits on refresh and OK
	--     mode "fetch": unicast REQ for an unserved-but-pullable unit;
	--       the serve waits on the query landing real data
	--   reqSenderAt[senderKey] = last inbound unicast REQ time (throttle)
	--   chanReqSenderAt[senderName] = last inbound channel REQ time
	self.requests = {}
	self.recentReqs = {}
	self.reqMissed = {}
	self.pendingServes = {}
	self.freshenPending = {}
	self.reqQueued = {}
	--   fetchCache[guid] = { at, unitID } -- last on-demand pull we fired;
	--     fresh entries serve straight from the register, no re-query
	self.fetchCache = {}
	self.reqQueueOrder = { head = 1, tail = 0 }
	self.contactDecks = {
		{ draw = {}, spent = {}, have = {} },
		{ draw = {}, spent = {}, have = {} },
		{ draw = {}, spent = {}, have = {} },
	}
	self.reqSenderAt = {}
	self.chanReqSenderAt = {}
	self.lastChannelReqAt = 0 -- last broadcast REQ we sent (self-rate)
	self.fanoutInFlight = {} -- queue tail positions of issued probes
	self.relayProbeAt = 0 -- last whisper probe burst
	self.probeCursor = 0 -- rotating index into the flattened probe rosters
	self.probeSeeds = {} -- xfac contacts queued for priority probing
	self.probeSeedOrder = { head = 1, tail = 0 } -- FIFO of seeded keys

	-- Channel serve cooldown: while serveDrainPos tracks queued serve
	-- chunks we ACK no broadcast REQs; once a mesh serve's last chunk
	-- leaves the queue, broadcast REQs stay muted for a mesh-scaled window.
	self.serveMuteUntil = 0
	self.serveDrainPos = nil -- queue tail of the draining serve's last chunk
	self.serveDrainMesh = false -- a draining serve came from a mesh grant

	-- Version announcement: newest peer version heard this session, and the
	-- version we last printed an update notice for.
	self.topPeerVersion = nil
	self.notifiedVersion = nil
	self.verAttempts = 0
end

--- Own GUID, fetched fresh and validated on every use.
--- @return string|nil
function Broadcast:senderGUID()
	if Util.isPaused() then
		return nil
	end
	local guid = UnitGUID("player")
	self.playerGUID = Util.canWeUse(guid) and guid or nil
	return self.playerGUID
end

function Broadcast:start()
	self:senderGUID()
	ns.comms:setMessageHandler(function(raw, context)
		self:onMessage(raw, context)
	end)
	-- Register writes flush matching deferred replies early; the update
	-- signal fires after the save, the receipt signal before it.
	for _, adapter in pairs(ns.adapters) do
		adapter:registerUpdateListener(function(unitID)
			self:onFreshenReceived(unitID)
		end)
	end
	C_Timer.NewTicker(C.INJECT_INTERVAL, function()
		self:drainInject()
		self:pumpRequests()
	end)
	-- One ticker drives the BNet + whisper probe rotations and the sweeps.
	C_Timer.NewTicker(C.BNET_PROBE_INTERVAL, function()
		self:tick()
	end)

	-- Announce our addon version once per session. The channel join is
	-- async, so it retries while pending.
	C_Timer.After(C.VER_BROADCAST_DELAY, function()
		self:broadcastVersion()
	end)

	-- Opening the Communities UI streams member data in anyway; kick an
	-- early roster rebuild then. The frame lives in LoadOnDemand
	-- Blizzard_Communities, so hook it whenever it materialises.
	local hooked = false
	local function hookCommunitiesFrame()
		if hooked or not CommunitiesFrame then
			return
		end
		hooked = true
		CommunitiesFrame:HookScript("OnShow", function()
			Util.refreshClubRoster()
		end)
	end
	ns.RegisterEvent("ADDON_LOADED", function(_, name)
		if name == "Blizzard_Communities" then
			hookCommunitiesFrame()
		end
	end)
	hookCommunitiesFrame() -- may already be loaded (opened before login)

	-- The roster build requests member data per club via FocusMembers;
	-- the stream landing fires CLUB_MEMBERS_UPDATED. Rebuild then rather
	-- than wait out the defer retry (same ROSTER_UI_REFRESH rate gate).
	ns.RegisterEvent("CLUB_MEMBERS_UPDATED", function()
		Util.refreshClubRoster()
	end)
end

function Broadcast:pauseForLoading()

-- //edit: Keep cached profiles but do not resume transfers
	for _, peer in pairs(self.relays) do
		if peer.ign == 0 then
			peer.pr, peer.lp = 0, 0
		end
	end

	wipe(self.requests)
	wipe(self.reqQueued)
	wipe(self.reqQueueOrder)
	self.reqQueueOrder.head, self.reqQueueOrder.tail = 1, 0
	wipe(self.pendingServes)

	for _, pending in pairs(self.freshenPending) do
		if pending.mode == "fetch" then
			self.fetchCache[pending.subject] = nil
		end
	end

	wipe(self.freshenPending)
	wipe(self.fanoutInFlight)
	self.serveDrainPos = nil
	self.serveDrainMesh = false

end

-- Helpers -------------------------------------------------------------------

--- Fetch-or-create the relay record for `key`; `name` refreshes the
--- display name when given.
function Broadcast:relay(key, name)
	local p = self.relays[key]
	if not p then
		p = { name = name, conf = 0, lp = 0, pr = 0, ign = 0, lastHi = 0 }
		self.relays[key] = p
	elseif name then
		p.name = name
	end
	return p
end

--- Whether relay `p` is due a probe at `now` (nil = unprobed, due).
--- Expired silent members are marked ignored as a side effect.
function Broadcast:probeDue(p, target, now)
	if not p then
		return true
	end
	if p.ign ~= 0
		or (p.conf ~= 0 and (now - p.conf) < C.RELAY_CONFIRM_TTL)
	then
		return false
	end
	if p.pr >= C.RELAY_PROBE_MAX then
		-- Was quiet too long; get ignored.
		if (now - p.lp) >= C.RELAY_PROBE_COOLDOWN then
			p.ign = now
			if ns.debugPeer then
				ns.debugPeer("whisper " .. target
					.. " ignored (unanswered probe)")
			end
		end
		return false
	end
	return p.lp == 0 or (now - p.lp) >= C.RELAY_PROBE_COOLDOWN
end

--- Next queued xfac contact due a probe, drained ahead of the cursor.
--- Each seed is examined once and drops out either way.
function Broadcast:seedProbeTarget(now)
	local o = self.probeSeedOrder
	while o.head <= o.tail do
		local key = o[o.head]
		o[o.head] = nil
		o.head = o.head + 1
		self.probeSeeds[key] = nil
		local unitID = self.xfacContacts[key]
		local target = unitID and Util.fullUnitName(unitID)
		if target and target:sub(-1) ~= "-" and ns.comms:canWhisper(target)
			and self:probeDue(self.relays[key], target, now)
		then
			return key, target
		end
	end
	o.head, o.tail = 1, 0
end

--- Next probe target: queued seeds first, then the rotating cursor
--- over both rosters.
function Broadcast:whisperProbeTarget(now)
	local skey, starget = self:seedProbeTarget(now)
	if skey then
		return skey, starget
	end
	local guildRoster = Util.xfacGuildMembers()
	local commRoster = Util.xfacClubMembers()
	local gn = #guildRoster
	local total = gn + #commRoster
	if total == 0 then
		return
	end
	for step = 1, total do
		local idx = ((self.probeCursor + step - 1) % total) + 1
		local name = idx <= gn and guildRoster[idx] or commRoster[idx - gn]
		local key = Util.normalizeUnitName(name)
		local target = Util.fullUnitName(name)
		-- Realms can fail to resolve entirely mid-transition. Move on.
		if key and target and target:sub(-1) ~= "-" and ns.comms:canWhisper(target)
			and self:probeDue(self.relays[key], target, now)
		then
			self.probeCursor = idx
			return key, target
		end
	end
end

-- Control channel -----------------------------------------------------------

--- Own "Name-Realm", validated inside getUnitID each call.
local function ownUnitID()
	return Util.getUnitID("player") or ""
end

--- Highest generation a peer is known to speak, from its own envelope
--- stamps. nil means nothing recorded; send at own generation.
function Broadcast:peerGen(medium, target)
	if medium == "BNET" then
		local p = ns.comms.bnetPeers[target]
		return p and p.proto
	end
	-- Only whispers have a recorded relay generation; channel broadcasts
	-- have no single peer and encode at our own generation.
	if medium ~= "WHISPER" then
		return nil
	end
	local key = Util.normalizeUnitName(target)
	local p = key and self.relays[key]
	return p and p.proto
end

--- Generation to encode a leg for (medium, target): min(own, peerGen),
--- or nil when the peer's generation has no dialect.
function Broadcast:sendGenForPeer(medium, target)
	return ns.Dialect.sendGen(self:peerGen(medium, target))
end

--- Build (and chunk) a control envelope: subject "_frp", data per the
--- dialect for `gen`. Called at request/probe time only, not a hot path.
--- @return table|nil Chunk list, or nil when the dialect cannot encode.
function Broadcast:buildCtl(verb, fields, gen)
	local data = ns.Dialect.buildCtlData(verb, fields, gen)
	if not data then
		return nil
	end
	local message = Serializer.buildMessage({
		sender = self:senderGUID(),
		subject = C.CTL_SUBJECT,
		unitID = ownUnitID(),
		addon = "FRP",
		originTime = time(),
		contentVersion = "0",
		data = data,
	})
	return Serializer.chunk(message)
end

--- Handshake chunks are constant per session; build once, reuse forever.
function Broadcast:ctlHello()
	if not self._hello then
		self._hello = self:buildCtl("HELLO", { version = C.VERSION })
	end
	return self._hello
end

function Broadcast:ctlHi()
	if not self._hi then
		self._hi = self:buildCtl("HI", { version = C.VERSION })
	end
	return self._hi
end

--- Send a chunk-list to one peer: BNet to the gameAccountID, anything else
--- as a whisper to the named sender. A nil chunk list (a dialect could not
--- encode) counts as a send failure like a queue drop.
function Broadcast:sendToPeer(chunks, medium, target, meta)
	if not chunks then
		return false
	end
	if medium == "BNET" then
		return ns.comms:sendChunksBNet(chunks, target, meta)
	end
	return ns.comms:sendChunksAddon(chunks, "WHISPER", target, meta)
end

--- Send About chunks over a route: CHANNEL resolves the comm channel by
--- name at dispatch, WHISPER/BNET go through sendToPeer.
local function sendAboutChunks(chunks, route, meta)
	if route.medium == "CHANNEL" then
		return ns.comms:sendChunksChannel(chunks, C.COMM_CHANNEL, meta)
	end
	return ns.broadcast:sendToPeer(chunks, route.medium, route.target, meta)
end

-- Version announcement (issue #19) -------------------------------------------

--- Our installed addon version from the .toc metadata. C.VERSION is the
--- fallback when the field is missing.
local function ownVersion()
	return C_AddOns.GetAddOnMetadata(C.ADDON_NAME, "Version") or C.VERSION
end

--- One-time broadcast of our addon version on every channel we sit on, plus
--- the pinned stray channel of an amputated generation. VER is frozen
--- vocabulary, so one chunk build covers all of them. Retried while channel
--- joins pend; gives up after C.VER_BROADCAST_ATTEMPTS.
function Broadcast:broadcastVersion()
	if Util.isPaused() then
		self.versionPending = true
		return
	end
	self.versionPending = nil

	local version = ownVersion()
	-- Dev or prerelease suffixed versions stay quiet.
	if version:find("[^%d%.]") then
		return
	end
	local comms = ns.comms

	-- Stragglers on the amputated channel sit outside our join set; join it
	-- only long enough to launch the announcement there.
	local strayChan = C.VER_STRAY_CHANNEL
	local strayIdx = strayChan and GetChannelName(strayChan)
	if strayIdx == 0 then
		strayIdx = nil
	end
	if strayChan and not strayIdx then
		JoinTemporaryChannel(strayChan)
		strayIdx = GetChannelName(strayChan)
		if strayIdx == 0 then
			strayIdx = nil
		end
	end

	local idx = comms and comms:channelIndex()
	if Util.commsRestricted() or not idx or (strayChan and not strayIdx) then
		self.verAttempts = self.verAttempts + 1
		if self.verAttempts < C.VER_BROADCAST_ATTEMPTS then
			C_Timer.After(C.VER_BROADCAST_RETRY, function()
				self:broadcastVersion()
			end)
		elseif strayChan then
			LeaveChannelByName(strayChan)
		end
		if ns.debugPeer then
			ns.debugPeer("ver broadcast deferred (channel join pending)")
		end
		return
	end
	local chunks = self:buildCtl("VER", { version = version })
	if comms:sendChunksAddon(chunks, "CHANNEL", idx) then
		if ns.statsLeg then
			ns.statsLeg("ver", 1)
		end
		if ns.debugPeer then
			ns.debugPeer("ver " .. version .. " -> channel")
		end
	end
	for _, name in pairs(C.LEGACY_CHANNELS) do
		comms:sendChunksChannel(chunks, name)
	end
	if strayChan then
		if comms:sendChunksChannel(chunks, strayChan) and ns.debugPeer then
			ns.debugPeer("ver " .. version .. " -> " .. strayChan)
		end
		-- Keep membership until the paced queue has flushed the chunk.
		C_Timer.After(C.VER_PREV_CHANNEL_HOLD, function()
			LeaveChannelByName(strayChan)
		end)
	end
end

--- REQ fields: subject guid plus our unitID and held freshness (as-of
--- stamp, profileID, content-version hash) so stale holders can suppress
--- themselves. `mesh` sets the sampled-mesh flag.
local function reqFields(guid, unitID, mesh)
	local wire = unitID and Util.fullUnitName(unitID)
	if not wire then
		return { guid = guid }
	end
	local floor = ns.cache:freshnessFloor(guid, unitID)
	local pid, cvh = "-", "-"
	local adapter = ns.getAvailableAdapter()
	local meta = adapter and adapter.profileMeta
		and adapter:profileMeta(unitID)
	if meta then
		pid = meta.pid or "-"
		cvh = meta.cv and Util.hashStr(meta.cv) or "-"
	else
		local rec = ns.db and ns.db.seen and ns.db.seen[guid]
		if rec then
			pid = rec.pid or "-"
			cvh = rec.cv and Util.hashStr(rec.cv) or "-"
		end
	end
	return {
		guid = guid, unitID = wire, seenAt = floor,
		pid = pid, cvHash = cvh,
		flag = mesh and C.REQ_MESH_FLAG or nil,
	}
end

--- Whether the register's held copy is fresh enough to serve without a
--- refresh query: seen within SERVE_REFRESH_TTL, or clearly newer than the
--- requester's claim. `at` values are time() stamps.
local function serveFreshEnough(adapter, unitID, reqAt)
	local meta = adapter.profileMeta and adapter:profileMeta(unitID)
	local at = meta and meta.at
	if not at then
		return false
	end
	if time() - at < C.SERVE_REFRESH_TTL then
		return true
	end
	return reqAt and reqAt > 0 and at > reqAt + C.FRESHNESS_SKEW
end

-- Pull exchange --------------------------------------------------------------

---- Drop an in-flight request to the subject cooldown, stamp the miss for
--- the tooltip, and publish a held register copy so the subject still
--- renders (honest stale stamp; the mesh beats it when it can).
--- @return boolean Always true: the pump should advance.
local function dropReq(bcast, guid, req, now, why)
	bcast.requests[guid] = nil
	bcast.recentReqs[guid] = now
	bcast.reqMissed[guid] = now
	bcast:publishHeld(guid, req.unitID)
	if ns.debugPeer then
		ns.debugPeer("req " .. (req.unitID or Util.nameForGuid(guid))
			.. " " .. why)
	end
	return true
end

--- BNet and whisper probe rotations plus exchange expiry, one ticker.
function Broadcast:tick()
	if Util.isPaused() then
		return
	end

	local now = GetTime()
	local comms = ns.comms
	local restricted = Util.commsRestricted()

	-- Request lifecycle: silence is rejection at every stage. Contact and
	-- data failures fall back to the same-faction channel once per request
	-- for stranger subjects; everything else drops to the subject cooldown.
	local pump = false
	for guid, req in pairs(self.requests) do
		if restricted and req.state == "contact" and req.sentAt then
			req.responseRestricted = true
		end

		if req.state == "contact"
			and (req.sendFailed
				or now > (req.sentAt and (req.sentAt + C.REQ_CONTACT_TIMEOUT)
					or req.sendDeadline or (req.at + C.REQ_CONTACT_TIMEOUT)))

		then
			if req.medium == "WHISPER" and req.sentAt and not req.responseRestricted then
				ns.comms:backoffWhisper(req.target)
			end

			if not self:tryChannelFallback(guid, req, now) then
				pump = dropReq(self, guid, req, now, "dropped (contact silent)")
			end
		elseif req.state == "chan-wait" then
			if (now - req.waitAt) > C.REQ_CHANNEL_WAIT_MAX then
				pump = dropReq(self, guid, req, now, "dropped (channel wait)")
			elseif not restricted then
				-- Restricted: replies would be dropped inbound anyway;
				-- stay parked.
				self:pumpChannelReq(guid, req, now)
			end
		elseif req.state == "broadcast"
			and (now - req.at) > C.REQ_CHANNEL_WINDOW
		then
			-- Window closed: grant the freshest offer, else a silent miss.
			if not self:grantBestOffer(guid, req, now) then
				pump = dropReq(self, guid, req, now, "dropped (channel silent)")
			end
		elseif req.state == "awaiting-data" then
			local srcMedium = (req.winner and req.winner.medium) or req.medium
			local srcTarget = (req.winner and req.winner.target) or req.target
			local srcKey = srcMedium and srcTarget
				and comms:senderKeyFor(srcMedium, srcTarget)
			-- Stall detection: no chunk from the server since the grant
			-- (or since its last chunk) for REQ_DATA_STALL. Chunks predating
			-- the grant do not count toward liveness.
			local lastChunk = srcKey and comms.lastChunkFrom[srcKey]
			local activity = (lastChunk and lastChunk > req.at)
				and lastChunk or req.at
			local stalled = (now - activity) > C.REQ_DATA_STALL
			-- Deadline comes from the serve's first-chunk total: drain
			-- estimate + jitter + queue backlog + stall grace.
			local _, streamTotal = srcKey and comms.assembler:progress(srcKey)
			local deadline = req.at + C.REQ_DATA_TIMEOUT
			if streamTotal then
				req.jitter = req.jitter or (1 + math.random() * C.REQ_DATA_JITTER_PCT)
				deadline = req.at + (streamTotal / C.SEND_RATE) * req.jitter
					+ comms:queueDepth() / C.SEND_RATE + C.REQ_DATA_STALL
			end
			if stalled or now > deadline then
				-- The serve stalled or died; drop the sender's partial
				-- chunks so a resumed send cannot complete a ghost message.
				if srcKey
					and comms.assembler:drop(srcKey) > 0
					and ns.debugPeer
				then
					ns.debugPeer("dropped partial data from " .. tostring(srcKey))
				end
				if req.winner then
					req.deadTarget = req.winner.target
				end
				if not self:tryChannelFallback(guid, req, now) then
					pump = dropReq(self, guid, req, now, stalled
						and "dropped (serve stalled)"
						or "expired (awaiting-data)")
				end
			end
		end
	end
	if pump and not restricted then
		self:pumpRequests()
	end

	if restricted then
		return -- no probes, sends, or further transitions while restricted
	end

	-- Burst HELLOs to every eligible BNet account: the paced send queue
	-- does the wire throttling, the shared in-flight budget bounds each
	-- tick's wave, and unanswered probes bench their account at the
	-- deadline inside probeTarget.
	local hello = self:ctlHello()
	while self:fanoutsInFlight() < C.FANOUT_INFLIGHT_MAX do
		local id = comms:probeTarget(now)
		if not id or not comms:sendChunksBNet(hello, id) then
			break
		end
		comms:markAwaiting(id, now)
		self.fanoutInFlight[#self.fanoutInFlight + 1] = comms.queue.tail
		if ns.statsLeg then
			ns.statsLeg("bnet_probe", 1)
		end
		if ns.debugPeer then
			ns.debugPeer("probe -> bnet " .. id)
		end
	end

	-- Whisper relay probes in bursts. The rotation returns unconfirmed
	-- candidates only; a saturated queue ends the burst early. The gate
	-- also needs budget headroom or a BNet wave would consume the window
	-- without a whisper going out.
	if (now - self.relayProbeAt) >= C.RELAY_PROBE_INTERVAL
		and self:fanoutsInFlight() < C.FANOUT_INFLIGHT_MAX
	then
		self.relayProbeAt = now
		-- An ignored member observed offline gets a fresh slate: silence
		-- while online reads as "doesn't run FRP", while silence during an
		-- absence explains itself. Online-but-silent stays ignored
		-- regardless of age — the probe budget goes to plausible FRP users
		-- only.
		for key, p in pairs(self.relays) do
			if key:sub(-1) == "-" then
				-- Keyed while the realm was unresolvable; a "name-" stub
				-- can never be whispered to or confirmed by an inbound.
				self.relays[key] = nil
				if ns.debugPeer then
					ns.debugPeer("whisper " .. key
						.. " dropped (realm unresolved)")
				end
			elseif p.ign ~= 0 and Util.isClubMemberOffline(p.name or key) then
				p.ign, p.pr = 0, 0
				if ns.debugPeer then
					ns.debugPeer("whisper " .. tostring(p.name or key)
						.. " unignored (offline)")
				end
			end
		end
		for _ = 1, C.RELAY_PROBE_BURST do
			if self:fanoutsInFlight() >= C.FANOUT_INFLIGHT_MAX then
				break
			end
			local wkey, wname = self:whisperProbeTarget(now)
			if not wkey then
				break
			end
			local p = self:relay(wkey, wname)
			if comms:sendChunksAddon(self:ctlHello(), "WHISPER", wname) then
				p.lp = now
				p.pr = p.pr + 1
				self.fanoutInFlight[#self.fanoutInFlight + 1] = comms.queue.tail
				if ns.statsLeg then
					ns.statsLeg("wprobe", 1)
				end
				if ns.debugPeer then
					ns.debugPeer("probe -> whisper " .. wname)
				end
			end
		end
	end

	-- Expire grants we were never asked to serve.
	for key, serve in pairs(self.pendingServes) do
		if (now - serve.at) > C.SERVE_TIMEOUT then
			self.pendingServes[key] = nil
		end
	end

	-- Arm the post-serve cooldown as soon as a serve's last chunk drains,
	-- even if no REQ arrives to trip the lazy check in serveThrottled.
	self:serveDraining(now)

	-- Prune the unicast REQ throttle; entries only matter within the window.
	for sender, at in pairs(self.reqSenderAt) do
		if (now - at) > C.REQ_SENDER_INTERVAL then
			self.reqSenderAt[sender] = nil
		end
	end
	for sender, at in pairs(self.chanReqSenderAt) do
		if (now - at) > C.REQ_CHANNEL_SENDER_INTERVAL then
			self.chanReqSenderAt[sender] = nil
		end
	end
	-- Miss markers only matter to the tooltip inside the cooldown window.
	for guid, at in pairs(self.reqMissed) do
		if (now - at) > C.REQ_COOLDOWN then
			self.reqMissed[guid] = nil
		end
	end
	for guid, rec in pairs(self.fetchCache) do
		if (now - rec.at) > C.REQ_FETCH_TTL then
			self.fetchCache[guid] = nil
		end
	end

end

--- Pull status for one subject, for the tooltip indicator: "asking" while
--- queued or any pre-grant state is in flight, "receiving" plus chunk
--- progress once a serve is granted, "miss" plus seconds until the subject
--- may be requested again inside the cooldown window after a failed pull.
--- nil means nothing worth showing.
function Broadcast:reqStatus(guid)
	local req = self.requests[guid]
	if req then
		if req.state == "awaiting-data" then
			local medium = (req.winner and req.winner.medium) or req.medium
			local target = (req.winner and req.winner.target) or req.target
			local got, total
			if medium and target then
				got, total = ns.comms.assembler:progress(
					ns.comms:senderKeyFor(medium, target))
			end
			return "receiving", got, total
		end
		return "asking"
	end
	if self.reqQueued[guid] then
		return "asking"
	end
	local missedAt = self.reqMissed[guid]
	if missedAt then
		return "miss", math.max(0, math.ceil(
			C.REQ_COOLDOWN - (GetTime() - missedAt)))
	end
	return nil
end

--- Check if `guid` is so fresh that pulling it is pointless.
function Broadcast:profileFresh(guid)
	return ns.cache:fresh(guid) or self:heldSuppressed(guid)
end

--- Queue a request for `guid`'s profile. No-op when the subject's data is
--- fresh, the subject is pending or queued, or it is on cooldown.
function Broadcast:requestProfile(guid, unitID)
	if not guid or Util.commsRestricted() then
		return
	end
	if self:profileFresh(guid)
		or self.requests[guid]
		or self.reqQueued[guid]
	then
		return
	end
	local now = GetTime()
	local last = self.recentReqs[guid]
	if last and (now - last) < C.REQ_COOLDOWN then
		return
	end
	-- Bounded FIFO; oldest waits drop on overflow.
	local o = self.reqQueueOrder
	while (o.tail - o.head + 1) >= C.REQ_BACKLOG_CAP do
		local old = o[o.head]
		o[o.head] = nil
		o.head = o.head + 1
		self.reqQueued[old.guid] = nil
	end
	o.tail = o.tail + 1
	o[o.tail] = { guid = guid, unitID = unitID }
	self.reqQueued[guid] = true
	self:pumpRequests()
end

--- Count of initiated sends whose chunks have not fully left the queue.
--- A send's chunks enqueue contiguously, so the queue tail position recorded
--- at issue is in flight until the head passes it.
function Broadcast:fanoutsInFlight()
	local q = ns.comms.queue
	if q.tail < q.head then
		for i = #self.fanoutInFlight, 1, -1 do
			self.fanoutInFlight[i] = nil
		end
		return 0
	end
	local w = 0
	for i = 1, #self.fanoutInFlight do
		local pos = self.fanoutInFlight[i]
		if pos <= q.tail and pos >= q.head then
			w = w + 1
			self.fanoutInFlight[w] = pos
		end
	end
	for i = #self.fanoutInFlight, w + 1, -1 do
		self.fanoutInFlight[i] = nil
	end
	return w
end

--- Issue the next queued subject when no request is in flight.
--- Entries are re-validated on release.
function Broadcast:pumpRequests()
	if Util.commsRestricted() or next(self.requests) then
		return -- restricted, or serial: one request in flight
	end
	local o = self.reqQueueOrder
	local now = GetTime()
	while o.head <= o.tail do
		local entry = o[o.head]
		o[o.head] = nil
		o.head = o.head + 1
		self.reqQueued[entry.guid] = nil
		local last = self.recentReqs[entry.guid]
		if not self:profileFresh(entry.guid)
			and not (last and (now - last) < C.REQ_COOLDOWN)
		then
			self:issueRequest(entry.guid, entry.unitID, now)
			break
		end
	end
	if o.head > o.tail then
		o.head, o.tail = 1, 0
	end
end

-- Contact decks --------------------------------------------------------------
-- A cursor over a list rebuilt per pick orders identically on every client
-- holding the same relays, so identical first picks converge on the same
-- members. Per-tier draw/spent piles scramble that order instead: pops
-- move a served contact to spent and an emptied draw pile recycles spent
-- after a reshuffle, so every contact serves at most once per cycle.

local function deckShuffle(list)
	for i = #list, 2, -1 do
		local j = math.random(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

--- Register an eligible contact in its tier deck. New faces insert at a
--- random draw position. `have` dedupes so a contact never double-books.
function Broadcast:deckAdd(tier, medium, target, key)
	local deck = self.contactDecks[tier]
	if deck.have[key] then
		return
	end
	deck.have[key] = true
	table.insert(deck.draw, math.random(1, #deck.draw + 1), {
		medium = medium, target = target, key = key,
	})
end

--- Whether a queued contact could still be served right now. Entries go
--- stale as confirmations decay, members go offline, or rosters shift.
function Broadcast:deckLive(entry, now)
	if entry.medium == "BNET" then
		return ns.comms:isBNetConfirmed(entry.target, now)
	end
	local p = self.relays[entry.key]
	return p ~= nil and p.conf ~= 0 and ns.comms:canWhisper(entry.target)
		and (now - p.conf) < C.RELAY_CONFIRM_TTL
		and Util.isClubMemberOnline(p.name)
		and (Util.isGuildClubMember(p.name)
			or Util.isCommunityClubMember(p.name))
end

--- Fold newly-eligible contacts into the tier decks: confirmed BNet peers
--- in tier 1, online guild relays in 2, community relays in 3.
function Broadcast:deckRefresh(now)
	local comms = ns.comms
	for _, id in ipairs(comms:bnetAccounts()) do
		if comms:isBNetConfirmed(id, now) then
			self:deckAdd(1, "BNET", id, "bn:" .. id)
		end
	end
	for key, p in pairs(self.relays) do
		if p.conf ~= 0 and (now - p.conf) < C.RELAY_CONFIRM_TTL
			and ns.comms:canWhisper(p.name)
			and Util.isClubMemberOnline(p.name)
		then
			if Util.isGuildClubMember(p.name) then
				self:deckAdd(2, "WHISPER", p.name, key)
			elseif Util.isCommunityClubMember(p.name) then
				self:deckAdd(3, "WHISPER", p.name, key)
			end
		end
	end
end

--- Pop the next live contact across the tier decks into spent. Tier
--- order is cycle ordering, not exhaustion: once every tier's draw pile
--- is drained all spent piles reshuffle back for the next cycle.
function Broadcast:contactNext(now, excludedKey)
	for _ = 1, 2 do
		for tier = 1, 3 do
			local deck = self.contactDecks[tier]
			while #deck.draw > 0 do
				local entry = table.remove(deck.draw, 1)
				if self:deckLive(entry, now) then
					deck.spent[#deck.spent + 1] = entry
					if entry.key ~= excludedKey then
						return entry
					end
				else
					deck.have[entry.key] = nil
				end
			end
		end
		local any = false
		for tier = 1, 3 do
			local deck = self.contactDecks[tier]
			if #deck.spent > 0 then
				deck.draw, deck.spent = deck.spent, deck.draw
				deckShuffle(deck.draw)
				any = true
			end
		end
		if not any then
			return nil
		end
	end
	return nil
end

--- Pick the contact for a unicast REQ. A BNet-reachable subject wins
--- outright. Otherwise the tier decks hand out BNet peers, then guild
--- relays, then community relays.
function Broadcast:reqContact(guid, now, excluded)
	local comms = ns.comms
-- //edit: "about" fallback skip the contact we already tried including deck entry
	local excludedKey = excluded and (excluded.medium == "BNET" and "bn:" .. excluded.target
		or Util.normalizeUnitName(excluded.target))
	if guid then
		local info = C_BattleNet.GetGameAccountInfoByGUID(guid)
		local id = info and info.gameAccountID
		if id and "bn:" .. id ~= excludedKey and comms:isBNetConfirmed(id, now) then
			return { medium = "BNET", target = id }
		end
	end
	self:deckRefresh(now)
	local entry = self:contactNext(now, excludedKey)
	if entry then
		return { medium = entry.medium, target = entry.target }
	end
	return nil
end

--- Issue one request as a unicast REQ to the next contact.
function Broadcast:issueRequest(guid, unitID, now)
	-- Stamp the cooldown up front so a failed send cannot retry-storm.
	self.recentReqs[guid] = now
	local comms = ns.comms
	local contact = self:reqContact(guid, now)
	local chunks = contact
		and self:buildCtl("REQ", reqFields(guid, unitID),
			self:sendGenForPeer(contact.medium, contact.target))
	local queueStart = comms.queue.tail
	if not chunks
		or not self:sendToPeer(chunks, contact.medium, contact.target)
	then
		-- Nobody reachable: stranger subjects still get the channel leg.
		local req = {
			state = "chan-wait", at = now, waitAt = now, unitID = unitID,
		}
		self.requests[guid] = req
		if not self:tryChannelFallback(guid, req, now) then
			self.requests[guid] = nil
			self:publishHeld(guid, unitID) -- held copy still beats nothing
		end
		return
	end
	self.fanoutInFlight[#self.fanoutInFlight + 1] = comms.queue.tail

	local req = {
		state = "contact", at = now, unitID = unitID,
		medium = contact.medium, target = contact.target,
		sendDeadline = now + C.REQ_CONTACT_TIMEOUT + comms:queueDepth() / C.SEND_RATE,
	}

	self.requests[guid] = req
-- //edit: queue time is not silence from the contact so start waiting after this request leaves our queue
	for i = queueStart + 1, comms.queue.tail 
	do
		local desc = comms.queue[i]
		desc.contactRequest = req
		desc.contactSubject = guid
		desc.contactLast = i == comms.queue.tail
	end

	if ns.debugEnabled("targets") then
		for _, name in pairs(self.forcedTargets) do
			comms:sendChunksAddon(chunks, "WHISPER", name)
		end
	end
	if ns.statsLeg then
		ns.statsLeg("req", 1)
	end
	if ns.debugFanout then
		ns.debugFanout(contact.medium .. " " .. tostring(contact.target))
	end
	if ns.debugPeer then
		ns.debugPeer("req " .. (unitID or Util.nameForGuid(guid)) .. " -> "
			.. contact.medium .. " " .. tostring(contact.target))
	end
end

--- Whether `guid` may be asked over the same-faction channel. Stranger
--- subjects only: a shared club, group membership, or BNet friendship
--- already provides a direct or native pull path, so broadcasting would
--- duplicate work the rest of the system already does.
function Broadcast:channelEligible(guid, unitID)
	if not unitID then
		return false -- cannot prove non-membership without a name
	end
	if Util.isGuildClubMember(unitID) or Util.isCommunityClubMember(unitID) then
		return false
	end
	local info = C_BattleNet.GetGameAccountInfoByGUID(guid)
	if info and info.gameAccountID then
		return false -- BNet friend: the unicast leg covers them
	end
	if Util.isGroupGuid(guid) then
		return false -- group members exchange natively
	end
	return true
end

--- Local request suppression while the register still holds a copy we
--- accepted recently. noteSeen re-arms holdUntil on every accepted store;
--- a register purge (profileMeta nil) releases the suppression early.
function Broadcast:heldSuppressed(guid)
	local rec = ns.db and ns.db.seen and ns.db.seen[guid]
	if not rec or not rec.holdUntil or not rec.unitID
		or time() >= rec.holdUntil
	then
		return false
	end
	local adapter = (rec.addon and ns.getAdapter(rec.addon))
		or ns.getAvailableAdapter()
	local meta = adapter and adapter.profileMeta
		and adapter:profileMeta(rec.unitID)
	return meta ~= nil
end

--- Publish our own held register copy, when servable. Zero wire cost: the
--- honest (possibly stale) originTime stamps it as a floor, fresher mesh
--- data still wins on landing, and it gives the requester content even
--- when the mesh misses entirely.
function Broadcast:publishHeld(guid, unitID)
	if Util.isPaused() then
		return false
	end

	local adapter = ns.getAvailableAdapter()
	if not (unitID and adapter and adapter.canServe
		and adapter:canServe(unitID))
	then
		return
	end
	if adapter.isDefaultUnit and adapter:isDefaultUnit(unitID) then
		return -- default stub: not content
	end
	local profile = adapter:extract(unitID)
	if profile then
		self:publish(guid, unitID, profile)
	end
end

--- Up to REQ_MESH_SAMPLE_SIZE random channel members for a sampled mesh
--- REQ, or nil while the roster has no usable names.
function Broadcast:meshSample()
	local comms = ns.comms
	local roster = comms:meshRoster()
	if not roster then
		return nil
	end
	local own = comms.ownName
	local names, n = {}, 0
	for i = 1, #roster do
		local full = Util.fullUnitName(roster[i])
		-- A realm that fails to resolve can never be whispered to.
		if full and full:sub(-1) ~= "-" then
			local key = Util.normalizeUnitName(full)
			if key and key ~= own then
				n = n + 1
				names[n] = full
			end
		end
	end
	if n == 0 then
		return nil
	end
	-- Partial Fisher-Yates: the first picks land in order.
	local targets = {}
	for k = 1, math.min(C.REQ_MESH_SAMPLE_SIZE, n) do
		local j = math.random(k, n)
		names[k], names[j] = names[j], names[k]
		targets[k] = names[k]
	end
	return targets
end

--- Whisper a flagged mesh REQ to a random member sample.
--- @return number Legs actually queued (0 = stay parked).
function Broadcast:sendSampledReq(guid, req)
	local targets = self:meshSample()
	if not targets then
		return 0
	end
	local comms = ns.comms
	local chunks = self:buildCtl("REQ", reqFields(guid, req.unitID, true),
		C.PROTO_MAJOR)
	local legs = 0
	for _, name in ipairs(targets) do
		if comms:sendChunksAddon(chunks, "WHISPER", name) then
			legs = legs + 1
			self.fanoutInFlight[#self.fanoutInFlight + 1] = comms.queue.tail
		end
	end
	if legs > 0 then
		if ns.statsLeg then
			ns.statsLeg("req_mesh", legs)
		end
		if ns.debugPeer then
			ns.debugPeer("req " .. (req.unitID or Util.nameForGuid(guid))
				.. " -> mesh sample x" .. legs)
		end
	end
	return legs
end

--- Promote `req` from chan-wait to broadcast when the self-rate gate is
--- open: a channel REQ on thin meshes, a flagged whisper sample on dense
--- ones. Missing channel/roster or a full queue stays parked.
function Broadcast:pumpChannelReq(guid, req, now)
	if (now - self.lastChannelReqAt) < C.REQ_CHANNEL_INTERVAL then
		return
	end
	local comms = ns.comms
	local legs = 0
	if comms:meshCount() > C.REQ_MESH_SAMPLE_AT then
		legs = self:sendSampledReq(guid, req)
	end
	local fields = reqFields(guid, req.unitID)
	local function chanReq(gen, name)
		if not comms:channelIndexFor(name) then
			return
		end
		local chunks = self:buildCtl("REQ", fields, gen)
		if chunks and comms:sendChunksChannel(chunks, name) then
			legs = legs + 1
			self.fanoutInFlight[#self.fanoutInFlight + 1] = comms.queue.tail
			if ns.debugPeer then
				ns.debugPeer("req " .. (req.unitID or Util.nameForGuid(guid))
					.. " -> " .. name)
			end
		end
	end
	if comms:meshCount() <= C.REQ_MESH_SAMPLE_AT then
		-- Thin mesh: broadcast. Stay parked until the channel is joined.
		if not comms:channelIndex() then
			return
		end
		chanReq(C.PROTO_MAJOR, C.COMM_CHANNEL)
	end
	-- The legacy bridge reaches the older fleet in its own dialect,
	-- dense mesh or thin.
	for gen, name in pairs(C.LEGACY_CHANNELS) do
		chanReq(gen, name)
	end
	if legs == 0 then
		return
	end
	self.lastChannelReqAt = now
	if ns.statsLeg then
		ns.statsLeg("req_chan", legs)
	end
	req.state = "broadcast"
	req.at = now
	req.acks = {}
end

--- Whether any confirmed relay could take a unicast REQ right now: a
--- BNet-confirmed subject or peer, or a confirmed online club relay.
--- Mirrors reqContact's roster without touching the cursor.
function Broadcast:hasContact(guid, now)
	local comms = ns.comms
	if guid then
		local info = C_BattleNet.GetGameAccountInfoByGUID(guid)
		local id = info and info.gameAccountID
		if id and comms:isBNetConfirmed(id, now) then
			return true
		end
	end
	for _, id in ipairs(comms:bnetAccounts()) do
		if comms:isBNetConfirmed(id, now) then
			return true
		end
	end
	for _, p in pairs(self.relays) do
		if p.conf ~= 0 and (now - p.conf) < C.RELAY_CONFIRM_TTL
			and ns.comms:canWhisper(p.name)
			and Util.isClubMemberOnline(p.name)
			and (Util.isGuildClubMember(p.name)
				or Util.isCommunityClubMember(p.name))
		then
			return true
		end
	end
	return false
end

--- Move a failed request onto the channel leg, once per request, for
--- eligible stranger subjects, and only while we hold no confirmed relay:
--- the mesh exists for cold-start coverage, not as a fallback to relays.
--- Our own held copy publishes first: free content while offers collect.
--- @return boolean Whether the request lives on (false = drop it).
function Broadcast:tryChannelFallback(guid, req, now)
	if req.channeled or not self:channelEligible(guid, req.unitID)
		or self:hasContact(guid, now)
	then
		return false
	end
	req.channeled = true
	self:publishHeld(guid, req.unitID)
	req.state = "chan-wait"
	req.waitAt = now
	self:pumpChannelReq(guid, req, now)
	return true
end

--- Collect window closed: grant the freshest offer by
--- max(content claim, directory last-seen), ties to the earliest arrival.
--- Denied offerers are never told; their pendingServes expire on their own.
--- @return boolean Whether a grant went out.
function Broadcast:grantBestOffer(guid, req, now)
	local best
	for _, offer in ipairs(req.acks) do
		offer.score = math.max(offer.offerAt, offer.dirAt)
		if not best or offer.score > best.score then
			best = offer
		end
	end
	if not best then
		return false
	end
	if not self:sendToPeer(
		self:buildCtl("OK", { guid = guid }, best.gen),
		best.medium, best.target)
	then
		return false
	end
	req.winner = { medium = best.medium, target = best.target }
	req.state = "awaiting-data"
	req.at = now
	req.acks = nil
	if ns.statsLeg then
		ns.statsLeg("ok", 1)
	end
	if ns.debugPeer then
		ns.debugPeer("ack " .. (req.unitID or Util.nameForGuid(guid))
			.. " <- " .. tostring(best.target) .. " (granted, best offer)")
	end
	return true
end

--- The freshness claim we can honestly make for a subject: our persisted
--- record's as-of stamp, or the register's last-seen stamp when it holds
--- content the record does not cover. Self is authoritative.
function Broadcast:claimAt(guid, unitID, addonName)
	if guid == self:senderGUID() then
		return time()
	end
	local rec = ns.db and ns.db.seen and ns.db.seen[guid]
	local adapter = (addonName and ns.getAdapter(addonName))
		or ns.getAvailableAdapter()
	local meta = adapter and adapter.profileMeta and unitID
		and adapter:profileMeta(unitID)
	if meta and meta.at then
		-- Register content the record does not cover arrived after it, so
		-- its bind stamp is an honest receipt time. An identical copy's
		-- stamp may be our own injection re-dated.
		if not rec or meta.cv ~= rec.cv then
			return meta.at
		end
		return rec.at or meta.at
	end
	return (rec and rec.at) or time()
end

--- Send the requested profile directly to a granted peer.
function Broadcast:serveData(serve)
	if Util.isPaused() then
		return
	end
	local adapter = ns.getAvailableAdapter()
	local profile = adapter and adapter:extract(serve.unitID)
	local encoded = profile and ns.Dialect.encodeProfile(profile.data,
		ns.Dialect.sendGen(serve.peerGen))
	if not encoded then
		if ns.statsError then
			ns.statsError("encode_fail")
		end
		return
	end
	local message = Serializer.buildMessage({
		sender = self:senderGUID(),
		subject = serve.subject,
		unitID = serve.unitID,
		addon = profile.addon,
		-- Claim the copy's own freshness, not now, so a stale copy stays
		-- stale on the wire.
		originTime = self:claimAt(serve.subject, serve.unitID, profile.addon),
		contentVersion = profile.contentVersion,
		data = encoded,
	})
	local chunks = Serializer.chunk(message)
	if not self:sendToPeer(chunks, serve.medium, serve.target) then
		return -- leg dropped for capacity: nothing queued, nothing to mute
	end
	-- Track the drain: a serve's chunks enqueue contiguously, so the tail
	-- position is in flight until the head passes it. Mesh (channel-path
	-- and sampled-flagged) serves arm the post-serve cooldown on drain.
	-- Self-serves are exempt.
	self.serveDrainPos = ns.comms.queue.tail
	if (serve.mesh
			or (serve.medium ~= "WHISPER" and serve.medium ~= "BNET"))
		and serve.subject ~= self:senderGUID()
	then
		self.serveDrainMesh = true
	end
	if ns.statsOutMessage then
		ns.statsOutMessage(#message, #chunks, serve.subject, "serve")
	end
	if ns.statsLeg then
		ns.statsLeg("serve", 1)
	end
	if ns.debugPeer then
		ns.debugPeer("serve " .. (serve.unitID or Util.nameForGuid(serve.subject))
			.. " -> " .. serve.target)
	end
end

--- Resolve a request subject's guid to a unitID by consensus: the cache's
--- guid->unitID map, the client player-info cache, the club roster, and the
--- wire-asserted unitID must all agree. Any conflict or empty claim set is
--- a miss.
--- @param guid       string The requested subject GUID.
--- @param wireUnitID string The requester-asserted unitID ("" when absent).
--- @return string|nil The consensus unitID, or nil on conflict/no claims.
function Broadcast:resolveSubject(guid, wireUnitID)
	local unitID, conflict = nil, false
	local function claim(id)
		id = id and Util.fullUnitName(id)
		if not id then
			return
		end
		if unitID and unitID ~= id then
			conflict = true
		end
		unitID = id
	end
	local entry = ns.cache:get(guid)
	claim(entry and entry.unitID)
	claim(Util.unitForGuidFromClient(guid))
	claim(Util.unitForGuid(guid))
	local hadLocal = unitID ~= nil
	claim(wireUnitID ~= "" and wireUnitID or nil)
	if conflict then
		if ns.debugPeer then
			ns.debugPeer("req " .. Util.nameForGuid(guid)
				.. " dropped (identity conflict)")
		end
		return nil
	end
	if unitID and not hadLocal then
		if ns.debugPeer then
			ns.debugPeer("req " .. Util.nameForGuid(guid)
				.. " resolved via wire unitID " .. unitID)
		end
	end
	return unitID
end

--- Shared reject path for verifyDataLeg.
--- @return nil
local function rejectDataLeg(reason, subject)
	if ns.statsError then
		ns.statsError(reason)
	end
	if ns.debugPeer then
		ns.debugPeer("data " .. Util.nameForGuid(subject)
			.. " rejected (" .. reason .. ")")
	end
	return nil
end

--- Whether an inbound data envelope may reach the cache.
--- If we didn't OK the ack then the serve is unsolicited.
--- @return string|nil Consensus unitID for the candidate, or nil to drop.
function Broadcast:verifyDataLeg(msg, context)
	-- sendToPeer emits WHISPER or BNET, which are the only serves.
	if context.medium ~= "WHISPER" and context.medium ~= "BNET" then
		return rejectDataLeg("unsolicited_data", msg.subject)
	end
	local guid = msg.subject
	local req = self.requests[guid]
	if not req and not self.recentReqs[guid] then
		return rejectDataLeg("unsolicited_data", guid)
	end
	if not ns.getAdapter(msg.addon) then
		return rejectDataLeg("unknown_addon", guid)
	end
	local wireUnitID = msg.unitID ~= "" and Util.fullUnitName(msg.unitID)
	if not wireUnitID then
		return rejectDataLeg("bad_unitid", guid)
	end

	-- Enforce consensus case-insensitively.
	local unitID, unitKey, conflict = nil, nil, false
	local function claim(id)
		id = id and Util.fullUnitName(id)
		if not id then
			return
		end
		local key = id:lower()
		if unitKey and unitKey ~= key then
			conflict = true
		end
		unitID, unitKey = id, key
	end
	local entry = ns.cache:get(guid)
	claim(entry and entry.unitID)
	claim(Util.unitForGuidFromClient(guid))
	claim(Util.unitForGuid(guid))
	claim(req and req.unitID)
	local rec = ns.db and ns.db.seen and ns.db.seen[guid]
	claim(rec and rec.unitID)
	claim(wireUnitID)
	if conflict then
		if context.senderKey then
			ns.comms:blockSender(context.senderKey)
		end
		return rejectDataLeg("identity_conflict", guid)
	end
	return unitID
end

--- Post-serve broadcast mute, scaled to mesh size: a thin mesh gets
--- SERVE_CHANNEL_COOLDOWN_MIN (availability beats dedup when we may be the
--- only holder), a dense one ramps linearly to the MAX at
--- SERVE_MESH_DENSE members. Unknown size counts as thin.
function Broadcast:serveCooldown()
	local n = ns.comms and ns.comms:meshCount() or 0
	if n >= C.SERVE_MESH_DENSE then
		return C.SERVE_CHANNEL_COOLDOWN_MAX
	end
	local t = (n - 1) / (C.SERVE_MESH_DENSE - 1)
	if t < 0 then
		t = 0
	end
	return C.SERVE_CHANNEL_COOLDOWN_MIN
		+ (C.SERVE_CHANNEL_COOLDOWN_MAX - C.SERVE_CHANNEL_COOLDOWN_MIN) * t
end

--- Whether tracked serve chunks are still queued. When the last chunk
--- leaves the send queue the marker clears; a drained *mesh* serve then
--- arms the post-serve cooldown. Runs lazily wherever the mute is checked,
--- so the cooldown engages even if no REQ ever arrives.
function Broadcast:serveDraining(now)
	local drain = self.serveDrainPos
	if not drain then
		return false
	end
	-- In flight while the marker sits inside the live queue window. The
	-- queue resets head/tail on full drain, so a marker past the current
	-- tail is stale rather than pending.
	local q = ns.comms.queue
	if drain >= q.head and drain <= q.tail then
		return true -- chunks still in flight
	end
	self.serveDrainPos = nil
	if self.serveDrainMesh then
		self.serveDrainMesh = false
		local cd = self:serveCooldown()
		self.serveMuteUntil = now + cd
		if ns.statsLeg then
			ns.statsLeg("serve_mute", 1)
		end
		if ns.debugPeer then
			ns.debugPeer(("mesh serve drained: broadcast REQs muted %ds (mesh %d)")
				:format(math.floor(cd), ns.comms:meshCount()))
		end
	end
	return false
end

--- True while a serve's chunks drain or the post-serve cooldown holds.
function Broadcast:serveThrottled(now)
	return self:serveDraining(now) or now < self.serveMuteUntil
end

--- Address key for pendingServes/freshenPending and OK/NOK lookups.
local function serveKey(peer, guid)
	return (peer or "?") .. ":" .. guid
end

--- Whether serving `unitID` cannot help this requester: a default profile,
--- or a copy no newer than their advertised claim of the same lineage.
--- Returns the honest offer stamp as second value for the ACK.
function Broadcast:suppressable(subject, unitID, adapter,
								reqAt, reqPid, reqCvh, selfReq)
	-- Auto-generated default profiles carry no user content; never offer.
	if adapter.isDefaultUnit and adapter:isDefaultUnit(unitID) then
		return true
	end
	local offerAt = self:claimAt(subject, unitID, adapter.name)
	if not selfReq and offerAt <= reqAt + C.FRESHNESS_SKEW then
		local meta = adapter.profileMeta and adapter:profileMeta(unitID)
		if meta and ((reqPid ~= "" and meta.pid == reqPid)
			or (reqCvh ~= "" and meta.cv
				and Util.hashStr(meta.cv) == reqCvh))
		then
			return true
		end
	end
	return false, offerAt
end

--- Decide whether to ACK a channel REQ and send it, recording a pending
--- serve awaiting the requester's OK. Shared by the immediate path and the
--- deferred flush so the advertised claim is evaluated at decision time.
--- @return boolean Whether an ACK was sent.
function Broadcast:tryAck(subject, unitID, adapter, medium, target,
						  reqAt, reqPid, reqCvh, selfReq, mesh, reqGen)
	if Util.isPaused() then
		return false
	end

	local now = GetTime()
	local peer = ns.debugPeer
	local leg = ns.statsLeg
	local suppressed, offerAt = self:suppressable(
		subject, unitID, adapter, reqAt, reqPid, reqCvh, selfReq)
	if suppressed then
		if peer then
			peer("ack " .. Util.nameForGuid(subject) .. " -> " .. tostring(target)
				.. " skipped (stale copy)")
		end
		return false
	end
	-- Over the cap we do not ACK; the requester times out like a miss.
	local pending = 0
	for _ in pairs(self.pendingServes) do
		pending = pending + 1
	end
	if pending >= C.SERVE_PENDING_CAP then
		return false
	end
	-- dirSeenAt advertises our TRP3 directory last-seen stamp: requesters
	-- collecting channel offers weigh it against the content claim.
	local meta = adapter.profileMeta and adapter:profileMeta(unitID)
	local dirAt = (meta and meta.at) or 0
	if not self:sendToPeer(
		self:buildCtl("ACK",
			{ guid = subject, seenAt = offerAt, dirSeenAt = dirAt }, reqGen),
		medium, target
	) then
		return false
	end
	self.pendingServes[serveKey(target, subject)] = {
		subject = subject, unitID = unitID, peerGen = reqGen,
		medium = medium, target = target, at = now, mesh = mesh,
	}
	if leg then
		leg("ack", 1)
	end
	if peer then
		peer("ack " .. subject .. " -> " .. tostring(target))
	end
	return true
end

--- Answer a unicast REQ. The ACK goes out immediately (it marks the
--- requester's data window), then a pending serve waits for the OK grant
--- like the channel path: denied offers and serves obsoleted mid-flight
--- expire instead of costing a data leg.
function Broadcast:serveUnicast(subject, unitID, adapter, medium, target,
								reqAt, reqPid, reqCvh, selfReq, reqGen)
	if Util.isPaused() then
		return
	end

	local suppressed, offerAt = self:suppressable(
		subject, unitID, adapter, reqAt, reqPid, reqCvh, selfReq)
	if suppressed then
		if ns.debugPeer then
			ns.debugPeer("ack " .. Util.nameForGuid(subject) .. " -> "
				.. tostring(target) .. " skipped (stale copy)")
		end
		return
	end
	-- Over the cap we do not ACK. The requester times out like a miss.
	local pending = 0
	for _ in pairs(self.pendingServes) do
		pending = pending + 1
	end
	if pending >= C.SERVE_PENDING_CAP then
		return
	end
	local meta = adapter.profileMeta and adapter:profileMeta(unitID)
	local dirAt = (meta and meta.at) or 0
	if not self:sendToPeer(
		self:buildCtl("ACK",
			{ guid = subject, seenAt = offerAt, dirSeenAt = dirAt }, reqGen),
		medium, target
	) then
		return
	end
	local key = serveKey(target, subject)
	self.pendingServes[key] = {
		subject = subject, unitID = unitID, peerGen = reqGen,
		medium = medium, target = target, at = GetTime(),
	}
	if ns.statsLeg then
		ns.statsLeg("ack", 1)
	end
	if ns.debugPeer then
		ns.debugPeer("ack " .. Util.nameForGuid(subject) .. " -> " .. tostring(target))
	end
	local freshenN = 0
	for _ in pairs(self.freshenPending) do
		freshenN = freshenN + 1
	end
	if not selfReq
		and adapter.refreshQuery
		and freshenN < C.REQ_FRESHEN_MAX
		and not self.selfxNoPull
		and not serveFreshEnough(adapter, unitID, reqAt)
		and adapter:refreshQuery(unitID)
	then
		self.freshenPending[key] = {
			mode = "serve", subject = subject, unitID = unitID,
			medium = medium, target = target,
		}
		local pending = self.freshenPending[key]
		C_Timer.After(C.REQ_FRESHEN_DELAY, function()
			self:flushFreshen(key, pending)
		end)
		if ns.debugPeer then
			ns.debugPeer("freshen " .. Util.nameForGuid(subject)
				.. " (defer serve -> " .. tostring(target) .. ")")
		end
	end
end

--- Resolve a deferred REQ on timer expiry or landed data. Re-checks the
--- serve gate, which can change during the wait; channel entries also
--- re-check the cooldown.
function Broadcast:flushFreshen(key, expected)
	local entry = self.freshenPending[key]
	if Util.isPaused() or not entry or (expected and entry ~= expected) then
		return
	end
	self.freshenPending[key] = nil
	if entry.mode == "ack" and self:serveThrottled(GetTime()) then
		return
	end
	local adapter = ns.getAvailableAdapter()
	-- The profile could have been purged during the deferral. A fetch
	-- lapsing with nothing landed fails canServe the same way.
	if not (adapter and adapter.canServe and adapter:canServe(entry.unitID)) then
		if entry.mode == "fetch" then
			self.fetchCache[entry.subject] = nil
		end
		return
	end
	if entry.mode == "fetch" then
		-- Data landed: evaluate like a fresh unicast REQ.
		self:serveUnicast(entry.subject, entry.unitID, adapter, entry.medium,
			entry.target, entry.reqAt, entry.reqPid, entry.reqCvh, false,
			entry.peerGen)
	elseif entry.mode == "serve" then
		-- A `*` stub may have refreshed into a real profile mid-wait.
		if adapter.isDefaultUnit and adapter:isDefaultUnit(entry.unitID) then
			return
		end
		-- Refresh done. Serve only when the grant already landed. Without
		-- an OK the pendingServe keeps waiting for one.
		local serve = self.pendingServes[key]
		if serve and serve.ok then
			self.pendingServes[key] = nil
			self:serveData(serve)
		end
	else
		self:tryAck(entry.subject, entry.unitID, adapter, entry.medium,
			entry.target, entry.reqAt, entry.reqPid, entry.reqCvh, false,
			entry.mesh, entry.peerGen)
	end
end

--- A unit's register profile was written (our freshen query, native exchange,
--- MSP merge, profileID rebind): flush deferred ACKs waiting on that unit.
function Broadcast:onFreshenReceived(unitID)
	if Util.isPaused() then
		return
	end
	for key, entry in pairs(self.freshenPending) do
		if entry.unitID == unitID then
			self:flushFreshen(key)
		end
	end
end

--- Dispatch an inbound control message, already parsed into a canonical
--- record by ns.Dialect.parseCtl. Reachable on every medium; the HELLO/HI
--- verbs only carry meaning over BNet. `ctl.gen` is the generation to use
--- when replying to this sender.
function Broadcast:onControl(ctl, msg, context)
	if Util.isPaused() then
		return
	end
	local comms = ns.comms
	local now = GetTime()
	local verb = ctl.verb
	local target = context.gameAccountID or context.senderName
	if not target then
		return -- no way to address the peer back
	end
	local leg = ns.statsLeg
	local peer = ns.debugPeer

	if verb == "HELLO" then
		if context.medium == "BNET" and context.gameAccountID then
			comms:bnetPeerSeen(context.gameAccountID, ctl.args.version,
				msg.protoVer)
			if comms:canHi(context.gameAccountID, now)
				and comms:sendChunksBNet(self:ctlHi(), context.gameAccountID)
			then
				comms:markHi(context.gameAccountID, now)
				if leg then
					leg("hi", 1)
				end
			end
		elseif context.medium == "WHISPER" and context.senderName
			and Util.isXfacClubMember(context.senderName)
		then
			-- A whispered HELLO gets a HI, rate-limited per sender.
			local key = Util.normalizeUnitName(context.senderName)
			local p = key and self:relay(key, context.senderName)
			if p then
				p.version = ctl.args.version
				if (now - p.lastHi) >= C.RELAY_HI_COOLDOWN
					and self:sendToPeer(self:ctlHi(), "WHISPER", target)
				then
					p.lastHi = now
					if leg then
						leg("hi", 1)
					end
				end
			end
		end
	elseif verb == "HI" then
		if context.medium == "BNET" and context.gameAccountID then
			comms:bnetPeerSeen(context.gameAccountID, ctl.args.version,
				msg.protoVer)
		elseif context.medium == "WHISPER" and context.senderName then
			-- Inbound already confirmed them; record the version.
			local key = Util.normalizeUnitName(context.senderName)
			local p = key and self.relays[key]
			if p then
				p.version = ctl.args.version
			end
		end
	elseif verb == "REQ" then
		local guid = ctl.args.guid
		local reqAt = ctl.args.seenAt or 0
		local reqPid = ctl.args.pid or ""
		local reqCvh = ctl.args.cvHash or ""
		-- A REQ flagged with the mesh marker is a broadcast delivered by
		-- whisper, so it takes the channel path on any medium.
		local meshReq = ctl.args.flag == C.REQ_MESH_FLAG
		local wideReq = meshReq
			or (context.medium ~= "WHISPER" and context.medium ~= "BNET")
		if wideReq then
			-- Channel REQs are throttled per requester before any work;
			-- legit clients self-rate at the same interval, so this only
			-- bounds spam (and old fanout-era builds).
			local lastChan = self.chanReqSenderAt[target]
			if lastChan and (now - lastChan) < C.REQ_CHANNEL_SENDER_INTERVAL then
				return
			end
			self.chanReqSenderAt[target] = now
		end
		-- "Who can serve subject guid?" Ourselves answer directly; anyone
		-- else resolves by identity consensus. canServe reads the register
		-- live, so cache-absent subjects are still servable.
		local selfReq = (guid == self:senderGUID())
		local unitID
		if selfReq then
			unitID = ownUnitID()
		else
			unitID = self:resolveSubject(guid, ctl.args.unitID or "")
		end
		local adapter = ns.getAvailableAdapter()
		if wideReq then
			-- Broadcast path: many holders may hear it, so ACK/OK
			-- arbitration and the serve cooldown still apply.
			if not selfReq and self:serveThrottled(now) then
				return
			end
			if not (unitID and adapter and adapter.canServe
				and adapter:canServe(unitID))
			then
				return
			end
			-- Refresh before answering; the ACK defers until data lands
			-- or REQ_FRESHEN_DELAY elapses.
			if not selfReq and adapter.refreshQuery
				and not self.selfxNoPull
			then
				local freshenN = 0
				for _ in pairs(self.freshenPending) do
					freshenN = freshenN + 1
				end
				if freshenN < C.REQ_FRESHEN_MAX
					and not serveFreshEnough(adapter, unitID, reqAt)
					and adapter:refreshQuery(unitID)
				then
					local key = serveKey(target, guid)
					self.freshenPending[key] = {
						subject = guid, unitID = unitID, peerGen = ctl.gen,
						medium = context.medium, target = target,
						reqAt = reqAt, reqPid = reqPid, reqCvh = reqCvh,
						mesh = meshReq,
					}
					local pending = self.freshenPending[key]
					C_Timer.After(C.REQ_FRESHEN_DELAY, function()
						self:flushFreshen(key, pending)
					end)
					if peer then
						peer("freshen " .. guid .. " (defer ack -> "
							.. tostring(target) .. ")")
					end
					return
				end
			end
			self:tryAck(guid, unitID, adapter, context.medium, target,
				reqAt, reqPid, reqCvh, selfReq, meshReq, ctl.gen)
			return
		end
		-- Unicast path: per-sender throttle, then serve or silence.
		local lastReq = self.reqSenderAt[target]
		if lastReq and (now - lastReq) < C.REQ_SENDER_INTERVAL then
			return
		end
		self.reqSenderAt[target] = now
		if unitID and adapter then
			if adapter.canServe and adapter:canServe(unitID) then
				self:serveUnicast(guid, unitID, adapter, context.medium, target,
					reqAt, reqPid, reqCvh, selfReq, ctl.gen)
			elseif not selfReq
				and adapter.canPull and adapter:canPull(unitID)
				and adapter.refreshQuery
				and not self.selfxNoPull
			then
				-- Known but unserved: pull the profile on demand. A fresh
				-- fetch record means the register owns this subject until
				-- the TTL lapses. Never re-query it back-to-back.
				local rec = self.fetchCache[guid]
				if rec and (now - rec.at) < C.REQ_FETCH_TTL then
					return
				end
				-- Register already holds something recent: TRP3 pulled or
				-- merged it just now, so another query gains nothing.
				local meta = adapter.profileMeta and adapter:profileMeta(unitID)
				if meta and meta.at
					and (time() - meta.at) < C.SERVE_REFRESH_TTL
				then
					return
				end
				local freshenN = 0
				for _ in pairs(self.freshenPending) do
					freshenN = freshenN + 1
				end
				if freshenN < C.REQ_FRESHEN_MAX
					and adapter:refreshQuery(unitID)
				then
					self.fetchCache[guid] = { at = now, unitID = unitID }
					local key = serveKey(target, guid)
					self.freshenPending[key] = {
						mode = "fetch", subject = guid, unitID = unitID,
						medium = context.medium, target = target,
						reqAt = reqAt, reqPid = reqPid, reqCvh = reqCvh,
						peerGen = ctl.gen,
					}
					local pending = self.freshenPending[key]
					C_Timer.After(C.REQ_FETCH_DELAY, function()
						self:flushFreshen(key, pending)
					end)
					if peer then
						peer("fetch " .. guid .. " (pull on demand -> "
							.. tostring(target) .. ")")
					end
				end
			end
		end
		-- Misses stay silent.
	elseif verb == "ACK" then
		local guid = ctl.args.guid
		-- seenAt is the holder's content claim; dirSeenAt is its TRP3
		-- directory last-seen stamp. A claim at or under our persisted
		-- floor cannot carry anything newer — silence is rejection.
		local req = self.requests[guid]
		local offerAt = ctl.args.seenAt or 0
		if req and (offerAt + C.FRESHNESS_SKEW)
			< ns.cache:freshnessFloor(guid, req.unitID)
		then
			if peer then
				peer("ack " .. guid .. " <- " .. tostring(target)
					.. " denied (stale claim)")
			end
		elseif req and req.state == "contact" and req.target == target then
			-- The contact answered; open the data window.
			req.state = "awaiting-data"
			req.at = now
			req.winner = { medium = context.medium, target = target }
			-- The grant the server's pendingServe waits on.
			self:sendToPeer(self:buildCtl("OK", { guid = guid }, ctl.gen),
				context.medium, target)
			if leg then
				leg("ok", 1)
			end
			if peer then
				peer("ack " .. (req.unitID or Util.nameForGuid(guid))
					.. " <- " .. tostring(target))
			end
		elseif req and req.state == "chan-wait"
			and req.target == target
		then
			-- The "dead" contact was merely slow; take it and skip the
			-- channel leg entirely.
			req.state = "awaiting-data"
			req.at = now
			req.winner = { medium = context.medium, target = target }
			req.acks = nil
			self:sendToPeer(self:buildCtl("OK", { guid = guid }, ctl.gen),
				context.medium, target)
			if leg then
				leg("ok", 1)
			end
			if peer then
				peer("ack " .. (req.unitID or Util.nameForGuid(guid))
					.. " <- " .. tostring(target) .. " (late contact)")
			end
		elseif req and req.state == "broadcast"
			and target ~= req.deadTarget
		then
			-- Collect the offer; the window end grants the freshest.
			if req.acks and #req.acks < C.REQ_CHANNEL_ACK_CAP then
				req.acks[#req.acks + 1] = {
					medium = context.medium, target = target, gen = ctl.gen,
					offerAt = offerAt, dirAt = ctl.args.dirSeenAt or 0,
				}
				if peer then
					peer("ack " .. guid .. " <- " .. tostring(target)
						.. " (offer " .. #req.acks .. ")")
				end
			end
		end
	elseif verb == "OK" then
		local key = serveKey(target, ctl.args.guid)
		local serve = self.pendingServes[key]
		if serve then
			local fp = self.freshenPending[key]
			if fp and fp.mode == "serve" then
				-- Serve-side refresh still pending. The flush serves it.
				serve.ok = true
			else
				self.pendingServes[key] = nil
				self:serveData(serve)
			end
		end
	elseif verb == "NOK" then
		self.pendingServes[serveKey(target, ctl.args.guid)] = nil
		self.freshenPending[serveKey(target, ctl.args.guid)] = nil
	elseif verb == "VER" then
		-- Peer version announcement. Print a notice when it beats ours,
		-- deduped by the highest version seen this session.
		local version = ctl.args.version
		if not self.topPeerVersion
			or Util.versionCompare(version, self.topPeerVersion) > 0
		then
			self.topPeerVersion = version
			local own = ownVersion()
			if Util.versionCompare(version, own) > 0
				and (not self.notifiedVersion
					or Util.versionCompare(version, self.notifiedVersion) > 0)
			then
				self.notifiedVersion = version
				ns.Print(("|cffffd200outdated:|r A new version of FactionRP is available. Please update to %s. (Yours: %s)"):format(version, own))
				if peer then
					peer("update notice for " .. version)
				end
			end
		end
	end
end

-- Origination ---------------------------------------------------------------

--- Publish a freshly-extracted profile into our cache. Sends nothing.
--- @param guid    string The subject's GUID.
--- @param unitID  string The subject's "Name-Realm".
--- @param profile table  { addon, contentVersion, data } from an adapter.
function Broadcast:publish(guid, unitID, profile)
	if Util.isPaused() then
		return
	end

	local candidate = {
		guid = guid,
		unitID = unitID,
		addon = profile.addon,
		originTime = self:claimAt(guid, unitID, profile.addon),
		contentVersion = profile.contentVersion,
		data = profile.data,
	}
	local result = ns.cache:tryStore(candidate)
	if ns.debugStore then
		ns.debugStore(result, guid)
	end
	if ns.statsCache then
		ns.statsCache(result)
	end
end

-- Reception -----------------------------------------------------------------

--- Handle a fully-reassembled inbound message.
function Broadcast:onMessage(raw, context)
	if Util.isPaused() then
		return
	end
	local msg = Serializer.parseMessage(raw)
	-- A non-numeric originTime would break the cache's ordering compare.
	if not msg or type(msg.originTime) ~= "number" then
		if ns.statsError then
			ns.statsError("malformed")
		end
		ns.comms:blockSender(context.senderKey)
		return
	end

	-- Hard protocol gate, before any peer-state side effects: stamps below
	-- the supported dialect floor are amputated generations. Newer stamps
	-- pass; decode resolves min(stamp, own) downstream.
	if not msg.protoVer or msg.protoVer < ns.Dialect.floor() then
		if ns.statsError then
			ns.statsError("proto_old")
		end
		ns.comms:blockSender(context.senderKey)
		return
	end

	-- Drop our own echoed traffic. selfEchoUntil is the selfx loopback
	-- window: our own serves come back through the whole path on purpose.
	if msg.sender == self:senderGUID()
		and GetTime() > (ns.comms and ns.comms.selfEchoUntil or 0)
	then
		if ns.statsError then
			ns.statsError("self_echo")
		end
		return
	end
	-- A parseable inbound whisper from an xfac club member confirms a
	-- relay; ctl verbs confirm senders too. The envelope stamp records the
	-- sender's generation for dialect selection.
	if context.medium == "WHISPER" and context.senderName then
		local key = Util.normalizeUnitName(context.senderName)
		if key and Util.isXfacClubMember(context.senderName) then
			local p = self:relay(key, context.senderName)
			if p.conf == 0 and ns.debugPeer then
				ns.debugPeer("whisper " .. context.senderName .. " confirmed")
			end
			p.conf = GetTime()
			p.pr = 0
			p.ign = 0
			p.proto = msg.protoVer

-- //Edit: We have a reply so failures before should not block this contact
			ns.comms.whisperBackoff[key] = nil
			ns.comms.whisperAttempts[key] = nil
		end
	end
	-- Any parseable BNet message confirms the account runs FactionRP.
	if context.medium == "BNET" and context.gameAccountID then
		ns.comms:bnetPeerSeen(context.gameAccountID, nil, msg.protoVer)
	end
	-- Control messages never reach the cache or register.
	if msg.subject == C.CTL_SUBJECT then
		local ctl = ns.Dialect.parseCtl(msg)
		if ctl then
			self:onControl(ctl, msg, context)
		end
		return
	end
	-- About envelopes carry FRP1 dialect verbs inside data; the subject is
	-- reserved so they bypass profile-leg verification.
	if msg.subject == C.ABOUT_SUBJECT then
		local ctl = ns.Dialect.parseCtl(msg)
		if ctl and ns.about then
			ns.about:onMessage(ctl, msg, context)
		end
		return
	end
	-- Drop data legs that cannot be a granted serve.
	local unitID = self:verifyDataLeg(msg, context)
	if not unitID then
		return
	end
	if ns.debugReceive then
		ns.debugReceive(msg.sender, msg.subject)
	end
	if ns.statsPeer then
		ns.statsPeer(msg.sender, msg.subject)
	end
	if ns.statsTagSubject then
		ns.statsTagSubject(msg.subject)
	end
	if ns.statsOriginAge then
		-- Rough cross-client staleness measure; sender's time() may skew.
		ns.statsOriginAge(time() - msg.originTime)
	end

	-- Data for a pending subject completes the exchange.
	local req = self.requests[msg.subject]
	if req then
		local src = context.gameAccountID or context.senderName
		self.requests[msg.subject] = nil
		self.recentReqs[msg.subject] = GetTime()
		self.reqMissed[msg.subject] = nil
		if ns.debugPeer then
			ns.debugPeer("data " .. Util.nameForGuid(msg.subject)
				.. " <- " .. tostring(src))
		end
		self:pumpRequests()
	end

	local candidate = {
		guid = msg.subject,
		unitID = unitID,
		addon = msg.addon,
		originTime = msg.originTime,
		contentVersion = msg.contentVersion,
	}

	-- peek first: duplicates and stale copies skip the expensive decode.
	local result = ns.cache:peek(candidate)
	if not result then
		local profileData = ns.Dialect.decodeProfile(msg.data, msg.protoVer)
		if not profileData then
			if ns.statsError then
				ns.statsError("undecodable")
			end
			return -- corrupt or undecodable
		end
		candidate.data = profileData
		result = ns.cache:tryStore(candidate)
	end
	if ns.debugStore then
		ns.debugStore(result, msg.subject)
	end
	if ns.statsCache then
		ns.statsCache(result)
	end

	if ns.about and result ~= ns.Cache.RESULT.REJECTED then
		local entry = ns.cache:get(msg.subject)
		local adapter = entry and ns.getAdapter(entry.addon)
		local profileID = adapter and entry.data and adapter:dataProfileID(entry.data)
		if entry and entry.addon == C.SOURCE.TRP3 and profileID then
			ns.about:rememberSource(entry.unitID, profileID, context)
		end
	end
	-- Only genuinely new/changed content reaches the RP AddOn's register.
	if result ~= ns.Cache.RESULT.NEW and result ~= ns.Cache.RESULT.UPDATED then
		return
	end

	-- Populate the register as profiles land. Queued: writes are expensive.
	self:queueInject(candidate)
end

-- Injection into the RP AddOn ------------------------------------------------

--- Number of profiles queued for injection.
function Broadcast:injectDepth()
	local o = self.injectOrder
	return o.tail - o.head + 1
end

--- Queue a stored profile for injection into its source AddOn's register.
--- Deduped by GUID.
function Broadcast:queueInject(candidate)
	if Util.isPaused() then
		return
	end

	-- Our own profile is already authoritative; never inject it back.
	if candidate.guid == self:senderGUID() then
		return
	end
	if not self.injectQueue[candidate.guid] then
		local o = self.injectOrder
		o.tail = o.tail + 1
		o[o.tail] = candidate.guid
		if ns.statsQueueDepth then
			ns.statsQueueDepth("inject", o.tail - o.head + 1)
		end
	end
	self.injectQueue[candidate.guid] = candidate
end

--- Drain up to INJECT_BURST pending injections per tick.
function Broadcast:drainInject()
	if Util.isPaused() then
		return
	end
	local o = self.injectOrder
	local head = o.head
	local budget = C.INJECT_BURST
	while budget > 0 and head <= o.tail do
		local guid = o[head]
		o[head] = nil
		head = head + 1
		local candidate = self.injectQueue[guid]
		self.injectQueue[guid] = nil
		if candidate then
			local adapter = ns.getAdapter(candidate.addon)
			if adapter and adapter:isAvailable() then
				adapter:inject(candidate.unitID, candidate.data)
			end
		end
		budget = budget - 1
	end
	o.head = head
	if head > o.tail then
		o.head, o.tail = 1, 0
	end
end

--- Pin a whisper target for testing: sent a copy of every issued REQ.
--- @return string|nil The normalized "Name-Realm".
function Broadcast:forceTarget(unitID)
	local key = unitID and Util.normalizeUnitName(unitID)
	local display = key and Util.fullUnitName(unitID)
	if display and display:sub(-1) ~= "-" then
		self.forcedTargets[key] = display
		return display
	end
end

--- Drop all pinned targets. Returns the number removed.
function Broadcast:clearForcedTargets()
	local n = 0
	for _ in pairs(self.forcedTargets) do
		n = n + 1
	end
	self.forcedTargets = {}
	return n
end

--- Record an xfac club member whose profile reached us over the RP
--- AddOn's own comms and queue it for a priority probe.
function Broadcast:noteXfacContact(unitID)
	local key = unitID and Util.normalizeUnitName(unitID)
	if not key then
		return
	end
	self.xfacContacts[key] = unitID
	local p = self.relays[key]
	local fresh = p and p.conf ~= 0
		and (GetTime() - p.conf) < C.RELAY_CONFIRM_TTL
	if not self.probeSeeds[key] and (not p or (p.ign == 0 and not fresh)) then
		local o = self.probeSeedOrder
		o.tail = o.tail + 1
		o[o.tail] = key
		self.probeSeeds[key] = true
	end
end

-- Singleton.
ns.broadcast = Broadcast:new()
ns.OnLogin(function()
	ns.broadcast:start()
end)

-- //edit: keeping the "about" exchange with our profile requests
local About = ns.Class("About")

local function field(value, limit)
	return type(value) == "string" and #value > 0 and #value <= limit
		and not value:find("[|%c]")
end

local function peer(context)
	if context.medium == "BNET" and type(context.gameAccountID) == "number" then
		return { medium = "BNET", target = context.gameAccountID }
	elseif context.medium == "WHISPER" and field(context.senderName, 128) then
		return { medium = "WHISPER", target = context.senderName }
	end
end

local function samePeer(a, b)
	if not a or not b or a.medium ~= b.medium then
		return false
	end
	if a.medium == "BNET" then
		return a.target == b.target
	end
	return Util.normalizeUnitName(a.target) == Util.normalizeUnitName(b.target)
end

-- FRP1 verbs this service answers; other dialect verbs on the subject drop.
local ABOUT_VERBS = { AQ = true, AR = true, AO = true, AG = true,
	AD = true, AN = true, AC = true }

local function key(unitID, profileID)
	return Util.normalizeUnitName(unitID) .. "|" .. profileID
end

--- Freshness TTL for a pulled About, scaled by its advertised encoded
--- size: cheap payloads re-pull sooner, expensive ones suppress longer.
local function aboutCacheTTL(encodedLen)
	local frac = math.min(math.max((encodedLen or 0) / C.ABOUT_MAX_ENCODED, 0), 1)
	return C.ABOUT_CACHE_TTL_MIN
		+ (C.ABOUT_CACHE_TTL_MAX - C.ABOUT_CACHE_TTL_MIN) * frac
end

function About:init()
	self.sources, self.cooldowns, self.cache = {}, {}, {}
	self.counter = 0
	self.lastQueryAt = -math.huge
end

function About:routeLive(route)
	if not route or Util.commsRestricted() then
		return false
	end


	if route.medium == "WHISPER" then
		return field(route.target, 128) and ns.comms:canWhisper(route.target)
	elseif route.medium == "BNET" then
		local entry = ns.comms.bnetPeers[route.target]
		if not entry or entry.confirmedAt <= 0 or not ns.comms:isBNetConfirmed(route.target, GetTime()) then
			return false
		end
		for _, id in ipairs(ns.comms:bnetAccounts()) do
			if id == route.target then
				return true
			end
		end

	elseif route.medium == "CHANNEL" then
		return type(route.target) == "number" and route.target > 0 and ns.comms:channelIndex() ~= nil
	end

	return false
end

function About:rememberSource(unitID, profileID, context)
	local route = peer(context)
	if not field(unitID, 128) or not field(profileID, 96) or not route then
		return
	end

	local count, oldest, oldestAt = 0, nil, math.huge
	for id, record in pairs(self.sources) do
		count = count + 1
		if record.at < oldestAt then
			oldest, oldestAt = id, record.at
		end
	end

	local id = key(unitID, profileID)
	if not self.sources[id] and count >= C.ABOUT_SOURCE_CAP then
		self.sources[oldest] = nil
	end

	self.sources[id] = { route = route, at = GetTime() }
end

--- Encode an About leg's envelope chunks and shared send frame, or nil
--- when the route, dialect, or size bound rejects it.
function About:buildLeg(verb, fields, route)
	if not self:routeLive(route) then
		return nil
	end

	local gen = ns.broadcast:sendGenForPeer(route.medium, route.target)
	local text = gen and ns.Dialect.buildCtlData(verb, fields, gen)
	if not text or #text > C.ABOUT_MAX_ENCODED + C.ABOUT_FRAME_OVERHEAD then
		return nil
	end

	local message = Serializer.buildMessage({
		sender = ns.broadcast:senderGUID(),
		subject = C.ABOUT_SUBJECT,
		unitID = ownUnitID(),
		addon = "FRP",
		originTime = time(),
		contentVersion = "0",
		data = text,
	})
	return Serializer.chunk(message), {}
end

function About:queue(verb, fields, route, owner)
	local chunks, frame = self:buildLeg(verb, fields, route)
	if not chunks then
		return nil
	end
	local sent = sendAboutChunks(chunks, route,
		{ owner = owner, route = route, frame = frame,
			verb = verb, id = fields.id })
	if not sent then
		return nil
	end
	return frame
end

--- Feed the data leg for a granted serve through the idle send slot, i.e.
--- currently not serving a profile.
function About:sendData(serve)
	local chunks, frame = self:buildLeg("AD", { id = serve.id, data = serve.encoded },
		serve.route)
	if not chunks then
		self:queue("AN", { id = serve.id, reason = "busy" }, serve.route,
			{ deadline = GetTime() + C.ABOUT_STALL, id = serve.id })
		serve.cancelled, self.serve = true, nil
		return
	end
	local bytes = 0
	for i = 1, #chunks do
		bytes = bytes + #chunks[i]
	end
	serve.chunks, serve.chunkPos = chunks, 1
	serve.legBytes, serve.legStartedAt = bytes, GetTime()
	serve.frame, serve.lastAt = frame, GetTime()
end

function About:notify()
	if ns.trp3About then
		ns.trp3About:update()
	end
end

function About:finish(reason)
	local request = self.request
	if not request then
		return
	end

	if ns.debugAbout then
		ns.debugAbout(reason and "request stopped" or "complete", request.id, reason)
	end

	request.cancelled = true
	local count, oldest, oldestAt = 0, nil, math.huge
	for id, record in pairs(self.cooldowns) do
		count = count + 1
		if record.untilAt < oldestAt then
			oldest, oldestAt = id, record.untilAt
		end
	end

	if not self.cooldowns[request.key] and count >= C.ABOUT_SOURCE_CAP then
		self.cooldowns[oldest] = nil
	end

	self.cooldowns[request.key] = { untilAt = GetTime() + C.ABOUT_COOLDOWN, reason = reason }
	if reason == nil then
		-- Freshness gate: a successful pull suppresses repeats for a
		-- size-scaled TTL. Failures stay cooldown-only.
		count, oldest, oldestAt = 0, nil, math.huge
		for id, record in pairs(self.cache) do
			count = count + 1
			if record.at < oldestAt then
				oldest, oldestAt = id, record.at
			end
		end
		if not self.cache[request.key] and count >= C.ABOUT_CACHE_CAP then
			self.cache[oldest] = nil
		end
		self.cache[request.key] = { at = GetTime(), v = request.aboutV,
			ttl = aboutCacheTTL(request.encodedLen) }
	end
	self.request = nil
	self:notify()
end

function About:requestStatus(unitID, profileID)
	local id = key(unitID, profileID)
	local cached = self.cache[id]
	if cached and cached.at + cached.ttl > GetTime() then
		return "cooldown", cached.at + cached.ttl, "cached"
	end
	local record = self.cooldowns[id]
	if record and record.untilAt > GetTime() then
		return "cooldown", record.untilAt, record.reason
	end

	if self.request then
		if self.request.key == id then
			return self.request.phase == "loading" and "loading" or "searching"
		end

		return "busy"
	end

	return "idle"
end

local function contactKey(route)
	return route.medium == "BNET" and "bn:" .. route.target
		or Util.normalizeUnitName(route.target)
end

function About:pickContact(request)
	local now = GetTime()
	local tried = request.tried
	local source = self.sources[request.key]
	if source and now - source.at < C.ABOUT_SOURCE_TTL and self:routeLive(source.route)
		and not (tried and tried[contactKey(source.route)])
	then
		return source.route
	end
	local route = ns.broadcast:reqContact(request.guid, now, request.failedRoute)
	if route and route.medium == "BNET" then
		-- reqContact's BNet leg only ever returns the subject themselves.
		if self:routeLive(route) and not (tried and tried[contactKey(route)]) then
			return route
		end
		route = nil
	end

	-- Owner path: the subject may itself be a confirmed club relay. conf is
	-- the live-FRP marker, proto gates peers whose dialect lacks the verbs.
	local ownerKey = Util.normalizeUnitName(request.unitID)
	local p = ownerKey and ns.broadcast.relays[ownerKey]
	if p and p.conf ~= 0 and (now - p.conf) < C.RELAY_CONFIRM_TTL
		and (p.proto or 0) >= C.PROTO_MAJOR
		and ns.comms:canWhisper(p.name)
		and Util.isClubMemberOnline(p.name)
		and (Util.isGuildClubMember(p.name) or Util.isCommunityClubMember(p.name))
		and not (tried and tried[ownerKey])
	then
		return { medium = "WHISPER", target = p.name }
	end

	-- Sample the deck until an untried contact comes up. A re-yielded key
	-- means the draw pile emptied, so every live contact was already asked.
	local excluded = request.failedRoute
	for _ = 1, 24 do
		if not route then
			route = ns.broadcast:reqContact(request.guid, now, excluded)
		end
		if not route then
			break
		end
		local k = contactKey(route)
		if not (tried and tried[k]) then
			break
		end
		excluded, route = route, nil
		if k:sub(1, 3) == "bn:" then
			break
		end
	end
	return self:routeLive(route) and route or nil
end

function About:contactName(route)
	if route.medium == "WHISPER" then
		return Util.normalizeUnitName(route.target)
	end

	if route.medium ~= "BNET" or type(C_BattleNet.GetGameAccountInfoByID) ~= "function" then
		return nil
	end


	local ok, info = pcall(C_BattleNet.GetGameAccountInfoByID, route.target)
	if ok and Util.fieldsUsable(info, "characterName", "realmName")
		and field(info.characterName, 128) and field(info.realmName, 128)
	then
		return Util.normalizeUnitName(info.characterName .. "-" .. info.realmName)
	end
end

function About:query(request, route)
	self.counter = self.counter + 1
	request.id = ("%x-%x"):format(math.random(1, 1073741823), self.counter)
	request.route, request.phase, request.queuedAt = route, "searching", GetTime()
	request.contactName = self:contactName(route)
	request.queryFrame = self:queue("AQ",
		{ id = request.id, unitID = request.unitID, pid = request.profileID },
		route, request)
	
	if ns.debugAbout then
		ns.debugAbout(request.queryFrame and "request queued" or "request not queued", request.id,
			request.unitID .. " -> " .. route.medium .. " " .. tostring(route.target))
	end

	return request.queryFrame ~= nil
end

function About:pumpDiscovery(request, now)
	if now - ns.broadcast.lastChannelReqAt < C.REQ_CHANNEL_INTERVAL then
		return
	end

	local index = ns.comms:channelIndex()
	if not index then
		return
	end

	local route = { medium = "CHANNEL", target = index }
	local frame = self:queue("AR",
		{ id = request.id, unitID = request.unitID, pid = request.profileID },
		route, request)
	
	if not frame then
		return
	end

	request.route, request.queryFrame = route, frame
	request.phase, request.queuedAt = "discovering", now
	ns.broadcast.lastChannelReqAt = now
	
	if ns.debugAbout then
		ns.debugAbout("discovery queued", request.id, request.unitID .. " -> CHANNEL " .. index)
	end
end

function About:discover(request, reason)
	if request.discovered then
		return false
	end

	request.discovered = true
	request.failureReason = reason
	request.failedRoute, request.failedName = request.route, request.contactName
	self.counter = self.counter + 1
	request.id = ("%x-%x"):format(math.random(1, 1073741823), self.counter)
	request.phase, request.waitAt, request.queryFrame = "discovery-wait", GetTime(), nil
	request.grantFrame, request.encodedLen, request.loadUntil = nil, nil, nil

-- searching once through our channel only one sends the "about"
	if ns.debugAbout then
		ns.debugAbout("discovery waiting", request.id, "channel and broadcast pacing")
	end
	self:pumpDiscovery(request, GetTime())
	self:notify()
	return true
end

function About:requestAbout(unitID, profileID)
	local restricted = Util.commsRestricted()
	if restricted or self.request or not field(unitID, 128) or not field(profileID, 96) then
		if ns.debugAbout then
			ns.debugAbout("request blocked", nil, restricted and "paused" or (self.request and "busy" or "invalid profile"))
		end

		return false
	end


	local context, _, currentUnitID = ns.trp3About:getContext()

	if not context or currentUnitID ~= unitID or context.profileID ~= profileID
		or self:requestStatus(unitID, profileID) ~= "idle"
	then

		if ns.debugAbout then
			ns.debugAbout("request blocked", nil, "profile context or cooldown")
		end


		return false
	end

	local adapter = ns.getAdapter(C.SOURCE.TRP3)
	local aboutState = adapter and adapter:captureAboutState(unitID, profileID)
	if not aboutState then
		if ns.debugAbout then
			ns.debugAbout("request blocked", nil, "native profile unavailable")
		end
		return false
	end

	local id = key(unitID, profileID)
	local guid = Util.resolveGUID(unitID)
	local request = { key = id, unitID = unitID, profileID = profileID, guid = guid, aboutState = aboutState,
		deadline = GetTime() + C.ABOUT_TIMEOUT, phase = "searching" }
	self.request = request
	local route = self:pickContact(request)
	if route then
		if not self:query(request, route) then
			self:finish("busy")
			return false
		end
	else
		request.phase, request.waitAt = "waiting", GetTime()
		if ns.debugAbout then
			ns.debugAbout("waiting for contact", nil, unitID)
		end
	end

	self:notify()
	return true
end

--- Drop the current contact and return to sampling.
function About:dropContact(request, reason, now)
	request.tried = request.tried or {}
	if request.route then
		request.tried[contactKey(request.route)] = true
	end
	request.failedRoute, request.failedName = request.route, request.contactName
	request.failureReason = reason
	request.phase, request.waitAt = "waiting", now
	request.queryFrame, request.grantFrame = nil, nil
	request.encodedLen, request.loadUntil = nil, nil
end

function About:checkRequestTimeout(request, now)
	if now > request.deadline then
		self:finish("timeout")
		return true
	end
	if request.phase == "waiting" then
		local route = self:pickContact(request)
		if route then
			if not self:query(request, route) then
				self:finish("busy")
			end
		elseif now - request.waitAt >= C.REQ_CONTACT_TIMEOUT then
			if not self:discover(request, request.failureReason) then
				self:finish(request.failureReason or "no-contact")
			end
		end
		return true
	elseif request.phase == "discovery-wait" then
		if now - request.waitAt > C.REQ_CHANNEL_WAIT_MAX then
			self:finish(request.failureReason or "no-contact")
		else
			self:pumpDiscovery(request, now)
		end
		return true

	end
	local frame = request.phase == "searching" and request.queryFrame or request.grantFrame
	if request.phase == "discovering" then
		frame = request.queryFrame
	end
	if (request.phase == "searching" or request.phase == "loading")
		and not frame.sentAt and not self:routeLive(request.route)
	then
		-- Route died before the leg dispatched: no confirmed answer exists,
		-- so the mesh broadcast is still worth one shot.
		if not self:discover(request, "no-contact") then
			self:finish("no-contact")
		end
		return true
	end

	if not frame.sentAt and now - request.queuedAt > C.ABOUT_STALL then
		self:finish("timeout")

	elseif request.phase == "searching" and frame.sentAt and now - frame.sentAt > C.REQ_CONTACT_TIMEOUT then
		-- A holder's silence says nothing about other holders. Sample the
		-- next contact; the channel broadcast stays the cold-start answer
		-- for a mesh with nothing left to ask.
		self:dropContact(request, "no-response", now)

	elseif request.phase == "discovering" and frame.sentAt and now - frame.sentAt > C.ABOUT_STALL then
		self:finish(request.failureReason == "no-contact" and "no-response" or (request.failureReason or "no-response"))
	elseif request.phase == "loading" then
		-- Chunk-level liveness: the D leg reassembles silently, so stall on
		-- inbound chunk activity and bound the whole drain up front. Only
		-- chunks after the grant count; before the first one, measure from
		-- the grant dispatch itself (same shape as the profile exchange).
		local lastChunk = ns.comms.lastChunkFrom[
			ns.comms:senderKeyFor(request.route.medium, request.route.target)]
		local grantAt = request.grantFrame.sentAt or request.queuedAt
		local activity = (lastChunk and lastChunk > grantAt) and lastChunk or grantAt
		if now > (request.loadUntil or request.deadline)
			or now - activity > C.ABOUT_STALL
		then
			self:finish("timeout")
			return true
		end
		-- Still alive: report false so onMessage keeps dispatching the verb.
		return false
	else
		return false
	end

	return true
end

function About:checkServeTimeout(serve, now)

	if serve.frame and serve.frame.sentAt then
		serve.lastAt = serve.frame.sentAt
	end

	if now > serve.deadline or not self:routeLive(serve.route)
		or now - (serve.lastAt or serve.offerFrame.sentAt or serve.offeredAt) > C.ABOUT_STALL
	then
		if ns.debugAbout then
			ns.debugAbout("serve stopped", serve.id, "timeout or contact unavailable")
		end
		serve.cancelled, self.serve = true, nil
		return true
	end

	return false

end

function About:pause()
	if self.request then
		self:finish("paused")
	end

	if self.serve then
		if ns.debugAbout then
			ns.debugAbout("serve stopped", self.serve.id, "paused")
		end

		self.serve.cancelled = true
		self.serve = nil
	end
end

function About:offer(id, unitID, profileID, route, discovery)
	if not field(unitID, 128) or not field(profileID, 96) then
		return
	end

	if GetTime() - self.lastQueryAt < C.ABOUT_QUERY_INTERVAL then
		return
	end

	self.lastQueryAt = GetTime()

	local owner = { deadline = GetTime() + C.ABOUT_STALL, id = id }
	if self.serve then
		if discovery then
			return
		end

		if ns.debugAbout then
			ns.debugAbout("offer rejected", id, "busy")
		end
		self:queue("AN", { id = id, reason = "busy" }, route, owner)
		return
	end

	local adapter = ns.getAdapter(C.SOURCE.TRP3)
	local about, reason

	if adapter then
		about, reason = adapter:extractAbout(unitID, profileID)
	end

	local ok, encoded, rawSize
	if about then
		ok, encoded, rawSize = pcall(ns.Dialect.encodeProfile,
			{ profileID = profileID, about = about },
			ns.broadcast:sendGenForPeer(route.medium, route.target))
	end
	if not about or not ok or not encoded or not rawSize
		or rawSize > C.ABOUT_MAX_RAW or #encoded > C.ABOUT_MAX_ENCODED
	then

		local tooLarge = reason == "about-too-large" or (encoded and #encoded > C.ABOUT_MAX_ENCODED)
			or (rawSize and rawSize > C.ABOUT_MAX_RAW)
		if discovery then
			return
		end

		if ns.debugAbout then
			ns.debugAbout("offer rejected", id, tooLarge and "too-large" or "missing")
		end

		self:queue("AN", { id = id, reason = tooLarge and "too-large" or "missing" },
			route, owner)
		return
	end

	local serve = { id = id, route = route, encoded = encoded,
		deadline = GetTime() + C.ABOUT_TIMEOUT, offeredAt = GetTime() }
	self.serve = serve
	serve.offerFrame = self:queue("AO",
		{ id = id, pid = profileID, size = #encoded }, route, serve)

	if ns.debugAbout then
		ns.debugAbout(serve.offerFrame and "offer queued" or "offer not queued", id,
			#encoded .. " bytes")
	end

	if not serve.offerFrame then
		self.serve = nil
	end
end

function About:onMessage(ctl, msg, context)
	if Util.commsRestricted() or not ABOUT_VERBS[ctl.verb]
		or #msg.data > C.ABOUT_MAX_ENCODED + C.ABOUT_FRAME_OVERHEAD
		or msg.data:find("%z")
	then
		return
	end

	local verb, args = ctl.verb, ctl.args
	local id = args.id
	if type(id) ~= "string" or #id > 32 then
		return
	end

	if verb == "AR" then
		if context.medium ~= "CHANNEL" or not ns.comms:channelIndex() then
			return
		end
		local response = peer({ medium = "WHISPER", senderName = context.senderName })
		if self:routeLive(response) then
			if ns.debugAbout then
				ns.debugAbout("in AR", id, "CHANNEL " .. response.target)
			end
			self:offer(id, args.unitID, args.pid, response, true)
		end
		return
	end

	local route = peer(context)
	if not self:routeLive(route) then
		if ns.debugAbout then
			ns.debugAbout("in " .. verb .. " dropped", id, "route dead")
		end
		return
	end

	if ns.debugAbout then
		ns.debugAbout("in " .. verb, id, route.medium .. " " .. tostring(route.target))
	end

	if verb == "AQ" then
		self:offer(id, args.unitID, args.pid, route)
		return
	end

	local serve = self.serve
	if serve and serve.id == id and samePeer(serve.route, route)
		and not self:checkServeTimeout(serve, GetTime())

	then
		if verb == "AG" and serve.offerFrame.sentAt and not serve.granted then
			serve.granted = true
			serve.lastAt = GetTime()
			if ns.debugAbout then
				ns.debugAbout("serve granted", id)
			end
			self:sendData(serve)

		elseif verb == "AC" then
			serve.cancelled, self.serve = true, nil
		end
	end

	local request = self.request
	local discovering = request and request.phase == "discovering" and request.queryFrame.sentAt and route.medium == "WHISPER"
	if not request or request.id ~= id or (not discovering and not samePeer(request.route, route)) then
		if ns.debugAbout then
			ns.debugAbout("in " .. verb .. " dropped", id,
				not request and "no request"
					or request.id ~= id and "id mismatch"
					or "peer mismatch")
		end
		return
	end
--  delayed packets can arrive before the next tick. Checking its time limits here
	if self:checkRequestTimeout(request, GetTime()) then
		return
	end
--  the contact that failed must not be the fallback again

	if discovering and verb == "AO" and (samePeer(request.failedRoute, route)
		or (request.failedName and Util.normalizeUnitName(route.target) == request.failedName))
	then
		if ns.debugAbout then
			ns.debugAbout("offer ignored", id, "previous contact")
		end
		return
	end

	if verb == "AN" and (request.phase == "searching" or request.phase == "loading") then
		local reason = args.reason == "too-large" and "too-large"
			or (args.reason == "missing" and "missing"
			or (args.reason == "busy" and "busy" or "no-response"))
		self:dropContact(request, reason, GetTime())
		return
	end

	if verb == "AO" and (request.phase == "searching" or discovering) and request.queryFrame.sentAt then
		-- num args keep the raw token when tonumber fails; normalize here.
		local profileID, encodedLen = args.pid, tonumber(args.size)
		if profileID ~= request.profileID or not encodedLen or encodedLen <= 0 then
			if discovering then
				return
			end
			self:finish("invalid")
			return
		end

		if encodedLen > C.ABOUT_MAX_ENCODED then
			if discovering then
				return
			end
			self:finish("too-large")
			return
		end

		request.route, request.encodedLen = route, encodedLen
		request.phase = "loading"
		-- Bound the whole drain: queue wait + expected chunks at SEND_RATE
		-- plus a stall grace, the same shape the profile exchange uses.
		local expectedChunks = math.ceil((encodedLen + C.ABOUT_ENVELOPE_OVERHEAD) / C.CHUNK_SIZE)
		request.loadUntil = GetTime()
			+ (ns.comms:queueDepth() + expectedChunks) / C.SEND_RATE
			+ C.ABOUT_STALL

		if ns.debugAbout then
			ns.debugAbout("offer accepted", id, encodedLen .. " bytes")
		end

		request.queuedAt = GetTime()
		request.grantFrame = self:queue("AG", { id = id }, route, request)
		if not request.grantFrame then
			self:finish("busy")
		end

		self:notify()

	elseif verb == "AD" and request.phase == "loading" and request.grantFrame.sentAt then
		local encoded = args.data
		if type(encoded) ~= "string" or #encoded < 1
			or #encoded > C.ABOUT_MAX_ENCODED
			or #encoded ~= request.encodedLen
		then
			if ns.debugAbout then
				ns.debugAbout("data rejected", id,
					type(encoded) == "string"
						and ("%d bytes, expected %d"):format(#encoded, request.encodedLen or -1)
						or "missing data")
			end
			self:finish("invalid")
			return
		end

		local data = ns.Dialect.decodeProfile(encoded, msg.protoVer, C.ABOUT_MAX_RAW)
		local adapter = ns.getAdapter(C.SOURCE.TRP3)
		if type(data) ~= "table" or data.profileID ~= request.profileID
			or type(data.about) ~= "table"
			or not adapter or not adapter:injectAbout(request.unitID, request.profileID, data.about, request.aboutState)
		then
			if ns.debugAbout then
				ns.debugAbout("data rejected", id, "decode or inject failed")
			end
			self:finish("invalid")
			return
		end

		request.aboutV = data.about.v
		self:rememberSource(request.unitID, request.profileID, context)
		self:finish(nil)
	end
end

function About:tick()
	if Util.commsRestricted() then
		self:pause()
		return
	end

	local now = GetTime()
	for id, record in pairs(self.cooldowns) do
		if record.untilAt <= now then
			self.cooldowns[id] = nil
		end
	end
	for id, record in pairs(self.cache) do
		if record.at + record.ttl <= now then
			self.cache[id] = nil
		end
	end

	local request = self.request
	if request then
		self:checkRequestTimeout(request, now)
	end

	local serve = self.serve
	if serve then
		self:checkServeTimeout(serve, now)
	end

	-- Fill idle slots one descriptor at a time.
	serve = self.serve
	if serve and serve.chunks and not ns.comms.aboutSend and not Util.isPaused() then
		local i = serve.chunkPos
		local meta = { owner = serve, route = serve.route, frame = serve.frame,
			verb = "AD", id = serve.id }
		local desc
		if serve.route.medium == "BNET" then
			desc = ns.comms:makeDesc(serve.chunks[i], "bnet", "BNET",
				serve.route.target, meta)
		elseif serve.route.medium == "CHANNEL" then
			desc = ns.comms:makeDesc(serve.chunks[i], "addon", "CHANNEL",
				nil, meta)
			desc.channelName = C.COMM_CHANNEL
		else
			desc = ns.comms:makeDesc(serve.chunks[i], "addon", "WHISPER",
				serve.route.target, meta)
		end
		if i == #serve.chunks then
			desc.legStartedAt, desc.legBytes, desc.legTotal =
				serve.legStartedAt, serve.legBytes, i
		end
		ns.comms.aboutSend = desc
		serve.chunkPos = i + 1
		if i == #serve.chunks then
			serve.chunks = nil
		end
	end

	-- Serve lives until last slot dispatched, or canceled.
	serve = self.serve
	if serve and serve.chunkPos and not serve.chunks and not ns.comms.aboutSend then
		self.serve = nil
	end
end

function About:start()
	ns.trp3About:setRequestHandler(function(unitID, profileID)
		return self:requestAbout(unitID, profileID)
	end, function(unitID, profileID)
		return self:requestStatus(unitID, profileID)
	end)
end

ns.about = About:new()
ns.OnLogin(function()
	ns.about:start()
end)
