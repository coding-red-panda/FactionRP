-- Broadcast.lua
--
-- The pull-exchange engine. Profile data never floods: it travels exactly
-- once, server -> requester, after a granted request. The only multi-target
-- traffic is single-chunk FRP1 control messages (subject "_frp"):
--
--   requester: REQ <guid> -> first ACKer gets OK, the rest time out
--   server:    REQ -> ACK (if it can extract the profile) -> on OK, the
--              data envelope goes direct to the requester
--
-- BNet legs only reach *confirmed* peers — accounts that have answered a
-- HELLO/HI handshake or sent us any parseable FactionRP message.
--
-- SENDER vs SUBJECT: SENDER is always the *immediate* sender (us, whenever we
-- serve or relay) and is used purely for loop avoidance. SUBJECT is the
-- profile owner and never changes as a message is relayed.

local _, ns = ...
local C = ns.Const
local Serializer = ns.Serializer
local Util = ns.Util

local Broadcast = ns.Class("Broadcast")
ns.Broadcast = Broadcast

function Broadcast:init()
	self.playerGUID = nil -- refreshed per use by senderGUID()
	-- Cross-faction relay lifecycle (session-only), keyed by normalized
	-- "name-realm" — same probe/confirm/ignore shape as BNet peers:
	--   relays[key] = {
	--     name    display "Name-Realm" for sending/debugging,
	--     conf    last inbound-proof time (confirmed relay while fresh),
	--     lp      last probe sent        pr   consecutive unanswered probes,
	--     ign     ignored-since time     lastHi last HI we sent them,
	--     version peer's addon version (when seen)
	--   }
	--   xfacContacts: opposite-faction club members whose profiles reached us
	--                 via the RP AddOn's own comms — proven cross-faction
	--                 reachable RP-AddOn users, though maybe not FRP users.
	self.relays = {}
	self.xfacContacts = {}

	-- Community-relay fairness state: per-contact usage counts (so no single
	-- member becomes a relay server) and a round-robin cursor spreading picks
	-- across the candidate list.
	self.commUsage = {} -- [normalized name] = { count, at }
	self.commCursor = 0

	-- Profiles queued for injection into the RP AddOn's register so its
	-- directory fills as gossip lands (drained at a bounded rate).
	self.injectQueue = {} -- [guid] = candidate
	self.injectOrder = { head = 1, tail = 0 } -- FIFO of guids

	-- Pinned whisper targets for testing (/frp target), keyed by normalized
	-- name. Always sent on every fanout, bypassing leg membership and caps.
	self.forcedTargets = {}

	-- Reused fanout scratch, wiped per call so a fanout allocates nothing:
	-- fanoutSentKeys dedups targets across legs, legCandidates/legSeen hold
	-- one leg's ordered candidate keys and their display names.
	self.fanoutSentKeys = {}
	self.legCandidates = {}
	self.legSeen = {}

	-- The last fanout's chosen targets per leg ("/frp relays" + the fanout
	-- debug line): arrays wiped and refilled each fanout.
	self.lastLegPicks = { community = {}, guild = {}, bnet = {}, pinned = {} }

	-- Pull-exchange state (session-only):
	--   requests[guid]  = { state = "open"|"awaiting-data", at, unitID,
	--                       winner = { medium, target }|nil }
	--   recentReqs[guid] = last request time (per-subject cooldown)
	--   pendingServes[key] = { subject, unitID, medium, target, at }
	--     where key = "<peer>:<guid>" — grants we may serve.
	-- Global fanout pacing: sightings arrive in bursts but the mesh hears at
	-- most one request per REQ_ISSUE_INTERVAL. Deferred subjects wait in a
	-- dedup'd FIFO and are re-validated when released.
	self.requests = {}
	self.recentReqs = {}
	self.pendingServes = {}
	self.reqBacklog = {} -- [guid] = true (membership, for dedup)
	self.reqBacklogOrder = { head = 1, tail = 0 } -- FIFO of { guid, unitID }
	self.lastFanoutAt = 0 -- GetTime() of the last issued fanout
	self.fanoutInFlight = {} -- queue tail positions of issued fanouts/probes
	self.relayProbeAt = 0 -- last whisper probe burst
	self.probeCursor = 0 -- rotating index into the flattened probe rosters

	-- Outbound serve breaker (fixed window): once SERVE_RATE_LIMIT granted
	-- serves land inside SERVE_RATE_WINDOW we stop answering REQs until
	-- serveMuteUntil.
	self.serveWindowAt = 0
	self.serveCount = 0
	self.serveMuteUntil = 0

	-- Version announcement (issue #19): newest peer version heard this session
	-- (VER broadcasts on the comm channel) and the version we last printed an
	-- update notice for (dedup — several older peers logging in must not spam).
	self.topPeerVersion = nil
	self.notifiedVersion = nil
	self.verAttempts = 0
end

--- Own GUID, fetched fresh and validated on every use. A nil result
-- degrades sends to encode_fail rather than stamping a bad sender.
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
	C_Timer.NewTicker(C.INJECT_INTERVAL, function()
		self:drainInject()
		self:drainRequests()
	end)
	-- One ticker drives the BNet + whisper probe rotations and the sweeps.
	C_Timer.NewTicker(C.BNET_PROBE_INTERVAL, function()
		self:tick()
	end)

	-- Issue #19: announce our addon version once per session so out-of-date
	-- peers on the comm channel hear it. Delayed past login because the
	-- channel join completes asynchronously; retried while it pends.
	C_Timer.After(C.VER_BROADCAST_DELAY, function()
		self:broadcastVersion()
	end)
end

-- Helpers -------------------------------------------------------------------

-- Leg-membership predicates for _sendLeg, hoisted so fanout allocates no
-- closures.
local function inCommunity(unitID)
	return Util.isCommunityClubMember(unitID)
end

local function inGuild(unitID)
	return Util.isGuildClubMember(unitID)
end

--- Record `name` as a leg candidate if not already seen.
-- @param candidates table Ordered array of normalized keys.
-- @param seen       table Normalized key -> display name.
local function addCandidate(candidates, seen, name)
	local key = name and Util.normalizeUnitName(name)
	if key and not seen[key] then
		seen[key] = name
		candidates[#candidates + 1] = key
	end
end

--- Usage-budget helpers for the community/guild whisper legs (methods so no
-- per-fanout closures). `now` is stamped once per fanout by the caller.
function Broadcast:usageAt(key, now)
	local u = self.commUsage[key]
	if not u or (now - u.at) > C.COMM_USAGE_WINDOW then
		return 0
	end
	return u.count
end

function Broadcast:bumpUsage(key, now)
	local u = self.commUsage[key]
	if not u then
		u = { count = 0, at = 0 }
		self.commUsage[key] = u
	end
	-- Reuse the entry across window expiries (reset in place, no realloc).
	if (now - u.at) <= C.COMM_USAGE_WINDOW then
		u.count = u.count + 1
	else
		u.count = 1
	end
	u.at = now
end

--- Fetch-or-create the relay lifecycle record for `key` (normalized
-- "name-realm"). `name` refreshes the display name when given.
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

--- Next probe target via rotating cursor over both rosters: one probe per
--- target, and an unanswered one past RELAY_PROBE_COOLDOWN ignores the
--- target instead of re-probing. Confirmed relays are never probed.
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

--- One leg's selection: confirmed FRP relays and known xfac contacts first
-- (filtered to that leg's membership), then the leg's opposite-faction
-- roster. A rotating cursor spreads picks across candidates; pass 1 skips
-- usage-exhausted contacts, pass 2 fills with them if coverage requires.
-- Uses shared wiped scratch (self.legCandidates/legSeen/fanoutSentKeys) so
-- candidate building allocates nothing.
-- @return number Sends made this leg.
function Broadcast:_sendLeg(chunks, roster, inLeg, limit, skipName, now, picks)
	local comms = ns.comms
	local sentKeys = self.fanoutSentKeys
	local candidates = self.legCandidates
	local seen = self.legSeen
	for i = #candidates, 1, -1 do
		candidates[i] = nil
	end
	for key in pairs(seen) do
		seen[key] = nil
	end
	if picks then
		for i = #picks, 1, -1 do
			picks[i] = nil
		end
	end

	if skipName then
		seen[skipName] = skipName
	end
	for _, p in pairs(self.relays) do
		if p.conf ~= 0 and (now - p.conf) < C.RELAY_CONFIRM_TTL
			and Util.isClubMemberOnline(p.name) and inLeg(p.name)
		then
			addCandidate(candidates, seen, p.name)
		end
	end
	for _, unitID in pairs(self.xfacContacts) do
		if Util.isClubMemberOnline(unitID) and inLeg(unitID) then
			addCandidate(candidates, seen, unitID)
		end
	end
	for i = 1, #roster do
		addCandidate(candidates, seen, roster[i])
	end

	local n = #candidates
	if n == 0 then
		return 0
	end
	self.commCursor = self.commCursor + 1
	local offset = ((self.commCursor - 1) % n) + 1
	local sent = 0
	for pass = 1, 2 do
		for i = 0, n - 1 do
			if sent >= limit then
				break
			end
			local key = candidates[((offset + i - 1) % n) + 1]
			if not sentKeys[key]
				and not self:relayIgnored(key, now)
				and not (pass == 1 and self:usageAt(key, now) >= C.COMM_USAGE_LIMIT)
			then
				sentKeys[key] = true
				comms:sendChunksAddon(chunks, "WHISPER", seen[key])
				if picks then
					picks[#picks + 1] = seen[key]
				end
				self:bumpUsage(key, now)
				sent = sent + 1
			end
		end
		if sent >= limit then
			break
		end
	end
	return sent
end

-- Reused empty candidate list: REQ whisper legs now reach proven targets
-- only (confirmed relays + xfac contacts). The unconfirmed roster is
-- covered by the probe rotation, so a fresh subject's fanout never
-- whispers strangers.
local EMPTY_ROSTER = {}

-- Fan a control chunk-list out across every request medium: the same-faction
-- channel, the group, every *confirmed* BNet peer, and the cross-faction
-- whisper relays (confirmed relays and proven contacts only).
-- Only ever called with single-chunk control messages — data never floods.
-- @return number Total legs sent.
function Broadcast:sendCtlFanout(chunks)
	local comms = ns.comms
	local leg = ns.statsLeg
	local sent = 0
	local now = GetTime()

	local idx = comms:channelIndex()
	if idx and comms:sendChunksAddon(chunks, "CHANNEL", idx) then
		sent = sent + 1
		if leg then
			leg("channel", 1)
		end
	end

	local groupKind = comms:groupChannel()
	if groupKind and comms:sendChunksAddon(chunks, groupKind) then
		sent = sent + 1
		if leg then
			leg("group", 1)
		end
	end

	-- Battle.net: confirmed FactionRP peers only — the whole point of the
	-- HELLO/HI handshake is never paying data/req sends to silent friends.
	local bnetPicks = self.lastLegPicks.bnet
	for i = #bnetPicks, 1, -1 do
		bnetPicks[i] = nil
	end
	for _, id in ipairs(comms:bnetAccounts()) do
		if comms:isBNetConfirmed(id, now) then
			comms:sendChunksBNet(chunks, id)
			bnetPicks[#bnetPicks + 1] = id
			sent = sent + 1
			if leg then
				leg("bnet", 1)
			end
		end
	end

	local sentKeys = self.fanoutSentKeys
	for key in pairs(sentKeys) do
		sentKeys[key] = nil
	end

	-- Pinned debug targets: guaranteed delivery, bypassing leg membership and
	-- the caps. "targets" debug category only (/frp debug targets).
	local sentPinned = 0
	local pinnedPicks = self.lastLegPicks.pinned
	for i = #pinnedPicks, 1, -1 do
		pinnedPicks[i] = nil
	end
	if ns.debugEnabled("targets") then
		for key, name in pairs(self.forcedTargets) do
			if not sentKeys[key] then
				sentKeys[key] = true
				comms:sendChunksAddon(chunks, "WHISPER", name)
				pinnedPicks[#pinnedPicks + 1] = name
				sentPinned = sentPinned + 1
			end
		end
	end

	local sentComm = self:_sendLeg(
		chunks, EMPTY_ROSTER, inCommunity, C.COMM_RELAY_LIMIT,
		nil, now, self.lastLegPicks.community
	)
	local sentGuild = 0
	if IsInGuild() then
		sentGuild = self:_sendLeg(
			chunks, EMPTY_ROSTER, inGuild, C.GUILD_RELAY_LIMIT,
			nil, now, self.lastLegPicks.guild
		)
	end
	sent = sent + sentComm + sentGuild + sentPinned
	if leg then
		if sentComm > 0 then
			leg("community", sentComm)
		end
		if sentGuild > 0 then
			leg("guild", sentGuild)
		end
		if sentPinned > 0 then
			leg("pinned", sentPinned)
		end
	end
	if sent > 0 and ns.debugFanout then
		ns.debugFanout(self.lastLegPicks.community, self.lastLegPicks.guild, self.lastLegPicks.pinned)
	end
	return sent
end

-- Control channel -----------------------------------------------------------

--- Own "Name-Realm", validated inside getUnitID each call.
local function ownUnitID()
	return Util.getUnitID("player") or ""
end

--- Build (and chunk) a control envelope: subject "_frp", data "FRP1 <verb>
-- <arg>". Called at request/probe time only — not a hot path.
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

--- Send a chunk-list to one peer, addressing by medium: BNet goes to the
-- gameAccountID; WHISPER and CHANNEL replies both ride a whisper to the
-- named sender. Used for control replies (ACK/OK/NOK/HI) and the granted
-- serve's data leg.
function Broadcast:sendToPeer(chunks, medium, target)
	if medium == "BNET" then
		return ns.comms:sendChunksBNet(chunks, target)
	end
	return ns.comms:sendChunksAddon(chunks, "WHISPER", target)
end

-- Version announcement (issue #19) -------------------------------------------

--- Our own addon version as declared by the installed build's .toc
--- ("## Version:"), read live from the client. The version broadcast and
--- the update-notice comparison use this instead of C.VERSION so the check
--- reflects what is actually installed, even when the hard-coded constant
--- lags behind; C.VERSION is only a last-resort guard for a missing
--- metadata field.
local function ownVersion()
	return C_AddOns.GetAddOnMetadata(C.ADDON_NAME, "Version") or C.VERSION
end

--- One-time broadcast of our addon version on the same-faction comm channel:
--- every FactionRP listener compares it against its own addon version and
--- tells its user when it is outdated. Retried while the channel join is
--- still pending; gives up after C.VER_BROADCAST_ATTEMPTS.
function Broadcast:broadcastVersion()
	local version = ownVersion()
	local comms = ns.comms

	-- Old-generation peers sit on their own channel and cannot hear ours;
	-- join the previous generation's just long enough to launch the
	-- announcement there too.
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
	if not idx or (prevChan and not prevIdx) then
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
		-- The chunk still sits in the paced send queue; keep the membership
		-- until it has had time to flush, then leave the channel again.
		C_Timer.After(C.VER_PREV_CHANNEL_HOLD, function()
			LeaveChannelByName(prevChan)
		end)
	end
end

-- Pull exchange --------------------------------------------------------------

--- Our BNet handshake probe + exchange expiry sweep, one ticker.
function Broadcast:tick()
	local now = GetTime()
	local comms = ns.comms

	-- Probe the next unconfirmed, non-ignored online BNet account. Probes are
	-- initiated traffic like REQ fanouts and share their in-flight budget:
	-- none go out while the queue already holds the cap.
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

	-- Whisper relay probing in bursts: up to RELAY_PROBE_BURST candidates per
	-- RELAY_PROBE_INTERVAL. The rotation only returns unconfirmed candidates
	-- with their one probe still unspent and spent-and-silent targets are
	-- kicked to the ignore list inside whisperProbeTarget itself. Each probe
	-- consumes an in-flight slot, so a saturated queue ends the burst early.
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

	-- Expire requests: open requests need an ACK inside REQ_ACK_TIMEOUT,
	-- granted ones need data inside REQ_DATA_TIMEOUT. Either way the subject
	-- goes on cooldown so repeated sightings cannot re-request constantly.
	for guid, req in pairs(self.requests) do
		local ttl = (req.state == "awaiting-data") and C.REQ_DATA_TIMEOUT
			or C.REQ_ACK_TIMEOUT
		if (now - req.at) > ttl then
			self.requests[guid] = nil
			self.recentReqs[guid] = now
			if ns.debugPeer then
				ns.debugPeer("req " .. guid .. " expired (" .. req.state .. ")")
			end
		end
	end

	-- Expire grants we were never asked to serve.
	for key, serve in pairs(self.pendingServes) do
		if (now - serve.at) > C.SERVE_TIMEOUT then
			self.pendingServes[key] = nil
		end
	end

end

--- Request `guid`'s profile from the mesh (we just saw an opposite-faction
-- player). No-op when the cache already holds a fresh copy, a request is
-- pending, the subject is still on cooldown, or it already waits in the
-- pacing backlog. A subject arriving while a fanout went out less than
-- REQ_ISSUE_INTERVAL ago is deferred rather than spraying a second fanout.
function Broadcast:requestProfile(guid, unitID)
	if not guid then
		return
	end
	local now = GetTime()
	if ns.cache:fresh(guid) then
		return
	end
	if self.requests[guid] or self.reqBacklog[guid] then
		return -- already pending, or already waiting its fanout turn
	end
	local last = self.recentReqs[guid]
	if last and (now - last) < C.REQ_COOLDOWN then
		return
	end
	local inflight = self:fanoutsInFlight()
	if (now - self.lastFanoutAt) < C.REQ_ISSUE_INTERVAL
		or inflight >= C.FANOUT_INFLIGHT_MAX
	then
		-- Bounded FIFO, the oldest waits are the least useful on overflow.
		local o = self.reqBacklogOrder
		while (o.tail - o.head + 1) >= C.REQ_BACKLOG_CAP do
			local old = o[o.head]
			o[o.head] = nil
			o.head = o.head + 1
			self.reqBacklog[old.guid] = nil
		end
		o.tail = o.tail + 1
		o[o.tail] = { guid = guid, unitID = unitID }
		self.reqBacklog[guid] = true
		if ns.debugPeer then
			ns.debugPeer("req " .. guid .. " deferred (fanout pacing, "
				.. inflight .. " in flight)")
		end
		return
	end
	self:issueRequest(guid, unitID, now)
end

--- Fanouts whose chunks have not fully left the send queue. A fanout's
--- chunks enqueue contiguously, so the queue tail position recorded at
--- issue is "in flight" while the queue head has not passed it. Markers
--- are pruned in place; an empty queue clears all markers outright.
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

--- Release one deferred subject once REQ_ISSUE_INTERVAL has elapsed since
--- the last fanout and fewer than FANOUT_INFLIGHT_MAX initiated sends still
--- occupy the send queue.
function Broadcast:drainRequests()
	local o = self.reqBacklogOrder
	if o.head > o.tail then
		return
	end
	local now = GetTime()
	if (now - self.lastFanoutAt) < C.REQ_ISSUE_INTERVAL
		or self:fanoutsInFlight() >= C.FANOUT_INFLIGHT_MAX
	then
		return
	end
	while o.head <= o.tail do
		local entry = o[o.head]
		o[o.head] = nil
		o.head = o.head + 1
		self.reqBacklog[entry.guid] = nil
		local last = self.recentReqs[entry.guid]
		if not self.requests[entry.guid]
			and not ns.cache:fresh(entry.guid)
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

--- Issue the actual REQ fanout for `guid`.
function Broadcast:issueRequest(guid, unitID, now)
	-- Bound outstanding requests; the oldest pending is the least useful.
	local n = 0
	local oldest, oldestAt
	for g, req in pairs(self.requests) do
		n = n + 1
		if not oldestAt or req.at < oldestAt then
			oldest, oldestAt = g, req.at
		end
	end
	if n >= C.REQ_MAX_PENDING and oldest then
		self.requests[oldest] = nil
	end

	-- Carry the subject's unitID on the wire when known, plus our held
	-- freshness (as-of stamp, profileID, content-version hash) so stale
	-- holders can suppress their own ACK.
	local arg = guid
	if unitID then
		local wire = Util.fullUnitName(unitID)
		if wire then
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
			arg = string.format("%s %s %d %s %s", guid, wire, floor, pid, cvh)
		end
	end

	local sent = self:sendCtlFanout(self:buildCtl("REQ", arg))
	if sent > 0 then
		self.fanoutInFlight[#self.fanoutInFlight + 1] = ns.comms.queue.tail
	end
	self.requests[guid] = { state = "open", at = now, unitID = unitID }
	self.recentReqs[guid] = now
	self.lastFanoutAt = now
	if ns.statsLeg then
		ns.statsLeg("req", 1)
	end
	if ns.debugPeer then
		ns.debugPeer("req " .. guid .. " -> " .. sent .. " legs")
	end
end

--- The freshness claim we can honestly make for a subject: our persisted
-- record's as-of stamp, or the register's last-seen stamp when it holds
-- different content (a register copy differing from our record arrived after
-- it, so its bind stamp is an honest receipt time; an identical copy may
-- carry a stamp our own injection re-dated). A holder never claims fresher
-- than its own last contact, so re-serving an old copy cannot masquerade as
-- new. Self is authoritative.
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
		-- We do not know the original authoring time; we claim the copy's own
		-- freshness instead of now, so stale held data stays stale on the wire.
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

--- Resolve a request subject's guid to a unitID by consensus: gather every
-- identity claim we hold for the guid — the cache's guid->unitID map, the
-- client's player-info cache, the club roster, and the requester-asserted
-- wire unitID. All non-nil claims must agree; any disagreement is a silent
-- miss, and an empty claim set misses the same way an unresolvable guid always has.
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

--- True while the serve breaker is engaged. Resets the fixed window on
-- expiry (a fresh window also starts when the mute ends, since the mute
-- outlasts the window), so post-mute counting restarts clean.
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

--- Count a granted serve (our ACK was OK'd and real work committed). On
-- hitting the window limit, mute for SERVE_RATE_MUTE and realign the
-- window so counting restarts after unmute. Grants arriving while already
-- muted were committed before the breaker engaged: their serve completes,
-- but they neither count nor extend the mute.
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
		ns.debugPeer("serve throttled — " .. C.SERVE_RATE_LIMIT .. " serves/" .. C.SERVE_RATE_WINDOW .. "s reached")
	end
end

--- Address key shared by pendingServes entries and OK/NOK lookups. Peers are
-- identified by account/name only — NOT medium: a REQ may arrive over the
-- channel while its OK arrives by whisper, and both must resolve the same key.
local function serveKey(context, guid)
	local peer = context.gameAccountID or context.senderName or "?"
	return peer .. ":" .. guid
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
			-- Club-relay handshake: a whispered HELLO gets a HI, rate-limited
			-- per sender so probe storms cannot turn into HI spam. The
			-- inbound stamp already confirmed them as a relay.
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
			-- The inbound stamp already confirmed them; just record the
			-- advertised version.
			local key = Util.normalizeUnitName(context.senderName)
			local p = key and self.relays[key]
			if p then
				p.version = arg
			end
		end
	elseif verb == "REQ" then
		-- "Who can serve subject `arg`?" Ourselves answer directly; anyone
		-- else needs identity consensus across every claim we hold for the
		-- guid — including the requester-asserted unitID (`arg2`). The
		-- servability check below reads the RP AddOn's register live, so a
		-- subject absent from our cache is still servable whenever the
		-- register holds their profile.
		local selfReq = (arg == self:senderGUID())
		local unitID
		if selfReq then
			unitID = ownUnitID()
		else
			unitID = self:resolveSubject(arg, arg2)
		end
		local adapter = ns.getAvailableAdapter()
		-- The serve breaker never applies to requests for our own profile —
		-- we are the authoritative server for ourselves.
		if not selfReq and self:serveThrottled(now) then
			return
		end
		if unitID and adapter and adapter.canServe and adapter:canServe(unitID) then
			-- The requester advertises what it already holds (as-of stamp,
			-- profileID, content-version hash). Suppress our ACK when our copy
			-- is no newer than their claim and of the same lineage or content:
			-- serving it would only cost both ends a wasted data leg.
			local offerAt = self:claimAt(arg, unitID, adapter.name)
			local reqAt = tonumber(arg3) or 0
			if not selfReq and offerAt <= reqAt + C.FRESHNESS_SKEW then
				local meta = adapter.profileMeta and adapter:profileMeta(unitID)
				if meta and ((arg4 ~= "" and meta.pid == arg4)
					or (arg5 ~= "" and meta.cv
						and Util.hashStr(meta.cv) == arg5))
				then
					if peer then
						peer("ack " .. arg .. " -> " .. tostring(target)
							.. " skipped (stale copy)")
					end
					return
				end
			end
			-- Bound granted-or-awaiting serves: over the cap we simply do not
			-- ACK (same as a miss — the requester still times out cleanly).
			local pending = 0
			for _ in pairs(self.pendingServes) do
				pending = pending + 1
			end
			if pending >= C.SERVE_PENDING_CAP then
				return
			end
			if self:sendToPeer(
				self:buildCtl("ACK", arg .. " " .. offerAt),
				context.medium, target
			) then
				local key = serveKey(context, arg)
				self.pendingServes[key] = {
					subject = arg, unitID = unitID,
					medium = context.medium, target = target, at = now,
				}
				if leg then
					leg("ack", 1)
				end
				if peer then
					peer("ack " .. arg .. " -> " .. tostring(target))
				end
			end
		end
		-- Misses stay silent: a reply per non-holder costs more than the
		-- requester's timeout. Discovery/confirmation rides the whisper
		-- HELLO/HI probes instead.
	elseif verb == "ACK" then
		-- ACK carries the holder's claimed freshness (arg2). A claim at or
		-- below our persisted floor cannot contain anything newer; denying it
		-- keeps a fast-but-stale holder from winning the grant.
		local req = self.requests[arg]
		local ackAt = tonumber(arg2) or 0
		local stale = req ~= nil
			and ackAt + C.FRESHNESS_SKEW
				< ns.cache:freshnessFloor(arg, req.unitID)
		local won = req
			and not stale
			and req.state == "open"
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
		local key = serveKey(context, arg)
		local serve = self.pendingServes[key]
		if serve then
			self.pendingServes[key] = nil
			-- Granted serves are what the breaker meters — a NOK'd ACK
			-- never cost real work. Self-serves don't count (breaker-bypassed).
			if serve.subject ~= self:senderGUID() then
				self:bumpServe(now)
			end
			self:serveData(serve)
		end
	elseif verb == "NOK" then
		self.pendingServes[serveKey(context, arg)] = nil
	elseif verb == "VER" then
		-- Issue #19: a same-faction peer announcing its addon version on
		-- login. When it is newer than ours, print a one-shot update notice,
		-- deduped by the highest version we have already been told this
		-- session so a wave of older peers logging in cannot spam the chat.
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

--- Publish a freshly-extracted profile into our cache so we can serve it when
-- a peer asks. Under the pull model this sends nothing on the wire.
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
	-- Reject malformed messages, including a non-numeric origin-time which would
	-- otherwise break the Cache's ordering comparison.
	if not msg or type(msg.originTime) ~= "number" then
		if ns.statsError then
			ns.statsError("malformed")
		end
		ns.comms:blockSender(context.senderKey)
		return
	end

	-- Hard protocol gate, before ANY peer-state side effects: envelopes
	-- advertising an older protocol generation (incl. field-count-mismatched
	-- parses) are rejected outright — they cannot confirm a relay, serve a
	-- request, or feed the cache. Sneaks on modified old clients would have
	-- to speak the new wire format, at which point they are the protocol.
	if not msg.protoVer or msg.protoVer < C.PROTO_MAJOR then
		if ns.statsError then
			ns.statsError("proto_old")
		end
		ns.comms:blockSender(context.senderKey)
		return
	end

	-- Loop avoidance: ignore our own traffic echoed back to us.
	if msg.sender == self:senderGUID() then
		if ns.statsError then
			ns.statsError("self_echo")
		end
		return
	end
	-- A parseable inbound whisper from an opposite-faction club member proves
	-- they run the AddOn: a confirmed relay. Runs before the control dispatch
	-- so ctl traffic (ACK/OK/NOK/HELLO/HI) confirms senders too.
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
	-- Any parseable message over BNet proves the account runs the AddOn.
	if context.medium == "BNET" and context.gameAccountID then
		ns.comms:bnetPeerSeen(context.gameAccountID)
	end
	-- Control messages (subject "_frp") never reach the cache/register and
	-- are never re-sent.
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

	-- A data message for a subject we requested completes the exchange. If it
	-- came from someone other than our grant winner, NOK the winner so it
	-- stops (best-effort; it may already be mid-send).
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
	end

	local candidate = {
		guid = msg.subject,
		unitID = msg.unitID,
		addon = msg.addon,
		originTime = msg.originTime,
		contentVersion = msg.contentVersion,
	}

	-- Cheap path first: duplicates and stale copies resolve without the
	-- payload, so the (expensive) decode only runs for NEW/UPDATED content.
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

	-- Populate the RP AddOn's register as profiles land so its directory fills
	-- (queued: register writes are expensive, bursty). Data is never relayed:
	-- under the pull model peers fetch what they need via REQ.
	self:queueInject(candidate)
end

-- Injection into the RP AddOn ------------------------------------------------

--- Number of profiles queued for injection.
function Broadcast:injectDepth()
	local o = self.injectOrder
	return o.tail - o.head + 1
end

--- Queue a stored profile for injection into its source AddOn's register.
-- Dedup'd by GUID: a newer copy replaces any older pending one.
function Broadcast:queueInject(candidate)
	-- Our own profile is already authoritative locally; never inject it back.
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

--- Pin a whisper target for testing: always sent on every fanout, bypassing
--- leg membership and caps. Returns the normalized "Name-Realm" or nil.
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

--- Record an opposite-faction club member whose profile reached us over the
--- RP AddOn's own comm channels. They are proven reachable by cross-faction
--- whisper and almost certainly run an RP AddOn, so they are preferred relay
--- targets for the community leg (see sendCtlFanout).
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
