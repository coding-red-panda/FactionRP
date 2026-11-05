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

-- Loading on demand tooltip
local C = ns.Const
local Util = ns.Util

local TRP3About = ns.Class("TRP3About")

local unavailable = "About loading is not available yet."
local loadedHint = "Description loaded."
local missingHint = "Description not loaded."
local requestHint = "Click the arrow to request the description."
local searchingHint = "Searching for the description..."
local loadingHint = "Loading the description..."
local cooldownHint = "Try again in %d s."
local pausedHint = "Loading is currently paused."
local busyHint = "Another description is still loading."
local failureHints = {
	missing = "Description not found at the available contacts.",
	["no-contact"] = "No FactionRP contact or channel is available.",
	["no-response"] = "No reply to the description request.",
	["too-large"] = "The description is too large for this transfer.",
	timeout = "The description transfer timed out.",
	invalid = "The description could not be loaded.",
	busy = "The description service is busy; try again shortly.",
	cached = "Description was loaded recently.",
}

local function readContext(cachedFaction)
	local api = TRP3_API
	if not api or not api.navigation or not api.navigation.page
		or not api.register or not api.register.player or not api.register.ui
	then
		return
	end

	local page = api.navigation.page
	if page.getCurrentPageID() ~= "player_main" then
		return
	end

	local context = page.getCurrentContext()
	if not Util.fieldsUsable(context, "isPlayer", "unitID", "profileID", "profile")
		or context.isPlayer
		or type(context.profileID) ~= "string" or context.profileID == "" or type(context.profile) ~= "table"
	then
		return
	end

	local unitID = context.unitID
	if unitID == nil then

		for linkedID in pairs(context.profile.link or {}) do
			if unitID then
				return
			end
			unitID = linkedID
		end
	end
	if not Util.canWeUse(unitID) or type(unitID) ~= "string" or unitID == ""
		or unitID == api.globals.player_id
	then
		return
	end

	local reg = api.register
	if not reg.isUnitIDKnown(unitID)
		or reg.getUnitIDProfileID(unitID) ~= context.profileID
		or reg.getUnitIDProfile(unitID) ~= context.profile
	then
		return
	end

	local character = reg.getUnitIDCharacter(unitID)
	if not Util.fieldsUsable(character, "faction") then
		return
	end

	local faction = character.faction
	local restricted = Util.commsRestricted()
	local ownFaction = cachedFaction


	if not restricted then
		ownFaction = UnitFactionGroup("player")
		for _, unit in ipairs({ "mouseover", "target", "focus" }) do
			local liveUnitID = Util.getUnitID(unit)
			if Util.canWeUse(liveUnitID) and type(liveUnitID) == "string"
				and Util.normalizeUnitName(liveUnitID) == Util.normalizeUnitName(unitID)
			then
				faction = UnitFactionGroup(unit)
				break
			end
		end
	end

	if not Util.canWeUse(faction, ownFaction)
		or (faction ~= "Alliance" and faction ~= "Horde")
		or (ownFaction ~= "Alliance" and ownFaction ~= "Horde")
		or faction == ownFaction
	then
		return
	end

	local group = reg.player.tabGroup
	if not group or not group.tabs or not group.tabs[2]
		or type(group.UpdateTabStates) ~= "function"
		or type(group.tabs[2].GetFrameLevel) ~= "function"
		or type(api.loc.REG_PLAYER_ABOUT) ~= "string"
	then
		return
	end

	local loaded = reg.ui.shouldShowAboutTab(context.profile) and true or false
	local about = context.profile.about
	if Util.fieldsUsable(about, "v") and type(about.v) == "number" then
		loaded = true
	end

	return context, group, unitID, loaded, restricted, ownFaction
end

function TRP3About:getContext()
	local ok, context, group, unitID, loaded, restricted, ownFaction = pcall(readContext, self.ownFaction)
	if ok then
		if context then
			self.ownFaction = ownFaction
		end
		return context, group, unitID, loaded, restricted
	end
end

function TRP3About:setRequestHandler(handler, statusHandler)
	if (handler ~= nil and type(handler) ~= "function")
		or (statusHandler ~= nil and type(statusHandler) ~= "function")
	then
		return false
	end

	self.requestHandler = handler
	self.statusHandler = statusHandler
	if not handler then
		self.requestState = nil
	end
	self:update()
	return true
end

function TRP3About:setRequestState(unitID, profileID, status, retryAt)
	if not Util.canWeUse(unitID, profileID, status, retryAt)
		or (status ~= "idle" and status ~= "searching" and status ~= "loading" and status ~= "cooldown")
		or (status == "cooldown" and (type(retryAt) ~= "number" or retryAt ~= retryAt or math.abs(retryAt) == math.huge))
	then
		return false
	end

	local context, _, currentUnitID = self:getContext()
	local request = self.requestState
	local current = context and unitID == currentUnitID and profileID == context.profileID
	local pending = request and request.unitID == unitID and request.profileID == profileID
	if not current and not pending then
		return false
	end

	self.requestState = { unitID = unitID, profileID = profileID, status = status, retryAt = retryAt }
	self:update()
	return true
end

function TRP3About:status(context, unitID, restricted)
	if restricted then
		return "paused", false
	end
	if not self.requestHandler then
		return "unavailable", false
	end
	if self.statusHandler then
		local ok, status, retryAt, reason = pcall(self.statusHandler, unitID, context.profileID)
		if not ok then
			return "unavailable", false
		end
		if status == "idle" then
			return "idle", true
		elseif status == "searching" or status == "loading" or status == "busy" then
			return status, false
		elseif status == "cooldown" and type(retryAt) == "number" and retryAt ~= math.huge and retryAt > GetTime() then
			return status, false, math.ceil(retryAt - GetTime()), retryAt, reason
		end
		return "unavailable", false
	end

	local request = self.requestState
	if request and request.unitID == unitID and request.profileID == context.profileID then
		if request.status == "cooldown" then
			local remaining = math.ceil(request.retryAt - GetTime())
			if remaining > 0 then
				return "cooldown", false, remaining, request.retryAt
			end
		elseif request.status == "searching" or request.status == "loading" then
			return request.status, false
		end
	end

	return "idle", true
end

function TRP3About:showTooltip(button)
	if not TRP3_TooltipUtil or type(TRP3_TooltipUtil.ShowTooltip) ~= "function" then
		return
	end

	TRP3_TooltipUtil.ShowTooltip(button, function(_, tooltip)
		local context, _, unitID, loaded, restricted = self:getContext()
		if not context then
			tooltip:SetShouldShow(false)
			self:update()
			return
		end

		local status, _, remaining, _, reason = self:status(context, unitID, restricted)
		tooltip:AddTitleLine(TRP3_API.loc.REG_PLAYER_ABOUT)
		tooltip:AddNormalLine(loaded and loadedHint or missingHint)
		if status == "cooldown" then
			if failureHints[reason] then
				tooltip:AddNormalLine(failureHints[reason])
			end
			tooltip:AddNormalLine(cooldownHint:format(remaining))
		elseif status == "searching" then
			tooltip:AddNormalLine(searchingHint)
		elseif status == "loading" then
			tooltip:AddNormalLine(loadingHint)
		elseif status == "paused" then
			tooltip:AddNormalLine(pausedHint)
		elseif status == "busy" then
			tooltip:AddNormalLine(busyHint)
		else
			tooltip:AddNormalLine(status == "unavailable" and unavailable or requestHint)
		end
	end)
end

function TRP3About:update()
	local context, group, unitID, loaded, restricted = self:getContext()
	if not context or not group then
		if self.button then
			self.button:Hide()
		end
		return
	end

	if self.group ~= group then
		if self.button then
			self.button:Hide()
		end

		local tab = group.tabs[2]
		local button = CreateFrame("Button", nil, tab)
		button:SetSize(16, 16)
		button:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -3, 2)
		button:SetFrameLevel(tab:GetFrameLevel() + 1)
		button:SetMotionScriptsWhileDisabled(true)
		button:EnableMouse(true)

		local icon = button:CreateTexture(nil, "ARTWORK")
		icon:SetAllPoints()
		icon:SetTexture("Interface\\Buttons\\UI-RefreshButton")
		icon:SetDesaturated(true)
		button.icon = icon

		local glow = button:CreateTexture(nil, "OVERLAY")
		glow:SetAllPoints()
		glow:SetTexture("Interface\\Buttons\\UI-RefreshButton")
		glow:SetDesaturated(true)
		glow:SetBlendMode("ADD")
		button.glow = glow
		button.pulse = glow:CreateAnimationGroup()
		button.pulse:SetLooping("REPEAT")
		for index, alpha in ipairs({ { 0.2, 1 }, { 1, 0.2 } }) do
			local animation = button.pulse:CreateAnimation("Alpha")
			animation:SetOrder(index)
			animation:SetDuration(0.6)
			animation:SetFromAlpha(alpha[1])
			animation:SetToAlpha(alpha[2])
		end

		button:SetScript("OnClick", function()
			if ns.debugAbout then
				ns.debugAbout("click")
			end
			local current, _, currentUnitID, _, paused = self:getContext()
			if not current or not select(2, self:status(current, currentUnitID, paused)) then
				if ns.debugAbout then
					ns.debugAbout("click blocked", nil, "profile context or request unavailable")
				end
				self:update()
				return
			end

			self:setRequestState(currentUnitID, current.profileID, "searching")
			local request = self.requestState
			local ok, started = pcall(self.requestHandler, currentUnitID, current.profileID)
			if not ok or started ~= true then
				if ns.debugAbout then
					ns.debugAbout(ok and "request not started" or "handler failed")
				end
				if self.requestState == request then
					self.requestState = nil
				end
				self:update()
			end
		end)
		button:SetScript("OnEnter", function()
			self:showTooltip(button)
		end)
		button:SetScript("OnLeave", function()
			if TRP3_TooltipUtil and type(TRP3_TooltipUtil.HideTooltip) == "function" then
				TRP3_TooltipUtil.HideTooltip(button)
			end
		end)
		button:SetScript("OnShow", function()
			if self.button == button then
				self:update()
			end
		end)
		button:SetScript("OnHide", function()
			button.pulse:Stop()
			button.glow:Hide()
			button:SetScript("OnUpdate", nil)
			if TRP3_TooltipUtil and type(TRP3_TooltipUtil.HideTooltip) == "function" then
				TRP3_TooltipUtil.HideTooltip(button)
			end
		end)

		self.button, self.group = button, group
		hooksecurefunc(group, "UpdateTabStates", function()
			if self.group == group then
				self:update()
			end
		end)
	end

	local button = self.button
	local status, enabled, _, retryAt = self:status(context, unitID, restricted)
	button.status, button.loaded = status, loaded
	button.retryAt = retryAt
	button:SetEnabled(enabled)
	local r, g, b = GameFontNormalSmall:GetTextColor()
	if enabled or status == "loading" then
		button.icon:SetVertexColor(r, g, b)
	else
		button.icon:SetVertexColor(0.45, 0.45, 0.45)
	end
	button.glow:SetVertexColor(r, g, b)
	if status == "loading" then
		button.glow:Show()
		if not button.pulse:IsPlaying() then
			button.pulse:Play()
		end
	else
		button.pulse:Stop()
		button.glow:Hide()
	end
	button:SetScript("OnUpdate", status == "cooldown" and function()
		if button.retryAt and GetTime() >= button.retryAt then
			self:update()
		end
	end or nil)
	self.button:Show()
	if TRP3_MainTooltip and TRP3_TooltipUtil and type(TRP3_TooltipUtil.IsOwned) == "function"
		and TRP3_TooltipUtil.IsOwned(TRP3_MainTooltip, button)
	then
		self:showTooltip(button)
	end
end

function TRP3About:start()
	local api = TRP3_API
	if not api or type(api.RegisterCallback) ~= "function"
		or not TRP3_Addon or not TRP3_Addon.Events
	then
		return
	end

	if self.api ~= api then
		self.api = api
		self.events = {}
	end

	for _, event in ipairs({
		"WORKFLOW_ON_LOADED", "WORKFLOW_ON_FINISH", "REGISTER_PROFILE_OPENED",
		"REGISTER_DATA_UPDATED", "PAGE_OPENED",
	}) do
		local name = TRP3_Addon.Events[event]
		if type(name) == "string" and not self.events[name] then
			local ok = pcall(api.RegisterCallback, TRP3_Addon, name, function()
				self:update()
			end)
			if ok then
				self.events[name] = true
			end
		end
	end

	self:update()
end

ns.trp3About = TRP3About:new()

ns.RegisterEvent("ADDON_LOADED", function(_, addon)
	if addon == "totalRP3" then
		ns.trp3About:start()
	end
end)

for _, event in ipairs({
	"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "LOADING_SCREEN_ENABLED", "LOADING_SCREEN_DISABLED",
	"PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED", "CHALLENGE_MODE_RESET",
}) do
	ns.RegisterEvent(event, function()
		local about = ns.trp3About
		about:update()
		if about.resumeTimer then
			about.resumeTimer:Cancel()
		end

		local timer
		timer = C_Timer.NewTimer(C.LOADING_RESUME_DELAY + 0.1, function()
			if about.resumeTimer == timer then
				about.resumeTimer = nil
				about:update()
			end
		end)
		about.resumeTimer = timer
	end)
end

ns.OnLogin(function()
	ns.trp3About:start()
end)
