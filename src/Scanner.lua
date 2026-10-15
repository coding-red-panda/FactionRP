-- Scanner.lua
--
-- Watches for player "selection" (mouseover / target). Same-faction and own
-- profiles are extracted and *published to the local cache* (Broadcast:publish
-- — no wire traffic) so we can serve them when a peer asks. Selecting an
-- opposite-faction unit is the pull trigger: requestProfile asks the mesh
-- for that subject.
--
-- Because the RP AddOn fetches a freshly-seen same-faction profile
-- asynchronously, we also listen for the adapter's "profile updated" signal and
-- re-publish when the data actually lands.
--
-- GUARD: every profile we *inject* (Tooltip module) also lands in the adapter's
-- register and therefore fires the same "profile updated" signal. Under the
-- pull model a re-publish only reaches the cache — but without a break in the
-- loop, one served profile becomes: inject -> REGISTER_DATA_UPDATED ->
-- re-extract -> re-publish, burning extraction work per injection and forcing
-- TRP3 to rebuild scan pins/tooltip groups from data whose profile bindings
-- change underneath it (observed as duplicated map-scan results, issue #1).
-- We therefore only re-publish for units the user actually selected
-- (mouseover/target), and only when the profile's content version differs from
-- what we last published (self-triggered writes are identical, so they
-- collapse to a no-op instead of cycling).

local _, ns = ...
local C = ns.Const

local Scanner = ns.Class("Scanner")
ns.Scanner = Scanner

function Scanner:init()
	-- Units the user has selected this session that we may publish for.
	-- [unitID] = guid. Only ever holds same-faction units; self is handled
	-- explicitly via the adapter's player unit id.
	self.selected = {}

	-- Profiles reported as received over the RP AddOn's own comm channels,
	-- queued for re-publication. receivedPending maps unitID -> pooled
	-- { adapter, readyAt } record; receivedQueue is the FIFO order, capped so
	-- a sustained receipt burst cannot queue unboundedly.
	self.receivedPending = {}
	self.receivedQueue = {}
	self.pendingAcquire, self.pendingRelease = ns.Util.newPool(C.RECEIVED_ORIGIN_QUEUE)

	-- Last content version we published per unit ID. Used to collapse
	-- update-event feedback (see header comment) to a no-op.
	-- [unitID] = contentVersion.
	self.lastSharedVersion = {}
end

function Scanner:start()
	-- React when an adapter reports a profile changed/arrived, or profile
	-- data was received over the AddOn's own comm channels.
	for _, adapter in pairs(ns.adapters) do
		adapter:registerUpdateListener(function(unitID)
			self:onAdapterUpdate(adapter, unitID)
		end)
		adapter:registerReceivedListener(function(unitID)
			self:onAdapterReceived(adapter, unitID)
		end)
	end

	ns.RegisterEvent("UPDATE_MOUSEOVER_UNIT", function()
		self:onSelect("mouseover")
	end)
	ns.RegisterEvent("PLAYER_TARGET_CHANGED", function()
		self:onSelect("target")
	end)

	-- Share our own profile as soon as possible (and again whenever we edit it,
	-- via onAdapterUpdate's self handling).
	self:shareSelf()

	-- Drain received-profile publishes at a bounded rate so a receipt burst
	-- cannot, on its own, produce an extraction storm.
	C_Timer.NewTicker(C.RECEIVED_ORIGIN_INTERVAL, function()
		self:drainReceived()
	end)
end

--- Publish the local player's own profile to the cache.
function Scanner:shareSelf()
	local adapter = ns.getAvailableAdapter()
	if not adapter then
		return
	end
	local unitID = adapter:getPlayerUnitID()
	local guid = UnitGUID("player")
	if ns.Util.canWeUse(unitID, guid) and unitID and guid then
		self:share(adapter, unitID, guid)
	end
end

--- Handle a mouseover/target change.
function Scanner:onSelect(unit)
	if not ns.Util.canWeUse(unit) then
		return
	end
	-- The token checks out, but the results themselves can still be secret.
	local isPlayer = UnitIsPlayer(unit)
	local isSelf = UnitIsUnit(unit, "player")
	if not ns.Util.canWeUse(isPlayer, isSelf) or not isPlayer or isSelf then
		return -- non-players and ourselves are handled elsewhere
	end
	-- Opposite-faction players have no authoritative local data: this is the
	-- pull-exchange trigger: ask the mesh for their profile (deduped and
	-- rate-limited inside requestProfile).
	if ns.Util.isOppositeFaction(unit) then
		local adapter = ns.getAvailableAdapter()
		local unitID = adapter and adapter:getUnitID(unit)
		local guid = UnitGUID(unit)
		if ns.Util.canWeUse(unitID, guid) and guid then
			ns.broadcast:requestProfile(guid, unitID)
		end
		return
	end
	local adapter = ns.getAvailableAdapter()
	if not adapter then
		return
	end
	local unitID = adapter:getUnitID(unit)
	local guid = UnitGUID(unit)
	if not ns.Util.canWeUse(unitID, guid) or not unitID or not guid then
		return
	end
	self.selected[unitID] = guid
	self:share(adapter, unitID, guid)
end

--- Handle an asynchronous profile update from an adapter.
-- NOTE: this fires for ALL register writes, including our own injections (see
-- header). Only re-publish for units the user actually selected this session,
-- and skip when the content version is unchanged since our last publish,
-- otherwise our own injection writes would churn the cache for nothing.
function Scanner:onAdapterUpdate(adapter, unitID)
	local guid
	local playerUnitID = adapter:getPlayerUnitID()
	if not ns.Util.canWeUse(unitID, playerUnitID) then
		return
	end
	if unitID == playerUnitID then
		guid = UnitGUID("player") -- our own profile changed
	else
		guid = self.selected[unitID] -- only previously-selected units
	end
	if ns.Util.canWeUse(guid) and guid then
		self:share(adapter, unitID, guid)
	end
end

--- Handle an adapter's "profile data received over the network" signal.
-- Receipts fire per section while data is still landing, so rather than
-- extracting immediately we queue the unit with a jittered ready time: this
-- collapses the burst into a single extraction+publish, and the jitter keeps
-- several simultaneous receipts from all landing on the same tick.
function Scanner:onAdapterReceived(adapter, unitID)
	local playerUnitID = adapter:getPlayerUnitID()
	if not ns.Util.canWeUse(unitID, playerUnitID)
		or not unitID or unitID == playerUnitID then
		return -- never re-publish our own profile
	end

	local readyAt = GetTime() + C.RECEIVED_DEBOUNCE + math.random() * C.RECEIVED_JITTER
	if self.receivedPending[unitID] then
		-- Re-arm on each section receipt.
		self.receivedPending[unitID].readyAt = readyAt
		return
	end

	local pending = self.pendingAcquire()
	pending.adapter = adapter
	pending.readyAt = readyAt
	self.receivedPending[unitID] = pending
	self.receivedQueue[#self.receivedQueue + 1] = unitID
	if ns.statsQueueDepth then
		ns.statsQueueDepth("received", #self.receivedQueue)
	end
	if ns.debugReceived then
		ns.debugReceived(unitID)
	end

	-- A profile received for an opposite-faction member of one of our clubs
	-- proves the subject is reachable by cross-faction whisper: record them
	-- as a preferred community relay target.
	if ns.Util.isXfacClubMember(unitID) then
		ns.broadcast:noteXfacContact(unitID)
	end

	-- Bound the queue; the oldest pending receipts are the least valuable.
	while #self.receivedQueue > C.RECEIVED_ORIGIN_QUEUE do
		local dropped = table.remove(self.receivedQueue, 1)
		local p = self.receivedPending[dropped]
		self.receivedPending[dropped] = nil
		if p then
			self.pendingRelease(p)
		end
		if ns.statsError then
			ns.statsError("received_queue_drop")
		end
		if ns.debugSkip then
			ns.debugSkip(dropped, "received queue full")
		end
	end
end

--- Fire at most one ready received-profile publish per tick.
function Scanner:drainReceived()
	local now = GetTime()
	local i = 1
	while i <= #self.receivedQueue do
		local unitID = self.receivedQueue[i]
		local pending = self.receivedPending[unitID]
		if not pending then
			-- Stale queue entry (shouldn't happen); drop it.
			table.remove(self.receivedQueue, i)
		elseif pending.readyAt <= now then
			table.remove(self.receivedQueue, i)
			self.receivedPending[unitID] = nil

			local adapter = pending.adapter
			self.pendingRelease(pending)
			local guid = adapter and adapter:isAvailable() and ns.Util.resolveGUID(unitID)
			if guid then
				self:share(adapter, unitID, guid)
			else
				if ns.statsError then
					ns.statsError("guid_unresolved")
				end
				if ns.debugSkip then
					ns.debugSkip(unitID, "could not resolve GUID")
				end
			end
			return -- at most one per tick
		else
			i = i + 1
		end
	end
end

--- Extract the profile and hand it to Broadcast:publish (which de-dups).
-- The cache is content-version-aware, so unchanged content collapses to
-- REFRESHED; that alone does not fully close the loop, though: repeated
-- REFRESHED results keep the cache entry alive forever (TTL extension) and
-- cost an extraction each tick, so we also stop publishing early when the
-- version matches what we last published.
function Scanner:share(adapter, unitID, guid)
	local profile = adapter:extract(unitID)
	if not profile then
		return
	end
	if self.lastSharedVersion[unitID] == profile.contentVersion then
		return -- nothing new since our last publish (e.g. our own injection)
	end
	self.lastSharedVersion[unitID] = profile.contentVersion
	ns.broadcast:publish(guid, unitID, profile)
end

-- Singleton.
ns.scanner = Scanner:new()
ns.OnLogin(function()
	ns.scanner:start()
end)
