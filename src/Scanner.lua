-- Scanner.lua
--
-- Watches player selection (mouseover/target). Same-faction selections are
-- extracted and published to the local cache; an xfac selection is the pull
-- trigger. Also re-publishes when the adapter reports received data.
--
-- GUARD: injected profiles fire the same update signal (issue #1), so we
-- only re-publish user-selected units whose content version changed.

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

	-- Pending delayed xfac mouseover REQ, or nil.
	self.hoverTimer = nil
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
	if ns.Util.isPaused() then
		return
	end

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
	if ns.Util.commsRestricted() then
		if unit == "mouseover" then
			self:cancelHover()
		end
		return -- no unit reads at all under lockdown
	end
	if not ns.Util.canWeUse(unit) then
		return
	end
	if unit == "mouseover" and self:updateHover() then
		return
	end
	-- The token checks out, but the results themselves could still be secret if
	-- something happened just after we got the token.
	local isPlayer = UnitIsPlayer(unit)
	local isSelf = UnitIsUnit(unit, "player")
	if not ns.Util.canWeUse(isPlayer, isSelf) or not isPlayer or isSelf then
		return -- non-players and ourselves are handled elsewhere
	end
	-- Opposite-faction selection is the pull trigger; requestProfile
	-- dedupes and rate-limits. Mouseover delays so a passing cursor
	-- costs nothing.
	if ns.Util.isOppositeFaction(unit) then
		local adapter = ns.getAvailableAdapter()
		local unitID = adapter and adapter:getUnitID(unit)
		local guid = UnitGUID(unit)
		if ns.Util.canWeUse(unitID, guid) and guid then
			if unit == "mouseover" then
				self:hoverRequest(guid, unitID)
			else
				self:xfacRequest(guid, unitID)
			end
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

--- Pull an xfac profile now. Shared-club subjects are whisper-reachable
-- and TRP3 already sends its own vernum query on selection, so we skip
-- our pull for them.
function Scanner:xfacRequest(guid, unitID)
	if ns.Util.commsRestricted() then
		return
	end

	local adapter = ns.getAvailableAdapter()
	if adapter and adapter.name == C.SOURCE.TRP3
		and (ns.Util.isCommunityClubMember(unitID)
			or ns.Util.isGuildClubMember(unitID))
	then
		if ns.debugPeer then
			ns.debugPeer("req " .. (unitID or tostring(guid))
				.. " skipped (shared club, native pull)")
		end
		return
	end
	ns.broadcast:requestProfile(guid, unitID)
end

--- REQ an xfac mouseover after actual hover time
--//edit: tiny interruptions pauses the countdown for the same player
function Scanner:hoverRequest(guid, unitID)
	if self.hoverTimer and self.hoverGuid == guid then
		return
	end

	local now = GetTime()
	local previous = self.hoverPrevious
	if previous and now - previous.lostAt >= C.MOUSEOVER_GRACE_PERIOD then
		previous = nil
	end

	local elapsed = 0
	if previous and previous.guid == guid then
		elapsed = previous.elapsed
		previous = nil
	end

-- //edit: keeping the players progress when someone tries screwing you by running through your cursor
	if not previous and self.hoverTimer and self.hoverLostAt
		and now - self.hoverLostAt < C.MOUSEOVER_GRACE_PERIOD then
		previous = {
			guid = self.hoverGuid,
			elapsed = self.hoverElapsed,
			lostAt = self.hoverLostAt,
		}
	end

	self:cancelHover()
	self.hoverGuid = guid
	self.hoverUnitID = unitID
	self.hoverAt = now
	self.hoverElapsed = elapsed
	self.hoverPrevious = previous

-- //edit: mouseover can break without an event so checking while we wait
	local timer
	timer = C_Timer.NewTicker(C.MOUSEOVER_CHECK_INTERVAL, function()
		if self.hoverTimer == timer then
			self:updateHover()
		end
	end)
	self.hoverTimer = timer
	if not self.hoverTimer then
		error("FactionRP: C_Timer.NewTicker returned no handle in Scanner:hoverRequest")
	end
end

---//edit: updating a pending hover and returning true if request was triggered
function Scanner:updateHover()
	if not self.hoverTimer then
		return
	end
	if ns.Util.commsRestricted() then
		self:cancelHover()
		return
	end

	local now = GetTime()
	if self.hoverPrevious and now - self.hoverPrevious.lostAt >= C.MOUSEOVER_GRACE_PERIOD then
		self.hoverPrevious = nil
	end

	local cur = UnitGUID("mouseover")
	if not ns.Util.canWeUse(cur) or cur ~= self.hoverGuid then
		if not self.hoverLostAt then
			self.hoverElapsed = self.hoverElapsed + now - self.hoverAt
			self.hoverLostAt = now
			self.hoverAt = nil
		end
		if now - self.hoverLostAt >= C.MOUSEOVER_GRACE_PERIOD then
			self:cancelHover()
		end
		return
	end

	if self.hoverLostAt then
		if now - self.hoverLostAt >= C.MOUSEOVER_GRACE_PERIOD then
			self:cancelHover()
			return
		end

-- //edit: Keeping the time we already hovered without the interuption time
		self.hoverAt = now
		self.hoverLostAt = nil
	end

	if self.hoverElapsed + now - self.hoverAt >= C.MOUSEOVER_REQ_DELAY then
		local guid, unitID = self.hoverGuid, self.hoverUnitID
		self:cancelHover()
		self:xfacRequest(guid, unitID)
		return true
	end
end

--- Cancel a pending hover REQ, if any.
function Scanner:cancelHover()
	if self.hoverTimer then
		self.hoverTimer:Cancel()
		self.hoverTimer = nil
	end
	self.hoverGuid = nil
	self.hoverUnitID = nil
	self.hoverAt = nil
	self.hoverElapsed = nil
	self.hoverLostAt = nil
	self.hoverPrevious = nil
end

function Scanner:pauseForActivity()
	self:cancelHover()
	for unitID, pending in pairs(self.receivedPending) do
		self.pendingRelease(pending)
		self.receivedPending[unitID] = nil
	end
	wipe(self.receivedQueue)
end

--- Fraction (0..1) of MOUSEOVER_REQ_DELAY elapsed while hovering `guid`,
-- or nil when no hover REQ is pending for them. Drives the tooltip
-- indicator's countdown fill.
function Scanner:hoverProgress(guid)
	if guid and self.hoverTimer and self.hoverGuid == guid then
		local now = GetTime()
		if self.hoverLostAt and now - self.hoverLostAt >= C.MOUSEOVER_GRACE_PERIOD then
			return
		end
		local elapsed = self.hoverElapsed + (self.hoverAt and now - self.hoverAt or 0)
		return math.min(elapsed / C.MOUSEOVER_REQ_DELAY, 1)
	end
end

--- Handle an asynchronous profile update from an adapter.
-- Fires for ALL register writes including our own injections, so only
-- re-publish user-selected units; an unchanged content version collapses
-- the feedback to a no-op.
function Scanner:onAdapterUpdate(adapter, unitID)
	if ns.Util.isPaused() then
		return
	end
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

--- Handle an adapter's "profile data received" signal. Receipts fire per
-- section, so we queue a jittered ready time that collapses the burst into
-- one extraction and keeps simultaneous receipts off the same tick.
function Scanner:onAdapterReceived(adapter, unitID)
	if ns.Util.isPaused() then
		return
	end

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

	-- A received xfac club profile proves whisper reachability; record it.
	if ns.Util.isXfacClubMember(unitID) then
		ns.broadcast:noteXfacContact(unitID)
	end

	-- Bound the queue; oldest pending receipts are least valuable.
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
	if ns.Util.isPaused() then
		return

	end
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
-- Repeated publishes would only extend the TTL at an extraction per tick,
-- so we also stop early when the version matches our last publish.
function Scanner:share(adapter, unitID, guid)
	if ns.Util.isPaused() then
		return
	end

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
