-- Tooltip.lua
--
-- Enriches tooltips for opposite-faction players using cached gossip. We do not
-- render anything ourselves: we inject the cached profile into the source RP
-- AddOn's register, which then refreshes and draws its own tooltip (TRP3, for
-- example, re-renders the shown tooltip on REGISTER_DATA_UPDATED). This reuses
-- the AddOn's exact presentation for free.

local _, ns = ...

local Tooltip = ns.Class("Tooltip")
ns.Tooltip = Tooltip

function Tooltip:start()
	-- Mirror the triggers TRP3 itself uses to detect the tooltip's unit.
	if GameTooltip then
		hooksecurefunc(GameTooltip, "SetUnit", function(tt)
			self:onTooltipUnit(tt)
		end)
	end
	ns.RegisterEvent("UPDATE_MOUSEOVER_UNIT", function()
		if UnitExists("mouseover") then
			self:tryInject("mouseover")
		end
	end)
end

--- If `unit` is an opposite-faction player we have cached, inject the profile.
function Tooltip:tryInject(unit)
	-- During combat (e.g. in dungeons) the unit token can be a "secret" value.
	-- Passing it to UnitIsPlayer and friends during our (tainted) execution
	-- errors, so bail out immediately. The detection global is `issecretvalue`
	-- (guarded for clients predating the secret-values system).
	if issecretvalue(unit) then
		return
	end

	if not unit or not UnitIsPlayer(unit) or not ns.Util.isOppositeFaction(unit) then
		return
	end

	local guid = UnitGUID(unit)
	if not guid then
		return
	end

	local entry = ns.cache:get(guid)
	if not entry then
		return
	end

	local adapter = ns.getAdapter(entry.addon)
	if not adapter or not adapter:isAvailable() then
		return
	end

	-- The unit is present, so pass its class id for correct name colouring.
	local classID = select(3, UnitClass(unit))
	adapter:inject(entry.unitID, entry.data, classID)
	-- The source AddOn refreshes the shown tooltip on its own data-update event.
end

function Tooltip:onTooltipUnit(tt)
	local _, unit = tt:GetUnit()
	if unit then
		self:tryInject(unit)
	end
end

-- Singleton.
ns.tooltip = Tooltip:new()
ns.OnLogin(function()
	ns.tooltip:start()
end)
