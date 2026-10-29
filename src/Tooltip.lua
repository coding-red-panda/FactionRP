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
		if ns.Util.commsRestricted() then
			return
		end
		local exists = UnitExists("mouseover")
		if ns.Util.canWeUse(exists) and exists then
			self:tryInject("mouseover")
		end
	end)
end

--- If `unit` is an opposite-faction player we have cached, inject the profile.
function Tooltip:tryInject(unit)
	if ns.Util.commsRestricted() then
		return -- no unit reads at all under lockdown
	end
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
	if ns.Util.commsRestricted() then
		if self.ind then
			self.ind:Hide()
		end
		return
	end

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
-- A small plate hung off the tooltip's edge, never a line inside it: it
-- cannot resize or reorder anyone else's content, and TRP3's tooltip
-- rebuilds pass over it untouched. It only exists for an opposite-faction
-- subject with a pull in flight or a recent miss. During "receiving" the
-- translucent fill sweeps the plate left-to-right as chunks land.

local IND_HEIGHT = 18
local IND_MIN_WIDTH = 180
local IND_MAX_WIDTH = 400

function Tooltip:startIndicator()
	local ind = CreateFrame("Frame", "FactionRPTooltipStatus", UIParent,
		"BackdropTemplate")
	ind:SetFrameStrata("TOOLTIP")
	ind:SetSize(IND_MIN_WIDTH, IND_HEIGHT)
	ind:Hide()
	ind:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Buttons\\WHITE8x8",
		edgeSize = 1,
	})
	ind:SetBackdropColor(0.04, 0.04, 0.04, 0.85)
	ind:SetBackdropBorderColor(1, 1, 1, 0.2)

	local fill = ind:CreateTexture(nil, "ARTWORK")
	fill:SetPoint("TOPLEFT", 1, -1)
	fill:SetPoint("BOTTOMLEFT", 1, 1)
	fill:SetColorTexture(1, 1, 1, 1)
	fill:SetWidth(1)
	fill:Hide()
	ind.fill = fill

	local text = ind:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("CENTER")
	text:SetJustifyH("CENTER")
	ind.text = text
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
	local unit = not ns.Util.commsRestricted()
		and select(2, GameTooltip:GetUnit())
	if unit and ns.Util.canWeUse(unit) then
		local isPlayer = UnitIsPlayer(unit)
		if ns.Util.canWeUse(isPlayer) and isPlayer
			and ns.Util.isOppositeFaction(unit)
		then
			local guid = UnitGUID(unit)
			if ns.Util.canWeUse(guid) and guid then
				status, got, total = ns.broadcast:reqStatus(guid)
				if not status and ns.scanner then
					local frac = ns.scanner:hoverProgress(guid)
					if frac then
						status, got = "hover", frac
					end
				end
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
	local pct, retry = 0, 0
	if status == "receiving" and got and total and total > 0 then
		pct = math.floor(got / total * 100 + 0.5)
	elseif status == "miss" and got then
		retry = got
	elseif status == "hover" and got then
		pct = math.floor(got * 100 + 0.5)
		retry = math.max(1, math.ceil(
			ns.Const.MOUSEOVER_REQ_DELAY * (1 - got)))
	end
	-- Width follows the tooltip; clamp for unreadable or degenerate sizes.
	local width = GameTooltip:GetWidth()
	if not ns.Util.canWeUse(width) or not width or width < IND_MIN_WIDTH then
		width = IND_MIN_WIDTH
	elseif width > IND_MAX_WIDTH then
		width = IND_MAX_WIDTH
	end
	-- Above the tooltip only when there is no room below.
	local bottom = GameTooltip:GetBottom()
	local above = bottom ~= nil and bottom < IND_HEIGHT + 20
	-- Steady state allocates and touches nothing.
	if ind:IsShown() and ind.status == status and ind.pct == pct
		and ind.retry == retry and ind.above == above
		and ind.width == width
	then
		return
	end
	ind.status, ind.pct, ind.retry = status, pct, retry
	ind.above, ind.width = above, width
	ind:ClearAllPoints()
	if above then
		ind:SetPoint("BOTTOMLEFT", GameTooltip, "TOPLEFT", 0, 2)
	else
		ind:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 0, -2)
	end
	ind:SetWidth(width)
	if status == "receiving" then
		ind.fill:SetWidth(math.max(1, (width - 2) * pct / 100))
		ind.fill:SetVertexColor(0.35, 0.75, 0.85, 0.3)
		ind.fill:Show()
		ind.text:SetText("Please wait... " .. pct .. "%")
		ind.text:SetTextColor(0.9, 0.95, 1.0)
	elseif status == "miss" then
		ind.fill:SetWidth(math.max(1, (width - 2) * retry / ns.Const.REQ_COOLDOWN))
		ind.fill:SetVertexColor(0.7, 0.45, 0.45, 0.3)
		ind.fill:Show()
		ind.text:SetText("No response. Try again in " .. retry .. "s")
		ind.text:SetTextColor(0.85, 0.7, 0.7)
	elseif status == "hover" then
		ind.fill:SetWidth(math.max(1, (width - 2) * pct / 100))
		ind.fill:SetVertexColor(0.5, 0.85, 0.6, 0.3)
		ind.fill:Show()
		ind.text:SetText("Requesting profile in " .. retry .. "s")
		ind.text:SetTextColor(0.8, 0.95, 0.85)
	else
		ind.fill:Hide()
		ind.text:SetText("Please wait...")
		ind.text:SetTextColor(0.75, 0.75, 0.75)
	end
	ind:Show()
end

-- Singleton.
ns.tooltip = Tooltip:new()
ns.OnLogin(function()
	ns.tooltip:start()
end)
