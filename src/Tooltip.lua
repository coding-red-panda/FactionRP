-- Tooltip.lua
--
-- Enriches tooltips for opposite-faction players using cached profile data.
-- We do not
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
		self:startIndicator()
	end
	ns.RegisterEvent("UPDATE_MOUSEOVER_UNIT", function()
		local exists = UnitExists("mouseover")
		if ns.Util.canWeUse(exists) and exists then
			self:tryInject("mouseover")
		end
	end)
end

--- If `unit` is an opposite-faction player we have cached, inject the profile.
function Tooltip:tryInject(unit)
	-- During combat (e.g. in dungeons) the unit token can be a "secret"
	-- value. Passing it to UnitIsPlayer and friends during our (tainted)
	-- execution errors, so bail out immediately.
	if not ns.Util.canWeUse(unit) then
		return
	end

	-- The token checks out, but the results themselves can still be secret.
	local isPlayer = UnitIsPlayer(unit)
	if not ns.Util.canWeUse(isPlayer) or not unit or not isPlayer
		or not ns.Util.isOppositeFaction(unit) then
		return
	end

	local guid = UnitGUID(unit)
	if not ns.Util.canWeUse(guid) or not guid then
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
	adapter:inject(entry.unitID, entry.data,
		ns.Util.canWeUse(classID) and classID or nil)
	-- The source AddOn refreshes the shown tooltip on its own data-update event.
end

function Tooltip:onTooltipUnit(tt)
	local _, unit = tt:GetUnit()
	if unit then
		self:tryInject(unit)
	end
	if self.ind then
		self:updateIndicator()
	end
end

-- Pull-status indicator -------------------------------------------------------
--
-- A small overlay hung off the tooltip's edge, never a line inside it: it
-- cannot resize or reorder anyone else's content, and TRP3's tooltip
-- rebuilds pass over it untouched. It only exists for an opposite-faction
-- subject with a pull in flight or a recent miss.

local IND_WIDTH = 110
local IND_BAR_H = 4

function Tooltip:startIndicator()
	local ind = CreateFrame("Frame", "FactionRPTooltipStatus", UIParent)
	ind:SetFrameStrata("TOOLTIP")
	ind:SetSize(IND_WIDTH, 14)
	ind:Hide()

	local text = ind:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("BOTTOMLEFT", 0, IND_BAR_H + 2)
	ind.text = text

	local bar = CreateFrame("StatusBar", nil, ind)
	bar:SetPoint("BOTTOMLEFT", 0, 0)
	bar:SetSize(IND_WIDTH, IND_BAR_H)
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
	bar:SetStatusBarColor(0.35, 0.75, 0.85)
	bar:SetMinMaxValues(0, 1)
	bar:Hide()
	ind.bar = bar
	self.ind = ind

	GameTooltip:HookScript("OnHide", function()
		ind:Hide()
	end)
	C_Timer.NewTicker(0.25, function()
		self:updateIndicator()
	end)
end

function Tooltip:updateIndicator()
	local ind = self.ind
	if not GameTooltip:IsShown() then
		return
	end
	local status, got, total
	local unit = select(2, GameTooltip:GetUnit())
	if unit and ns.Util.canWeUse(unit) then
		local isPlayer = UnitIsPlayer(unit)
		if ns.Util.canWeUse(isPlayer) and isPlayer
			and ns.Util.isOppositeFaction(unit)
		then
			local guid = UnitGUID(unit)
			if ns.Util.canWeUse(guid) and guid then
				status, got, total = ns.broadcast:reqStatus(guid)
			end
		end
	end
	if not status then
		if ind:IsShown() then
			ind.status = nil
			ind:Hide()
		end
		return
	end
	local pct = 0
	if status == "receiving" and got and total and total > 0 then
		pct = math.floor(got / total * 100 + 0.5)
	end
	-- Above the tooltip only when there is no room below.
	local bottom = GameTooltip:GetBottom()
	local above = bottom ~= nil and bottom < 40
	-- Steady state allocates and touches nothing.
	if ind:IsShown() and ind.status == status and ind.pct == pct
		and ind.above == above
	then
		return
	end
	ind.status, ind.pct, ind.above = status, pct, above
	ind:ClearAllPoints()
	if above then
		ind:SetPoint("BOTTOMLEFT", GameTooltip, "TOPLEFT", 4, 2)
	else
		ind:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 4, -2)
	end
	if status == "receiving" then
		ind.bar:SetValue(pct / 100)
		ind.bar:Show()
		ind.text:SetText("FRP receiving " .. pct .. "%")
		ind.text:SetTextColor(0.45, 0.8, 0.9)
	elseif status == "miss" then
		ind.bar:Hide()
		ind.text:SetText("FRP no response")
		ind.text:SetTextColor(0.7, 0.45, 0.45)
	else
		ind.bar:Hide()
		ind.text:SetText("FRP requesting profile...")
		ind.text:SetTextColor(0.55, 0.55, 0.55)
	end
	ind:Show()
end

-- Singleton.
ns.tooltip = Tooltip:new()
ns.OnLogin(function()
	ns.tooltip:start()
end)
