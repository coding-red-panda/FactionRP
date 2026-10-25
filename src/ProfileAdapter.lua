-- ProfileAdapter.lua
--
-- The abstraction decoupling FactionRP from a specific RP AddOn; each
-- supported AddOn (TRP3 first) provides a subclass of this contract.
--
-- The "profile" object adapters produce and consume:
--   {
--     addon          = "TRP3",          -- which adapter owns it (ns.Const.SOURCE)
--     contentVersion = "5:3:1",          -- opaque content identifier (equality only)
--     data           = <opaque table>,   -- adapter-private payload (e.g. profileID + sections)
--   }
-- `data` is opaque to the generic layers; only the owning adapter reads it.

local _, ns = ...

local ProfileAdapter = ns.Class("ProfileAdapter")
ns.ProfileAdapter = ProfileAdapter

--- @param name string The source identifier (ns.Const.SOURCE.*).
function ProfileAdapter:init(name)
	self.name = name
end

--- Is the underlying RP AddOn present and exposing the APIs we rely on?
-- Subclasses MUST override. Returning false makes the adapter inert.
-- @return boolean
function ProfileAdapter:isAvailable()
	return false
end

--- Resolve a unit token to the "Name-Realm" id used as the profile key.
-- Subclasses should override to match their AddOn's exact key format.
-- @param unit string A unit token ("mouseover", "target", ...).
-- @return string|nil
function ProfileAdapter:getUnitID(unit)
	return ns.Util.getUnitID(unit)
end

--- The unit id the AddOn uses for the local player. Subclasses should override
-- if their internal id differs from getUnitID("player").
-- @return string|nil
function ProfileAdapter:getPlayerUnitID()
	return self:getUnitID("player")
end

--- Extract a profile for a known unit from the RP AddOn's own data store.
-- Returns nil when no data is (yet) available.
-- @param unitID string "Name-Realm".
-- @return table|nil A profile object (see file header), or nil.
function ProfileAdapter:extract(unitID) -- luacheck: ignore
	error("ProfileAdapter:extract must be implemented by a subclass")
end

--- Inject a received profile into the RP AddOn for display. Idempotent and
-- version-aware where the AddOn supports it.
-- @param unitID  string  "Name-Realm".
-- @param data    table   The adapter-private `data` payload from a profile object.
-- @param classID number? Optional class id of the present unit, for display.
-- @return boolean Whether the profile was injected.
function ProfileAdapter:inject(unitID, data, classID) -- luacheck: ignore
	error("ProfileAdapter:inject must be implemented by a subclass")
end

--- Freshness metadata for our held copy of a unit, read without copying
-- data. Used for REQ claims and freshness floors. Nil for self, unknown
-- units, and units with no bound profile.
-- @param unitID string "Name-Realm".
-- @return table|nil { at = last-seen epoch, pid = profileID, cv = contentVersion }
function ProfileAdapter:profileMeta(unitID) -- luacheck: ignore
	return nil
end

--- The profileID inside an adapter-private `data` payload, for bookkeeping
-- (freshness records). Returns nil when the payload does not carry one.
-- @param data table The adapter-private `data` payload.
-- @return string|nil
function ProfileAdapter:dataProfileID(data) -- luacheck: ignore
	return nil
end

--- True when the unit's bound profile is an auto-generated default rather
-- than user-authored content. Such profiles are never served or stored.
-- @param unitID string "Name-Realm".
-- @return boolean
function ProfileAdapter:isDefaultUnit(unitID) -- luacheck: ignore
	return false
end

--- Same check for a `data` payload, used on the ingest path.
-- @param data table The adapter-private `data` payload.
-- @return boolean
function ProfileAdapter:dataIsDefault(data) -- luacheck: ignore
	return false
end

--- Ask the RP AddOn to refresh our held copy from the author (best-effort,
-- asynchronous). Only called for units we can serve.
-- @param unitID string "Name-Realm".
-- @return boolean Whether a refresh was actually requested.
--- Whether the adapter could pull a profile for `unitID` it does not yet
-- serve (e.g. a known register entry with no bound profile).
function ProfileAdapter:canPull(unitID) -- luacheck: ignore
	return false
end

function ProfileAdapter:refreshQuery(unitID) -- luacheck: ignore
	return false
end

--- Subscribe to "this unit's profile changed/arrived" notifications.
-- Optional; default is a no-op.
-- @param callback function Invoked as callback(unitID).
function ProfileAdapter:registerUpdateListener(callback) -- luacheck: ignore
	-- no-op by default
end

--- Subscribe to "profile data arrived over the RP AddOn's own channels"
-- notifications so the Scanner can re-publish. MUST NOT fire for data
-- FactionRP itself injected (that would loop). Optional; default no-op.
-- @param callback function Invoked as callback(unitID).
function ProfileAdapter:registerReceivedListener(callback) -- luacheck: ignore
	-- no-op by default
end

-- Adapter registry ----------------------------------------------------------
-- Adapters register at load; consumers look up by source name or take the
-- first available one.

ns.adapters = {} -- [name] = adapter instance

--- Register an adapter instance. Last registration for a name wins.
function ns.registerAdapter(adapter)
	ns.adapters[adapter.name] = adapter
end

--- Look up a specific adapter by source name (ns.Const.SOURCE.*).
-- @return table|nil
function ns.getAdapter(name)
	return ns.adapters[name]
end

--- Return the first currently-available adapter, used for local extraction.
-- @return table|nil
function ns.getAvailableAdapter()
	for _, adapter in pairs(ns.adapters) do
		if adapter:isAvailable() then
			return adapter
		end
	end
	return nil
end
