-- Broadcast.lua
--
-- The pull-exchange engine. Requests are serial: one subject at a time,
-- REQ'd to a single contact, falling back to the faction channel on
-- silence. The channel path keeps REQ -> ACK -> OK -> data arbitration
-- since many holders can hear a broadcast.
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
	--   }
	--   xfacContacts: proven cross-faction reachable RP-AddOn users, not
	--     necessarily FRP.
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
	--   contactIdx: round-robin contact cursor
	--   pendingServes[key] = { subject, unitID, medium, target, at }
	--     key = "<peer>:<guid>"; channel-path grants awaiting OK
	--   freshenPending[key] = { mode, subject, unitID, medium, target,
	--                           reqAt, reqPid, reqCvh }
	--     mode "ack": channel REQ whose ACK waits on an RP-AddOn refresh
	--     mode "serve": unicast REQ whose data leg waits on the refresh
	--   reqSenderAt[senderKey] = last inbound unicast REQ time (throttle)
	--   chanReqSenderAt[senderName] = last inbound channel REQ time
	self.requests = {}
	self.recentReqs = {}
	self.reqMissed = {}
	self.pendingServes = {}
	self.freshenPending = {}
	self.reqQueued = {}
	self.reqQueueOrder = { head = 1, tail = 0 }
	self.contactIdx = 0
	self.reqSenderAt = {}
	self.chanReqSenderAt = {}
	self.lastChannelReqAt = 0 -- last broadcast REQ we sent (self-rate)
	self.fanoutInFlight = {} -- queue tail positions of issued probes
	self.relayProbeAt = 0 -- last whisper probe burst
	self.probeCursor = 0 -- rotating index into the flattened probe rosters

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
-- @return string|nil
function Broadcast:senderGUID()
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
end

-- Helpers -------------------------------------------------------------------

--- Fetch-or-create the relay record for `key`; `name` refreshes the
-- display name when given.
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

--- Next probe target via a rotating cursor over both rosters. One probe
-- per target; an unanswered one past RELAY_PROBE_COOLDOWN gets ignored.
function Broadcast:whisperProbeTarget(now)
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
		if key then
			local p = self.relays[key]
			if p and p.ign == 0 then
				local fresh = p.conf ~= 0
					and (now - p.conf) < C.RELAY_CONFIRM_TTL
				if not fresh then
					if p.pr >= C.RELAY_PROBE_MAX then
						-- Was quiet too long; get ignored.
						if (now - p.lp) >= C.RELAY_PROBE_COOLDOWN then
							p.ign = now
							if ns.debugPeer then
								ns.debugPeer("whisper " .. name
									.. " ignored (unanswered probe)")
							end
						end
					elseif p.lp == 0
						or (now - p.lp) >= C.RELAY_PROBE_COOLDOWN
					then
						self.probeCursor = idx
						return key, name
					end
				end
			elseif not p then
				self.probeCursor = idx
				return key, name
			end
		end
	end
end

-- Control channel -----------------------------------------------------------

--- Own "Name-Realm", validated inside getUnitID each call.
local function ownUnitID()
	return Util.getUnitID("player") or ""
end

--- Build (and chunk) a control envelope: subject "_frp", data "FRP1 <verb>
-- <arg>". Called at request/probe time only, not a hot path.
-- @return table Chunk list.
function Broadcast:buildCtl(verb, arg)
	local message = Serializer.buildMessage({
		sender = self:senderGUID(),
		subject = C.CTL_SUBJECT,
		unitID = ownUnitID(),
		addon = "FRP",
		originTime = time(),
		contentVersion = "0",
		data = arg and (C.CTL_PROTO .. " " .. verb .. " " .. arg)
			or (C.CTL_PROTO .. " " .. verb),
	})
	return Serializer.chunk(message)
end

-- Handshake chunks are constant per session; build once, reuse forever.
function Broadcast:ctlHello()
	if not self._hello then
		self._hello = self:buildCtl("HELLO", C.VERSION)
	end
	return self._hello
end

function Broadcast:ctlHi()
	if not self._hi then
		self._hi = self:buildCtl("HI", C.VERSION)
	end
	return self._hi
end

--- Send a chunk-list to one peer: BNet to the gameAccountID, anything else
-- as a whisper to the named sender.
function Broadcast:sendToPeer(chunks, medium, target)
	if medium == "BNET" then
		return ns.comms:sendChunksBNet(chunks, target)
	end
	return ns.comms:sendChunksAddon(chunks, "WHISPER", target)
end

-- Version announcement (issue #19) -------------------------------------------

--- Our installed addon version from the .toc metadata. C.VERSION is the
-- fallback when the field is missing.
local function ownVersion()
	return C_AddOns.GetAddOnMetadata(C.ADDON_NAME, "Version") or C.VERSION
end

--- One-time broadcast of our addon version on the comm channel. Retried
-- while the channel join pends; gives up after C.VER_BROADCAST_ATTEMPTS.
function Broadcast:broadcastVersion()
	local version = ownVersion()
	-- Dev or prerelease suffixed versions stay quiet.
	if version:find("[^%d%.]") then
		return
	end
	local comms = ns.comms

	-- Old-generation peers sit on a disjoint channel; join the previous
	-- one long enough to launch the announcement there too.
	local prevChan = C.COMM_CHANNEL_PROTO3
	local prevIdx = prevChan and GetChannelName(prevChan)
	if prevIdx == 0 then
		prevIdx = nil
	end
	if prevChan and not prevIdx then
		JoinTemporaryChannel(prevChan)
		prevIdx = GetChannelName(prevChan)
		if prevIdx == 0 then
			prevIdx = nil
		end
	end

	local idx = comms and comms:channelIndex()
	if Util.commsRestricted() or not idx or (prevChan and not prevIdx) then
		self.verAttempts = self.verAttempts + 1
		if self.verAttempts < C.VER_BROADCAST_ATTEMPTS then
			C_Timer.After(C.VER_BROADCAST_RETRY, function()
				self:broadcastVersion()
			end)
		elseif prevChan then
			LeaveChannelByName(prevChan)
		end
		if ns.debugPeer then
			ns.debugPeer("ver broadcast deferred (channel join pending)")
		end
		return
	end
	if comms:sendChunksAddon(self:buildCtl("VER", version), "CHANNEL", idx) then
		if ns.statsLeg then
			ns.statsLeg("ver", 1)
		end
		if ns.debugPeer then
			ns.debugPeer("ver " .. version .. " -> channel")
		end
	end
	if prevChan then
		if comms:sendChunksChannel(self:buildCtl("VER", version), prevChan)
			and ns.debugPeer
		then
			ns.debugPeer("ver " .. version .. " -> " .. prevChan)
		end
		-- Keep membership until the paced queue has flushed the chunk.
		C_Timer.After(C.VER_PREV_CHANNEL_HOLD, function()
			LeaveChannelByName(prevChan)
		end)
	end
end

--- REQ argument: subject guid plus our unitID and held freshness
-- (as-of stamp, profileID, content-version hash) so stale holders can
-- suppress themselves.
local function reqArg(guid, unitID)
	local wire = unitID and Util.fullUnitName(unitID)
	if not wire then
		return guid
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
	return string.format("%s %s %d %s %s", guid, wire, floor, pid, cvh)
end

--- Whether the register's held copy is fresh enough to serve without a
-- refresh query: seen within SERVE_REFRESH_TTL, or clearly newer than the
-- requester's claim. `at` values are time() stamps.
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
-- the tooltip, and publish a held register copy so the subject still
-- renders (honest stale stamp; the mesh beats it when it can).
-- @return boolean Always true: the pump should advance.
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
	local now = GetTime()
	local comms = ns.comms
	local restricted = Util.commsRestricted()

	-- Request lifecycle: silence is rejection at every stage. Contact and
	-- data failures fall back to the same-faction channel once per request
	-- for stranger subjects; everything else drops to the subject cooldown.
	local pump = false
	for guid, req in pairs(self.requests) do
		if req.state == "contact"
			and (now - req.at) > C.REQ_CONTACT_TIMEOUT
		then
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
			if stalled or (now - req.at) > C.REQ_DATA_TIMEOUT then
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
			if p.ign ~= 0 and not Util.isClubMemberOnline(p.name or key) then
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

end

--- Pull status for one subject, for the tooltip indicator: "asking" while
-- queued or any pre-grant state is in flight, "receiving" plus chunk
-- progress once a serve is granted, "miss" plus seconds until the subject
-- may be requested again inside the cooldown window after a failed pull.
-- nil means nothing worth showing.
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

--- Queue a request for `guid`'s profile. No-op when the cache is fresh,
-- the subject is pending or queued, or it is on cooldown.
function Broadcast:requestProfile(guid, unitID)
	if not guid or Util.commsRestricted() then
		return
	end
	if ns.cache:fresh(guid)
		or self:heldSuppressed(guid)
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
-- A send's chunks enqueue contiguously, so the queue tail position recorded
-- at issue is in flight until the head passes it.
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
-- Entries are re-validated on release.
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
		if not ns.cache:fresh(entry.guid)
			and not self:heldSuppressed(entry.guid)
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

--- Pick the contact for a unicast REQ. A BNet-reachable subject wins
-- outright; otherwise a round-robin cursor walks confirmed BNet peers,
-- then guild relays, then community relays.
function Broadcast:reqContact(guid, now)
	local comms = ns.comms
	if guid then
		local info = C_BattleNet.GetGameAccountInfoByGUID(guid)
		local id = info and info.gameAccountID
		if id and comms:isBNetConfirmed(id, now) then
			return { medium = "BNET", target = id }
		end
	end
	local list = {}
	for _, id in ipairs(comms:bnetAccounts()) do
		if comms:isBNetConfirmed(id, now) then
			list[#list + 1] = { medium = "BNET", target = id }
		end
	end
	for _, p in pairs(self.relays) do
		if p.conf ~= 0 and (now - p.conf) < C.RELAY_CONFIRM_TTL
			and Util.isClubMemberOnline(p.name)
		then
			if Util.isGuildClubMember(p.name) then
				list[#list + 1] = { medium = "WHISPER", target = p.name }
			end
		end
	end
	for _, p in pairs(self.relays) do
		if p.conf ~= 0 and (now - p.conf) < C.RELAY_CONFIRM_TTL
			and Util.isClubMemberOnline(p.name)
			and not Util.isGuildClubMember(p.name)
			and Util.isCommunityClubMember(p.name)
		then
			list[#list + 1] = { medium = "WHISPER", target = p.name }
		end
	end
	if #list == 0 then
		return nil
	end
	self.contactIdx = (self.contactIdx % #list) + 1
	return list[self.contactIdx]
end

--- Issue one request as a unicast REQ to the next contact.
function Broadcast:issueRequest(guid, unitID, now)
	-- Stamp the cooldown up front so a failed send cannot retry-storm.
	self.recentReqs[guid] = now
	local chunks = self:buildCtl("REQ", reqArg(guid, unitID))
	local comms = ns.comms
	local contact = self:reqContact(guid, now)
	if not contact
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
	if ns.debugEnabled("targets") then
		for _, name in pairs(self.forcedTargets) do
			comms:sendChunksAddon(chunks, "WHISPER", name)
		end
	end
	self.requests[guid] = {
		state = "contact", at = now, unitID = unitID,
		medium = contact.medium, target = contact.target,
	}
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
-- subjects only: a shared club, group membership, or BNet friendship
-- already provides a direct or native pull path, so broadcasting would
-- duplicate work the rest of the system already does.
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
-- accepted recently. noteSeen re-arms holdUntil on every accepted store;
-- a register purge (profileMeta nil) releases the suppression early.
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
-- honest (possibly stale) originTime stamps it as a floor, fresher mesh
-- data still wins on landing, and it gives the requester content even
-- when the mesh misses entirely.
function Broadcast:publishHeld(guid, unitID)
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

--- Send the REQ on the faction channel when the self-rate gate is open;
-- promotes `req` from chan-wait to broadcast. A missing channel index
-- (join still pending) or queue-full leg just stays parked.
function Broadcast:pumpChannelReq(guid, req, now)
	if (now - self.lastChannelReqAt) < C.REQ_CHANNEL_INTERVAL then
		return
	end
	local comms = ns.comms
	local idx = comms:channelIndex()
	if not idx
		or not comms:sendChunksAddon(
			self:buildCtl("REQ", reqArg(guid, req.unitID)), "CHANNEL", idx)
	then
		return
	end
	self.lastChannelReqAt = now
	req.state = "broadcast"
	req.at = now
	req.acks = {}
	self.fanoutInFlight[#self.fanoutInFlight + 1] = comms.queue.tail
	if ns.statsLeg then
		ns.statsLeg("req_chan", 1)
	end
	if ns.debugPeer then
		ns.debugPeer("req " .. (req.unitID or Util.nameForGuid(guid))
			.. " -> channel")
	end
end

--- Move a failed request onto the channel leg, once per request and for
-- eligible stranger subjects only. Our own held copy publishes first —
-- free content while the offers collect.
-- @return boolean Whether the request lives on (false = drop it).
function Broadcast:tryChannelFallback(guid, req, now)
	if req.channeled or not self:channelEligible(guid, req.unitID) then
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
-- max(content claim, directory last-seen), ties to the earliest arrival.
-- Denied offerers are never told; their pendingServes expire on their own.
-- @return boolean Whether a grant went out.
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
		self:buildCtl("OK", guid), best.medium, best.target)
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
-- record's as-of stamp, or the register's last-seen stamp when it holds
-- content the record does not cover. Self is authoritative.
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
	local adapter = ns.getAvailableAdapter()
	local profile = adapter and adapter:extract(serve.unitID)
	local encoded = profile and Serializer.encodeProfile(profile.data)
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
	-- position is in flight until the head passes it. Mesh (channel-path)
	-- serves arm the post-serve cooldown on drain; self-serves are exempt.
	self.serveDrainPos = ns.comms.queue.tail
	if serve.medium ~= "WHISPER" and serve.medium ~= "BNET"
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
-- guid->unitID map, the client player-info cache, the club roster, and the
-- wire-asserted unitID must all agree. Any conflict or empty claim set is
-- a miss.
-- @param guid       string The requested subject GUID.
-- @param wireUnitID string The requester-asserted unitID ("" when absent).
-- @return string|nil The consensus unitID, or nil on conflict/no claims.
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

--- Post-serve broadcast mute, scaled to mesh size: a thin mesh gets
-- SERVE_CHANNEL_COOLDOWN_MIN (availability beats dedup when we may be the
-- only holder), a dense one ramps linearly to the MAX at
-- SERVE_MESH_DENSE members. Unknown size counts as thin.
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
-- leaves the send queue the marker clears; a drained *mesh* serve then
-- arms the post-serve cooldown. Runs lazily wherever the mute is checked,
-- so the cooldown engages even if no REQ ever arrives.
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
-- or a copy no newer than their advertised claim of the same lineage.
-- Returns the honest offer stamp as second value for the ACK.
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
-- serve awaiting the requester's OK. Shared by the immediate path and the
-- deferred flush so the advertised claim is evaluated at decision time.
-- @return boolean Whether an ACK was sent.
function Broadcast:tryAck(subject, unitID, adapter, medium, target,
						  reqAt, reqPid, reqCvh, selfReq)
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
	-- arg3 advertises our TRP3 directory last-seen stamp: requesters
	-- collecting channel offers weigh it against the content claim.
	local meta = adapter.profileMeta and adapter:profileMeta(unitID)
	local dirAt = (meta and meta.at) or 0
	if not self:sendToPeer(
		self:buildCtl("ACK", subject .. " " .. offerAt .. " " .. dirAt),
		medium, target
	) then
		return false
	end
	self.pendingServes[serveKey(target, subject)] = {
		subject = subject, unitID = unitID,
		medium = medium, target = target, at = now,
	}
	if leg then
		leg("ack", 1)
	end
	if peer then
		peer("ack " .. subject .. " -> " .. tostring(target))
	end
	return true
end

--- Answer a unicast REQ. One peer asked, so there is no race to arbitrate:
-- ACK marks the requester's data window, then we serve as soon as the
-- RP-AddOn refresh lands or the deferral lapses. Suppressed serves and
-- unreachable sends stay silent; the requester advances on its timeout.
function Broadcast:serveUnicast(subject, unitID, adapter, medium, target,
								reqAt, reqPid, reqCvh, selfReq)
	local suppressed, offerAt = self:suppressable(
		subject, unitID, adapter, reqAt, reqPid, reqCvh, selfReq)
	if suppressed then
		return
	end
	local meta = adapter.profileMeta and adapter:profileMeta(unitID)
	local dirAt = (meta and meta.at) or 0
	if not self:sendToPeer(
		self:buildCtl("ACK", subject .. " " .. offerAt .. " " .. dirAt),
		medium, target
	) then
		return
	end
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
		and not serveFreshEnough(adapter, unitID, reqAt)
		and adapter:refreshQuery(unitID)
	then
		local key = serveKey(target, subject)
		self.freshenPending[key] = {
			mode = "serve", subject = subject, unitID = unitID,
			medium = medium, target = target,
		}
		C_Timer.After(C.REQ_FRESHEN_DELAY, function()
			self:flushFreshen(key)
		end)
		if ns.debugPeer then
			ns.debugPeer("freshen " .. Util.nameForGuid(subject)
				.. " (defer serve -> " .. tostring(target) .. ")")
		end
	else
		self:serveData({
			subject = subject, unitID = unitID,
			medium = medium, target = target,
		})
	end
end

--- Resolve a deferred REQ on timer expiry or landed data. Re-checks the
-- serve gate, which can change during the wait; channel entries also
-- re-check the cooldown.
function Broadcast:flushFreshen(key)
	local entry = self.freshenPending[key]
	if not entry then
		return
	end
	self.freshenPending[key] = nil
	if entry.mode ~= "serve" and self:serveThrottled(GetTime()) then
		return
	end
	local adapter = ns.getAvailableAdapter()
	-- The profile could have been purged during the deferral.
	if not (adapter and adapter.canServe and adapter:canServe(entry.unitID)) then
		return
	end
	if entry.mode == "serve" then
		-- A `*` stub may have refreshed into a real profile mid-wait.
		if adapter.isDefaultUnit and adapter:isDefaultUnit(entry.unitID) then
			return
		end
		self:serveData(entry)
	else
		self:tryAck(entry.subject, entry.unitID, adapter, entry.medium,
			entry.target, entry.reqAt, entry.reqPid, entry.reqCvh, false)
	end
end

--- A unit's register profile was written (our freshen query, native exchange,
-- MSP merge, profileID rebind): flush deferred ACKs waiting on that unit.
function Broadcast:onFreshenReceived(unitID)
	for key, entry in pairs(self.freshenPending) do
		if entry.unitID == unitID then
			self:flushFreshen(key)
		end
	end
end

--- Dispatch an inbound control message. Reachable on every medium; the
-- HELLO/HI verbs only carry meaning over BNet.
function Broadcast:onControl(msg, context)
	local comms = ns.comms
	local now = GetTime()
	local verb, arg, arg2, arg3, arg4, arg5 =
		msg.data:match("^FRP1 (%S+)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)")
	if not verb then
		return
	end
	-- Exchange verbs carry a subject GUID; empty args (arg == "") are malformed.
	if arg == "" and verb ~= "HELLO" and verb ~= "HI" then
		return
	end
	local target = context.gameAccountID or context.senderName
	if not target then
		return -- no way to address the peer back
	end
	local leg = ns.statsLeg
	local peer = ns.debugPeer

	if verb == "HELLO" then
		if context.medium == "BNET" and context.gameAccountID then
			comms:bnetPeerSeen(context.gameAccountID, arg)
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
				p.version = arg
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
			comms:bnetPeerSeen(context.gameAccountID, arg)
		elseif context.medium == "WHISPER" and context.senderName then
			-- Inbound already confirmed them; record the version.
			local key = Util.normalizeUnitName(context.senderName)
			local p = key and self.relays[key]
			if p then
				p.version = arg
			end
		end
	elseif verb == "REQ" then
		if context.medium ~= "WHISPER" and context.medium ~= "BNET" then
			-- Channel REQs are throttled per requester before any work;
			-- legit clients self-rate at the same interval, so this only
			-- bounds spam (and old fanout-era builds).
			local lastChan = self.chanReqSenderAt[target]
			if lastChan and (now - lastChan) < C.REQ_CHANNEL_SENDER_INTERVAL then
				return
			end
			self.chanReqSenderAt[target] = now
		end
		-- "Who can serve subject `arg`?" Ourselves answer directly; anyone
		-- else resolves by identity consensus. canServe reads the register
		-- live, so cache-absent subjects are still servable.
		local selfReq = (arg == self:senderGUID())
		local unitID
		if selfReq then
			unitID = ownUnitID()
		else
			unitID = self:resolveSubject(arg, arg2)
		end
		local adapter = ns.getAvailableAdapter()
		local reqAt = tonumber(arg3) or 0
		if context.medium ~= "WHISPER" and context.medium ~= "BNET" then
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
			if not selfReq and adapter.refreshQuery then
				local freshenN = 0
				for _ in pairs(self.freshenPending) do
					freshenN = freshenN + 1
				end
				if freshenN < C.REQ_FRESHEN_MAX
					and not serveFreshEnough(adapter, unitID, reqAt)
					and adapter:refreshQuery(unitID)
				then
					local key = serveKey(target, arg)
					self.freshenPending[key] = {
						subject = arg, unitID = unitID,
						medium = context.medium, target = target,
						reqAt = reqAt, reqPid = arg4, reqCvh = arg5,
					}
					C_Timer.After(C.REQ_FRESHEN_DELAY, function()
						self:flushFreshen(key)
					end)
					if peer then
						peer("freshen " .. arg .. " (defer ack -> "
							.. tostring(target) .. ")")
					end
					return
				end
			end
			self:tryAck(arg, unitID, adapter, context.medium, target,
				reqAt, arg4, arg5, selfReq)
			return
		end
		-- Unicast path: per-sender throttle, then serve or silence.
		local lastReq = self.reqSenderAt[target]
		if lastReq and (now - lastReq) < C.REQ_SENDER_INTERVAL then
			return
		end
		self.reqSenderAt[target] = now
		if unitID and adapter and adapter.canServe
			and adapter:canServe(unitID)
		then
			self:serveUnicast(arg, unitID, adapter, context.medium, target,
				reqAt, arg4, arg5, selfReq)
		end
		-- Misses stay silent.
	elseif verb == "ACK" then
		-- offerAt is the holder's content claim; arg3 is its TRP3
		-- directory last-seen stamp. A claim at or under our persisted
		-- floor cannot carry anything newer — silence is rejection.
		local req = self.requests[arg]
		local offerAt = tonumber(arg2) or 0
		if req and (offerAt + C.FRESHNESS_SKEW)
			< ns.cache:freshnessFloor(arg, req.unitID)
		then
			if peer then
				peer("ack " .. arg .. " <- " .. tostring(target)
					.. " denied (stale claim)")
			end
		elseif req and req.state == "contact" and req.target == target then
			-- The contact answered; open the data window.
			req.state = "awaiting-data"
			req.at = now
			req.winner = { medium = context.medium, target = target }
			-- Compat: earlier proto-5 servers gate the serve on OK.
			self:sendToPeer(self:buildCtl("OK", arg), context.medium, target)
			if leg then
				leg("ok", 1)
			end
			if peer then
				peer("ack " .. (req.unitID or Util.nameForGuid(arg))
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
			self:sendToPeer(self:buildCtl("OK", arg), context.medium, target)
			if leg then
				leg("ok", 1)
			end
			if peer then
				peer("ack " .. (req.unitID or Util.nameForGuid(arg))
					.. " <- " .. tostring(target) .. " (late contact)")
			end
		elseif req and req.state == "broadcast"
			and target ~= req.deadTarget
		then
			-- Collect the offer; the window end grants the freshest.
			if req.acks and #req.acks < C.REQ_CHANNEL_ACK_CAP then
				req.acks[#req.acks + 1] = {
					medium = context.medium, target = target,
					offerAt = offerAt, dirAt = tonumber(arg3) or 0,
				}
				if peer then
					peer("ack " .. arg .. " <- " .. tostring(target)
						.. " (offer " .. #req.acks .. ")")
				end
			end
		end
	elseif verb == "OK" then
		local key = serveKey(target, arg)
		local serve = self.pendingServes[key]
		if serve then
			self.pendingServes[key] = nil
			self:serveData(serve)
		end
	elseif verb == "NOK" then
		self.pendingServes[serveKey(target, arg)] = nil
		self.freshenPending[serveKey(target, arg)] = nil
	elseif verb == "VER" then
		-- Peer version announcement. Print a notice when it beats ours,
		-- deduped by the highest version seen this session.
		if not self.topPeerVersion
			or Util.versionCompare(arg, self.topPeerVersion) > 0
		then
			self.topPeerVersion = arg
			local own = ownVersion()
			if Util.versionCompare(arg, own) > 0
				and (not self.notifiedVersion
					or Util.versionCompare(arg, self.notifiedVersion) > 0)
			then
				self.notifiedVersion = arg
				ns.Print(("|cffffd200outdated:|r A new version of FactionRP is available. Please update to %s. (Yours: %s)"):format(arg, own))
				if peer then
					peer("update notice for " .. arg)
				end
			end
		end
	end
end

-- Origination ---------------------------------------------------------------

--- Publish a freshly-extracted profile into our cache. Sends nothing.
-- @param guid    string The subject's GUID.
-- @param unitID  string The subject's "Name-Realm".
-- @param profile table  { addon, contentVersion, data } from an adapter.
function Broadcast:publish(guid, unitID, profile)
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
	local msg = Serializer.parseMessage(raw)
	-- A non-numeric originTime would break the cache's ordering compare.
	if not msg or type(msg.originTime) ~= "number" then
		if ns.statsError then
			ns.statsError("malformed")
		end
		ns.comms:blockSender(context.senderKey)
		return
	end

	-- Hard protocol gate, before any peer-state side effects.
	if not msg.protoVer or msg.protoVer < C.PROTO_MAJOR then
		if ns.statsError then
			ns.statsError("proto_old")
		end
		ns.comms:blockSender(context.senderKey)
		return
	end

	-- Drop our own echoed traffic.
	if msg.sender == self:senderGUID() then
		if ns.statsError then
			ns.statsError("self_echo")
		end
		return
	end
	-- A parseable inbound whisper from an xfac club member confirms a
	-- relay; ctl verbs confirm senders too.
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
		end
	end
	-- Any parseable BNet message confirms the account runs FactionRP.
	if context.medium == "BNET" and context.gameAccountID then
		ns.comms:bnetPeerSeen(context.gameAccountID)
	end
	-- Control messages never reach the cache or register.
	if msg.subject == C.CTL_SUBJECT then
		self:onControl(msg, context)
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
		unitID = msg.unitID,
		addon = msg.addon,
		originTime = msg.originTime,
		contentVersion = msg.contentVersion,
	}

	-- peek first: duplicates and stale copies skip the expensive decode.
	local result = ns.cache:peek(candidate)
	if not result then
		local profileData = Serializer.decodeProfile(msg.data)
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
-- Deduped by GUID.
function Broadcast:queueInject(candidate)
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
-- @return string|nil The normalized "Name-Realm".
function Broadcast:forceTarget(unitID)
	local key = unitID and Util.normalizeUnitName(unitID)
	local display = key and Util.fullUnitName(unitID)
	if key and display then
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
-- AddOn's own comms. Informational only: unicast picks FRP-confirmed
-- contacts.
function Broadcast:noteXfacContact(unitID)
	local key = unitID and Util.normalizeUnitName(unitID)
	if key then
		self.xfacContacts[key] = unitID
	end
end

-- Singleton.
ns.broadcast = Broadcast:new()
ns.OnLogin(function()
	ns.broadcast:start()
end)
