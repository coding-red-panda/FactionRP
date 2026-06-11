-- Scanner.lua
--
-- Watches for player "selection" (mouseover / target) and originates a
-- broadcast of the selected player's profile. We only originate for units the
-- RP AddOn has *authoritative* data for: the local player and same-faction
-- players. Opposite-faction units are display-only (see Tooltip).
--
-- Because the RP AddOn fetches a freshly-seen same-faction profile
-- asynchronously, we also listen for the adapter's "profile updated" signal and
-- originate when the data actually lands.

local _, ns = ...

local Scanner = ns.Class("Scanner")
ns.Scanner = Scanner

function Scanner:init()
	-- Units the user has selected this session that we may originate for.
	-- [unitID] = guid. Only ever holds same-faction units; self is handled
	-- explicitly via the adapter's player unit id.
	self.selected = {}
end

function Scanner:start()
	-- React when an adapter reports a profile changed/arrived.
	for _, adapter in pairs(ns.adapters) do
		adapter:registerUpdateListener(function(unitID)
			self:onAdapterUpdate(adapter, unitID)
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
end

--- Attempt to broadcast the local player's own profile.
function Scanner:shareSelf()
	local adapter = ns.getAvailableAdapter()
	if not adapter then
		return
	end
	local unitID = adapter:getPlayerUnitID()
	local guid = UnitGUID("player")
	if unitID and guid then
		self:share(adapter, unitID, guid)
	end
end

--- Handle a mouseover/target change.
function Scanner:onSelect(unit)
	if not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then
		return -- non-players and ourselves are handled elsewhere
	end
	-- Opposite-faction players have no authoritative local data to originate;
	-- they are enriched for display only (Tooltip module).
	if ns.Util.isOppositeFaction(unit) then
		return
	end
	local adapter = ns.getAvailableAdapter()
	if not adapter then
		return
	end
	local unitID = adapter:getUnitID(unit)
	local guid = UnitGUID(unit)
	if not unitID or not guid then
		return
	end
	self.selected[unitID] = guid
	self:share(adapter, unitID, guid)
end

--- Handle an asynchronous profile update from an adapter.
function Scanner:onAdapterUpdate(adapter, unitID)
	local guid
	if unitID == adapter:getPlayerUnitID() then
		guid = UnitGUID("player") -- our own profile changed
	else
		guid = self.selected[unitID] -- only previously-selected units
	end
	if guid then
		self:share(adapter, unitID, guid)
	end
end

--- Extract the profile and hand it to the broadcaster (which de-dups).
function Scanner:share(adapter, unitID, guid)
	local profile = adapter:extract(unitID)
	if profile then
		ns.broadcast:originate(guid, unitID, profile)
	end
end

-- Singleton.
ns.scanner = Scanner:new()
ns.OnLogin(function()
	ns.scanner:start()
end)
