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
	--   requests[guid]  = { state = "contact"|"channel"|"awaiting-data",
	--                       at, unitID, medium, target,
	--                       winner = { medium, target }|nil }
	--   recentReqs[guid] = last request time (per-subject cooldown)
	--   reqQueued[guid] + reqQueueOrder: deduped FIFO of waiting subjects
	--   contactIdx: round-robin contact cursor
	--   pendingServes[key] = { subject, unitID, medium, target, at }
	--     key = "<peer>:<guid>"; channel-path grants awaiting OK
	--   freshenPending[key] = { mode, subject, unitID, medium, target,
	--                           reqAt, reqPid, reqCvh }
	--     mode "ack": channel REQ whose ACK waits on an RP-AddOn refresh
	--     mode "serve": unicast REQ whose data leg waits on the refresh
	--   reqSenderAt[senderKey] = last inbound unicast REQ time (throttle)
	self.requests = {}
	self.recentReqs = {}
	self.pendingServes = {}
	self.freshenPending = {}
	self.reqQueued = {}
	self.reqQueueOrder = { head = 1, tail = 0 }
	self.contactIdx = 0
	self.reqSenderAt = {}
	self.fanoutInFlight = {} -- queue tail positions of issued probes
	self.relayProbeAt = 0 -- last whisper probe burst
	self.probeCursor = 0 -- rotating index into the flattened probe rosters

	-- Channel serve breaker: mute broadcast REQs after SERVE_RATE_LIMIT
	-- granted serves inside SERVE_RATE_WINDOW.
	self.serveWindowAt = 0
	self.serveCount = 0
	self.serveMuteUntil = 0

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

--- Is `key` currently on the whisper ignore list?
function Broadcast:relayIgnored(key, now)
	local p = self.relays[key]
	return p ~= nil and p.ign ~= 0 and (now - p.ign) < C.RELAY_IGNORE_TTL
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
			if p and p.ign ~= 0 and (now - p.ign) >= C.RELAY_IGNORE_TTL then
				p.ign, p.pr = 0, 0 -- served their time: fresh slate
			end
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

-- Pull exchange --------------------------------------------------------------

--- BNet and whisper probe rotations plus exchange expiry, one ticker.
function Broadcast:tick()
	local now = GetTime()
	local comms = ns.comms
	local restricted = Util.commsRestricted()

	-- Request expiry still runs while restricted, but contact timeouts
	-- drop outright: a response window lost to restriction cannot be
	-- recovered by a channel fallback.
	local pump = false
	for guid, req in pairs(self.requests) do
		if req.state == "contact"
			and (now - req.at) > C.REQ_CONTACT_TIMEOUT
		then
			if restricted then
				self.requests[guid] = nil
				self.recentReqs[guid] = now
				pump = true
				if ns.debugPeer then
					ns.debugPeer("req " .. guid .. " dropped (restricted)")
				end
			else
				local idx = comms:channelIndex()
				local sent = idx and comms:sendChunksAddon(
					self:buildCtl("REQ", reqArg(guid, req.unitID)),
					"CHANNEL", idx)
				if sent then
					req.state = "channel"
					req.at = now
					req.medium, req.target = nil, nil
					self.fanoutInFlight[#self.fanoutInFlight + 1] = comms.queue.tail
					if ns.statsLeg then
						ns.statsLeg("channel", 1)
					end
					if ns.debugPeer then
						ns.debugPeer("req " .. guid .. " -> channel (contact silent)")
					end
				else
					self.requests[guid] = nil
					self.recentReqs[guid] = now
					pump = true
				end
			end
		elseif req.state == "channel"
			and (now - req.at) > C.REQ_ACK_TIMEOUT
		then
			self.requests[guid] = nil
			self.recentReqs[guid] = now
			pump = true
			if ns.debugPeer then
				ns.debugPeer("req " .. guid .. " expired (channel)")
			end
		elseif req.state == "awaiting-data"
			and (now - req.at) > C.REQ_DATA_TIMEOUT
		then
			-- The serve stalled or died; drop the sender's partial chunks
			-- so a resumed send cannot complete a ghost message.
			local src = req.winner or req
			if src.medium and src.target then
				local key = comms:senderKeyFor(src.medium, src.target)
				if comms.assembler:drop(key) > 0 and ns.debugPeer then
					ns.debugPeer("dropped partial data from " .. tostring(key))
				end
			end
			self.requests[guid] = nil
			self.recentReqs[guid] = now
			pump = true
			if ns.debugPeer then
				ns.debugPeer("req " .. guid .. " expired (awaiting-data)")
			end
		end
	end
	if pump and not restricted then
		self:pumpRequests()
	end

	if restricted then
		return -- no probes, sends, or further transitions while restricted
	end

	-- Probe the next unconfirmed BNet account. Probes consume the
	-- in-flight budget, so none go out while the queue holds the cap.
	if self:fanoutsInFlight() < C.FANOUT_INFLIGHT_MAX then
		local id = comms:probeTarget(now)
		if id and comms:sendChunksBNet(self:ctlHello(), id) then
			comms:markProbed(id, now)
			self.fanoutInFlight[#self.fanoutInFlight + 1] = comms.queue.tail
			if ns.statsLeg then
				ns.statsLeg("bnet_probe", 1)
			end
			if ns.debugPeer then
				ns.debugPeer("probe -> bnet " .. id)
			end
		end
	end

	-- Whisper relay probes in bursts. The rotation returns unconfirmed
	-- candidates only; a saturated queue ends the burst early.
	if (now - self.relayProbeAt) >= C.RELAY_PROBE_INTERVAL then
		self.relayProbeAt = now
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

	-- Prune the unicast REQ throttle; entries only matter within the window.
	for sender, at in pairs(self.reqSenderAt) do
		if (now - at) > C.REQ_SENDER_INTERVAL then
			self.reqSenderAt[sender] = nil
		end
	end

end

--- Queue a request for `guid`'s profile. No-op when the cache is fresh,
-- the subject is pending or queued, or it is on cooldown.
function Broadcast:requestProfile(guid, unitID)
	if not guid or Util.commsRestricted() then
		return
	end
	if ns.cache:fresh(guid)
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

--- Issue one request: a unicast REQ to the next contact, or a channel
-- broadcast when none is reachable. Pinned targets get a copy either way.
function Broadcast:issueRequest(guid, unitID, now)
	-- Stamp the cooldown up front so a failed send cannot retry-storm.
	self.recentReqs[guid] = now
	local chunks = self:buildCtl("REQ", reqArg(guid, unitID))
	local comms = ns.comms
	local contact = self:reqContact(guid, now)
	local state
	if contact then
		if self:sendToPeer(chunks, contact.medium, contact.target) then
			state = "contact"
		end
	else
		local idx = comms:channelIndex()
		if idx and comms:sendChunksAddon(chunks, "CHANNEL", idx) then
			state = "channel"
			if ns.statsLeg then
				ns.statsLeg("channel", 1)
			end
		end
	end
	if not state then
		return -- nobody reachable
	end
	self.fanoutInFlight[#self.fanoutInFlight + 1] = comms.queue.tail
	if ns.debugEnabled("targets") then
		for _, name in pairs(self.forcedTargets) do
			comms:sendChunksAddon(chunks, "WHISPER", name)
		end
	end
	self.requests[guid] = {
		state = state, at = now, unitID = unitID,
		medium = contact and contact.medium,
		target = contact and contact.target,
	}
	if ns.statsLeg then
		ns.statsLeg("req", 1)
	end
	if ns.debugFanout then
		ns.debugFanout(contact
			and (contact.medium .. " " .. tostring(contact.target))
			or "channel")
	end
	if ns.debugPeer then
		ns.debugPeer("req " .. guid .. " -> "
			.. (contact and (contact.medium .. " " .. tostring(contact.target))
				or "channel"))
	end
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
	self:sendToPeer(chunks, serve.medium, serve.target)
	if ns.statsOutMessage then
		ns.statsOutMessage(#message, #chunks, serve.subject, "serve")
	end
	if ns.statsLeg then
		ns.statsLeg("serve", 1)
	end
	if ns.debugPeer then
		ns.debugPeer("serve " .. serve.subject .. " -> " .. serve.target)
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
			ns.debugPeer("req " .. guid .. " dropped (identity conflict)")
		end
		return nil
	end
	if unitID and not hadLocal then
		if ns.debugPeer then
			ns.debugPeer("req " .. guid .. " resolved via wire unitID " .. unitID)
		end
	end
	return unitID
end

--- True while the channel serve breaker is engaged.
function Broadcast:serveThrottled(now)
	if now < self.serveMuteUntil then
		return true
	end
	if (now - self.serveWindowAt) >= C.SERVE_RATE_WINDOW then
		self.serveWindowAt = now
		self.serveCount = 0
	end
	return false
end

--- Count a granted channel serve. On hitting the window limit, mute for
-- SERVE_RATE_MUTE; muted grants still complete but do not count.
function Broadcast:bumpServe(now)
	if now < self.serveMuteUntil then
		return
	end
	self.serveCount = self.serveCount + 1
	if self.serveCount >= C.SERVE_RATE_LIMIT then
		self.serveMuteUntil = now + C.SERVE_RATE_MUTE
		self.serveWindowAt = now
		if ns.statsError then
			ns.statsError("serve_throttled")
		end
		ns.debugPeer("serve throttled: " .. C.SERVE_RATE_LIMIT .. " serves/" .. C.SERVE_RATE_WINDOW .. "s reached")
	end
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
			peer("ack " .. subject .. " -> " .. tostring(target)
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
	if not self:sendToPeer(
		self:buildCtl("ACK", subject .. " " .. offerAt), medium, target
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
	if not self:sendToPeer(
		self:buildCtl("ACK", subject .. " " .. offerAt), medium, target
	) then
		return
	end
	if ns.statsLeg then
		ns.statsLeg("ack", 1)
	end
	if ns.debugPeer then
		ns.debugPeer("ack " .. subject .. " -> " .. tostring(target))
	end
	local freshenN = 0
	for _ in pairs(self.freshenPending) do
		freshenN = freshenN + 1
	end
	if not selfReq
		and adapter.refreshQuery
		and freshenN < C.REQ_FRESHEN_MAX
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
			ns.debugPeer("freshen " .. subject .. " (defer serve -> "
				.. tostring(target) .. ")")
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
-- re-check the breaker.
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
			-- arbitration and the serve breaker still apply.
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
		-- Unicast: the contact answered, open the data window. Channel:
		-- holders race, and a claim at or below our floor is denied.
		local req = self.requests[arg]
		if req and req.state == "contact"
			and req.target == target
		then
			req.state = "awaiting-data"
			req.at = now
			-- Compat: earlier proto-5 servers gate the serve on OK.
			self:sendToPeer(self:buildCtl("OK", arg), context.medium, target)
			if leg then
				leg("ok", 1)
			end
			if peer then
				peer("ack " .. arg .. " <- " .. tostring(target))
			end
			return
		end
		local ackAt = tonumber(arg2) or 0
		local stale = req ~= nil
			and ackAt + C.FRESHNESS_SKEW
				< ns.cache:freshnessFloor(arg, req.unitID)
		local won = req
			and not stale
			and req.state == "channel"
			and target
			and self:sendToPeer(self:buildCtl("OK", arg), context.medium, target)
		if won then
			req.winner = { medium = context.medium, target = target }
			req.state = "awaiting-data"
			req.at = now
			if leg then
				leg("ok", 1)
			end
			if peer then
				peer("ack " .. arg .. " <- " .. tostring(target) .. " (granted)")
			end
		elseif peer and req then
			-- Denied ACKs get no reply.
			peer("ack " .. arg .. " <- " .. tostring(target)
				.. (stale and " (denied: stale)" or " (denied)"))
		end
	elseif verb == "OK" then
		local key = serveKey(target, arg)
		local serve = self.pendingServes[key]
		if serve then
			self.pendingServes[key] = nil
			-- Only granted serves count toward the breaker.
			if serve.subject ~= self:senderGUID() then
				self:bumpServe(now)
			end
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

	-- Data for a pending subject completes the exchange. Channel arbitration
	-- only: if it came from a non-winner, NOK the winner so it stops.
	local req = self.requests[msg.subject]
	if req then
		local src = context.gameAccountID or context.senderName
		if req.winner
			and (req.winner.medium ~= context.medium or req.winner.target ~= src)
		then
			self:sendToPeer(
				self:buildCtl("NOK", msg.subject),
				req.winner.medium, req.winner.target
			)
		end
		self.requests[msg.subject] = nil
		self.recentReqs[msg.subject] = GetTime()
		if ns.debugPeer then
			ns.debugPeer("data " .. msg.subject .. " <- " .. tostring(src))
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
