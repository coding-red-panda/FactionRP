-- ProfileAdapter.lua
--
-- The abstraction that decouples FactionRP from any specific RP AddOn. Each
-- supported RP AddOn (TRP3 first; MRP/XRP could follow) provides a concrete
-- subclass implementing this contract. The rest of FactionRP only ever talks
-- to the abstract interface and the adapter registry below.
--
-- The "profile" object an adapter produces and consumes has this shape:
--   {
--     addon          = "TRP3",          -- which adapter owns it (ns.Const.SOURCE)
--     contentVersion = "5:3:1",          -- opaque content identifier (equality only)
--     data           = <opaque table>,   -- adapter-private payload (e.g. profileID + sections)
--   }
-- `data` is deliberately opaque to the generic layers: only the owning adapter
-- knows how to read it, so the wire/cache stay AddOn-agnostic.

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
-- Only meaningful for units the AddOn has authoritative data for (same faction
-- or the player). Returns nil when no data is (yet) available.
-- @param unitID string "Name-Realm".
-- @return table|nil A profile object (see file header), or nil.
function ProfileAdapter:extract(unitID) -- luacheck: ignore
	error("ProfileAdapter:extract must be implemented by a subclass")
end

--- Inject a received profile into the RP AddOn so it can display it (e.g. in
-- its tooltip). Idempotent and version-aware where the AddOn supports it.
-- @param unitID  string  "Name-Realm".
-- @param data    table   The adapter-private `data` payload from a profile object.
-- @param classID number? Optional class id of the present unit, for display.
-- @return boolean Whether the profile was injected.
function ProfileAdapter:inject(unitID, data, classID) -- luacheck: ignore
	error("ProfileAdapter:inject must be implemented by a subclass")
end

--- Subscribe to "this unit's profile changed/arrived" notifications from the
-- underlying AddOn, so the Scanner can react when async data lands. Optional;
-- the default is a no-op for AddOns without such a signal.
-- @param callback function Invoked as callback(unitID).
function ProfileAdapter:registerUpdateListener(callback) -- luacheck: ignore
	-- no-op by default
end

-- Adapter registry ----------------------------------------------------------
--
-- Adapters register themselves at load. Consumers look one up by source name
-- (to inject data that arrived tagged with that source) or ask for the first
-- available adapter (to extract local data).

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
