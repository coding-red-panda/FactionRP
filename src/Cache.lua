-- Cache.lua
--
-- The profile cache: a GUID-keyed store of observed/received profiles with
-- a TTL and the version logic driving de-duplication.
--
-- Each entry is a plain table:
--   {
--     guid           = "Player-1234-...",   -- cache key (subject's GUID)
--     unitID         = "Name-Realm",         -- needed to inject/display later
--     addon          = "TRP3",               -- source RP AddOn (ns.Const.SOURCE)
--     originTime     = 1718200000,           -- server time() at original extraction
--     contentVersion = "c5:k3:m1",           -- opaque content identifier
--     data           = <table>,              -- the profile payload
--     added          = <GetTime()>,          -- local clock, drives TTL/expiry
--   }
--
-- Two clocks: originTime uses time() so copies compare across clients;
-- added uses GetTime() purely for local expiry.
--
-- FactionRPDB.seen[guid] = { at, unitID, pid, cv, addon } persists the
-- highest accepted "as of" claim per subject, so a stale copy cannot be
-- stored again after a relog. Records are swept against the register.

local _, ns = ...
local C = ns.Const

local Cache = ns.Class("Cache")
ns.Cache = Cache

-- Result codes returned by :tryStore, describing what happened. Only NEW and
-- UPDATED represent a meaningful change worth injecting into the register.
Cache.RESULT = {
	NEW = "new", -- first time we have seen this subject
	UPDATED = "updated", -- content changed and the copy is not stale
	REFRESHED = "refreshed", -- identical content; TTL extended only
	REJECTED = "rejected", -- older/stale copy; ignored entirely
}

--- Constructor: initialise the store and start the expiry sweep.
function Cache:init()
	self.entries = {} -- [guid] = entry
	-- Drop expired entries periodically so memory stays bounded.
	self.ticker = C_Timer.NewTicker(C.CACHE_SWEEP_INTERVAL, function()
		self:sweep()
	end)
end

--- Whether an entry has outlived the TTL relative to `now` (a GetTime value).
local function isExpired(entry, now)
	return (now - entry.added) > C.CACHE_TTL
end

--- The freshness floor for a subject: the persisted record's as-of claim,
-- else the register's last-seen stamp. The record wins because TRP3
-- re-stamps profile.time on every bind, including our own injections.
-- @return number Epoch seconds; 0 when nothing is known.
function Cache:freshnessFloor(guid, unitID, addonName)
	local rec = ns.db and ns.db.seen and ns.db.seen[guid]
	if rec and rec.at and rec.at > 0 then
		return rec.at
	end
	local adapter = (addonName and ns.getAdapter(addonName))
		or ns.getAvailableAdapter()
	local meta = adapter and unitID and adapter:profileMeta(unitID)
	return (meta and meta.at) or 0
end

--- Advance the persisted freshness record for a subject. Called on NEW,
-- UPDATED and REFRESHED results; never on rejects.
function Cache:noteSeen(candidate)
	local db = ns.db
	if not db or not candidate.guid then
		return
	end
	db.seen = db.seen or {}
	local rec = db.seen[candidate.guid]
	if not rec then
		rec = { at = 0 }
		db.seen[candidate.guid] = rec
	end
	-- Clamp to now+skew: a claim cannot legitimately come from the future.
	local at = math.min(candidate.originTime or 0, time() + C.FRESHNESS_SKEW)
	if at > rec.at then
		rec.at = at
	end
	if candidate.unitID and candidate.unitID ~= "" then
		rec.unitID = candidate.unitID
	end
	rec.cv = candidate.contentVersion or rec.cv
	rec.addon = candidate.addon or rec.addon
	-- Every accepted sighting re-arms local request suppression while the
	-- register still holds the profile (Broadcast:heldSuppressed).
	rec.holdUntil = time() + C.REQ_HELD_TTL
	local adapter = candidate.addon and ns.getAdapter(candidate.addon)
	local pid = adapter and candidate.data and adapter:dataProfileID(candidate.data)
	if pid then
		rec.pid = pid
	end
end

--- Attempt to store a candidate profile, applying the de-dup rules.
--
-- Rules (see doc/protocol.md):
--   * No existing entry            -> store (NEW), unless under the floor.
--   * Same CONTENT-VERSION         -> extend TTL only (REFRESHED).
--   * Incoming ORIGIN-TIME older   -> ignore (REJECTED); the persisted
--                                    floor applies the rule across sessions.
--   * Otherwise (changed & newer)  -> store (UPDATED).
--
-- @param candidate table An entry table WITHOUT `added` (we stamp it here).
-- @return string One of Cache.RESULT.*
function Cache:tryStore(candidate)
	local now = GetTime()

	-- Default profiles carry no user content; never store.
	local adapter = candidate.addon and ns.getAdapter(candidate.addon)
	if candidate.data and adapter and adapter.dataIsDefault
		and adapter:dataIsDefault(candidate.data)
	then
		return Cache.RESULT.REJECTED
	end

	local existing = self.entries[candidate.guid]

	-- Treat an expired existing entry as if it were absent.
	if existing and isExpired(existing, now) then
		existing = nil
	end

	local floor = self:freshnessFloor(
		candidate.guid, candidate.unitID, candidate.addon)

	local result
	if not existing then
		if candidate.originTime < floor - C.FRESHNESS_SKEW then
			return Cache.RESULT.REJECTED
		end
		result = Cache.RESULT.NEW
	elseif existing.contentVersion == candidate.contentVersion then
		-- Same content: just keep it alive, nothing to propagate.
		existing.added = now
		self:noteSeen(candidate)
		return Cache.RESULT.REFRESHED
	elseif candidate.originTime < existing.originTime
		or candidate.originTime < floor - C.FRESHNESS_SKEW
	then
		-- A staler copy; reject so it cannot flap the fresher one we hold.
		return Cache.RESULT.REJECTED
	else
		result = Cache.RESULT.UPDATED
	end

	candidate.added = now
	self.entries[candidate.guid] = candidate
	self:noteSeen(candidate)
	return result
end

--- Resolve the store decision for a candidate WITHOUT its `data` payload:
-- REFRESHED/REJECTED, or nil when the caller must decode data and call
-- :tryStore. Lets the receive path skip payload decoding for duplicates.
-- MUST stay in lockstep with :tryStore.
--
-- @param candidate table An entry table WITHOUT `data` or `added`.
-- @return string|nil Cache.RESULT.REFRESHED / Cache.RESULT.REJECTED, or nil.
function Cache:peek(candidate)
	local now = GetTime()
	local existing = self.entries[candidate.guid]
	if existing and isExpired(existing, now) then
		existing = nil
	end

	local floor = self:freshnessFloor(
		candidate.guid, candidate.unitID, candidate.addon)

	if not existing then
		if candidate.originTime < floor - C.FRESHNESS_SKEW then
			return Cache.RESULT.REJECTED
		end
		return nil -- NEW: needs data
	elseif existing.contentVersion == candidate.contentVersion then
		existing.added = now
		self:noteSeen(candidate)
		return Cache.RESULT.REFRESHED
	elseif candidate.originTime < existing.originTime
		or candidate.originTime < floor - C.FRESHNESS_SKEW
	then
		return Cache.RESULT.REJECTED
	end
	return nil -- UPDATED: needs data
end

--- Look up a live (non-expired) entry by GUID. Expired entries are removed
-- lazily on access and treated as absent.
-- @param guid string
-- @return table|nil The entry, or nil if missing/expired.
function Cache:get(guid)
	local entry = self.entries[guid]
	if not entry then
		return nil
	end
	if isExpired(entry, GetTime()) then
		self.entries[guid] = nil
		return nil
	end
	return entry
end

--- Whether a live (non-expired) entry exists for `guid`.
function Cache:fresh(guid)
	return self:get(guid) ~= nil
end

--- Drop every entry regardless of expiry. Testing aid (/frp purge).
-- @return number Entries dropped.
function Cache:clear()
	local n = 0
	for _ in pairs(self.entries) do
		n = n + 1
	end
	self.entries = {}
	return n
end

--- Drop freshness records whose unit the register no longer holds a profile
-- for, so they follow the user's purges. Records with no loaded adapter are
-- kept: no adapter is not proof of absence. A changed register profileID
-- means the subject switched profiles; the record re-anchors to its stamp.
function Cache:sweepSeen()
	if ns.Util.isPaused() then
		return
	end

	local seen = ns.db and ns.db.seen
	if not seen then
		return
	end
	for guid, rec in pairs(seen) do
		local adapter = (rec.addon and ns.getAdapter(rec.addon))
			or ns.getAvailableAdapter()
		if adapter and adapter:isAvailable() and rec.unitID
			and rec.unitID ~= adapter:getPlayerUnitID()
		then
			local meta = adapter:profileMeta(rec.unitID)
			if not meta then
				seen[guid] = nil
			elseif rec.pid ~= meta.pid then
				rec.pid = meta.pid
				rec.at = meta.at or rec.at
			end
		end
	end
end

--- Remove all expired entries. Invoked on a timer; safe to call manually.
function Cache:sweep()
	if ns.Util.isPaused() then
		return
	end

	local now = GetTime()
	for guid, entry in pairs(self.entries) do
		if isExpired(entry, now) then
			self.entries[guid] = nil
		end
	end
	self:sweepSeen()
end

--- Number of live (non-expired) entries currently held.
-- @return number
function Cache:count()
	local n = 0
	local now = GetTime()
	for _, entry in pairs(self.entries) do
		if not isExpired(entry, now) then
			n = n + 1
		end
	end
	return n
end

-- Singleton used by the rest of the AddOn.
ns.cache = Cache:new()
