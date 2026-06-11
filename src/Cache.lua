-- Cache.lua
--
-- The profile cache: a GUID-keyed store of profiles we have observed or
-- received, with a time-to-live and the version logic that drives gossip
-- de-duplication.
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
-- Two clocks are used deliberately:
--   * originTime uses time() (Unix/server epoch) so it is comparable ACROSS
--     clients for ordering which copy of a profile is newer.
--   * added uses GetTime() (a local monotonic clock) purely for local expiry.

local _, ns = ...
local C = ns.Const

local Cache = ns.Class("Cache")
ns.Cache = Cache

-- Result codes returned by :tryStore, describing what happened. Only NEW and
-- UPDATED represent a meaningful change that should be re-broadcast.
Cache.RESULT = {
	NEW = "new", -- first time we have seen this subject
	UPDATED = "updated", -- content changed and the copy is not stale
	REFRESHED = "refreshed", -- identical content; TTL extended only
	REJECTED = "rejected", -- older/stale copy; ignored entirely
}

--- Constructor: initialise the store and start the expiry sweep.
function Cache:init()
	self.entries = {} -- [guid] = entry
	-- Periodically drop expired entries so memory does not grow unbounded even
	-- if nobody looks the entries up.
	self.ticker = C_Timer.NewTicker(C.CACHE_SWEEP_INTERVAL, function()
		self:sweep()
	end)
end

--- Whether an entry has outlived the TTL relative to `now` (a GetTime value).
local function isExpired(entry, now)
	return (now - entry.added) > C.CACHE_TTL
end

--- Attempt to store a candidate profile, applying the gossip de-dup rules.
--
-- Rules (see README "Broadcast Flow"):
--   * No existing entry            -> store (NEW).
--   * Same CONTENT-VERSION         -> extend TTL only (REFRESHED), do not re-broadcast.
--   * Incoming ORIGIN-TIME older   -> ignore (REJECTED).
--   * Otherwise (changed & newer)  -> store (UPDATED).
--
-- @param candidate table An entry table WITHOUT `added` (we stamp it here).
-- @return string One of Cache.RESULT.*
function Cache:tryStore(candidate)
	local now = GetTime()
	local existing = self.entries[candidate.guid]

	-- Treat an expired existing entry as if it were absent.
	if existing and isExpired(existing, now) then
		existing = nil
	end

	local result
	if not existing then
		result = Cache.RESULT.NEW
	elseif existing.contentVersion == candidate.contentVersion then
		-- Same content: just keep it alive, nothing to propagate.
		existing.added = now
		return Cache.RESULT.REFRESHED
	elseif candidate.originTime < existing.originTime then
		-- A different but staler copy; reject so it cannot flap with the
		-- fresher copy we already hold.
		return Cache.RESULT.REJECTED
	else
		result = Cache.RESULT.UPDATED
	end

	candidate.added = now
	self.entries[candidate.guid] = candidate
	return result
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

--- Remove all expired entries. Invoked on a timer; safe to call manually.
function Cache:sweep()
	local now = GetTime()
	for guid, entry in pairs(self.entries) do
		if isExpired(entry, now) then
			self.entries[guid] = nil
		end
	end
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
