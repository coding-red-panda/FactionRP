-- ElixirNotice.lua
--
-- Tracks the Elixir of Tongues buff and warns once when it has less than three
-- minutes left, offering to consume another elixir and refresh it. This is the
-- CrossRP reminder, adapted to FactionRP.
--
-- Nothing here is persisted: the warned state lives only for the session and
-- is reset whenever the buff expires, is refreshed or is reapplied.
--
-- Combat: since 12.0 player auras are secret while the UI is restricted, so
-- C_UnitAuras must not be touched during combat. The tracker simply pauses
-- until combat ends and keeps its current state.

local _, ns = ...
local C = ns.Const

local ElixirNotice = ns.Class("ElixirNotice")
ns.ElixirNotice = ElixirNotice

local POPUP = "FACTIONRP_ELIXIR_NOTICE"
local OUT_OF_ELIXIRS = "You're out of elixirs!"
local TEXT_EXPIRES_IN = "Elixir of Tongues expires in %s."
local TEXT_EXPIRED = "Elixir of Tongues has expired."
local TEXT_INACTIVE = "Elixir of Tongues is not active."

--- Number of elixirs in the player's bags (0 when the API is unavailable).
local function elixirCount()
	if C_Item and C_Item.GetItemCount then
		-- Bags only: the item action cannot consume one from the bank.
		return C_Item.GetItemCount(C.ELIXIR_ITEM_ID, false, false, false) or 0
	end
	return GetItemCount(C.ELIXIR_ITEM_ID) or 0
end

--- Replace the dialog's body text and let the dialog grow or shrink to fit.
-- The dialog frame exposes its text through GetTextFontString(); the plain
-- field is kept as a fallback for older clients.
local function setDialogText(dialog, text)
	local fontString = dialog.GetTextFontString and dialog:GetTextFontString() or dialog.text
	fontString:SetText(text)
	if dialog.Resize then
		dialog:Resize()
	end
end

local function dialogButton1(dialog)
	return dialog.GetButton1 and dialog:GetButton1() or dialog.button1
end

function ElixirNotice:init()
	-- Expiration timestamp of the buff we have already warned for. nil means
	-- the next buff inside the warning window is fair game.
	self.warnedExpiration = nil
	-- Short window after refreshing, so a lagging aura update cannot cause
	-- the same warning to pop straight back up.
	self.graceUntil = 0
	-- Set by PreClick, consumed by OnClick: did we have an elixir to use?
	self.hasElixir = nil
	-- True while the pop-up was opened by hand (slash command). A manual
	-- pop-up stays open regardless of the buff, so the button can be tested.
	self.manual = false
	self:createPopup()
end

--- Time left on the player's Elixir of Tongues buff.
-- @return number seconds left, plus the aura's expiration timestamp.
-- @return nil when the player has no such buff.
-- @return false when the aura cannot be read safely (combat / secret data).
function ElixirNotice:remaining()
	-- Returning false (not nil) keeps callers from mistaking "unknown" for
	-- "no buff": the warning state must survive combat untouched.
	if InCombatLockdown() then
		return false
	end

	local aura = C_UnitAuras.GetPlayerAuraBySpellID(C.ELIXIR_SPELL_ID)
	if not aura then
		return nil
	end
	if not ns.Util.fieldsUsable(aura, "expirationTime") then
		return false
	end

	local expiration = aura.expirationTime
	if not expiration or expiration <= 0 then
		return nil -- no duration; nothing to count down
	end
	local left = expiration - GetTime()
	if left <= 0 then
		return nil
	end
	return left, expiration
end

--- Poll: warn once per buff application when the window is entered.
function ElixirNotice:update()
	if GetTime() < self.graceUntil then
		return
	end

	local left, expiration = self:remaining()
	if left == false then
		return -- unreadable right now; keep the state and try again later
	end
	if not left then
		-- Buff expired or was removed: forget that we warned for it, so the
		-- next elixir gets its own reminder.
		self.warnedExpiration = nil
		return
	end
	if left > C.ELIXIR_NOTICE_LEAD then
		-- Fresh or refreshed buff, outside the window: re-arm.
		self.warnedExpiration = nil
		return
	end

	if self.warnedExpiration ~= expiration then
		self.warnedExpiration = expiration
		self:show()
	end
end

--- Show the reminder pop-up.
-- @param manual boolean? True when opened by hand; the pop-up then stays up
--                        even when the buff is fresh or absent.
function ElixirNotice:show(manual)
	if InCombatLockdown() then
		-- The Refresh button is a protected frame and gets reparented on
		-- show; that is not allowed in combat.
		ns.Print("The Elixir of Tongues reminder cannot be shown in combat.")
		return
	end
	self.manual = manual and true or false
	StaticPopup_Show(POPUP)
end

-- Pop-up ---------------------------------------------------------------------

-- The countdown refreshes once a second; only rewrite the text when the
-- rounded label actually changes.
function ElixirNotice:label(left)
	if left < 60 then
		return ("%d %s"):format(math.ceil(left), SECONDS:lower())
	end
	return ("%d %s"):format(math.ceil(left / 60), MINUTES:lower())
end

--- Body text for the current buff state; nil while it cannot be read.
function ElixirNotice:text()
	local left = self:remaining()
	if left == false then
		return nil -- aura secret in combat; leave the last text as-is
	end
	if not left then
		return self.manual and TEXT_INACTIVE or TEXT_EXPIRED
	end
	return TEXT_EXPIRES_IN:format(self:label(left))
end

function ElixirNotice:createPopup()
	local Me = self

	-- A secure button is required for the cast; a plain button cannot use the
	-- item. It sits on top of the popup's normal accept button.
	local button = CreateFrame("Button", nil, UIParent,
		"StaticPopupButtonTemplate, InsecureActionButtonTemplate")
	-- The secure action only fires on the mouse-up click the button is
	-- registered for when it is told not to follow ActionButtonUseKeyDown
	-- (which is on by default and would make it fire on mouse-down only).
	button:RegisterForClicks("AnyUp")
	button:SetAttribute("useOnKeyDown", false)
	-- Dedicated item action rather than macrotext: it consumes one elixir
	-- straight from the bags, by item ID so it is locale-independent.
	button:SetAttribute("type", "item")
	button:SetAttribute("item", "item:" .. C.ELIXIR_ITEM_ID)
	button:SetText(REFRESH)
	button:Hide() -- parented to the popup only while it is shown
	-- PreClick runs before the secure action consumes an elixir, so this is
	-- the only point where the bag count still reflects the pre-click state.
	button:HookScript("PreClick", function()
		Me.hasElixir = elixirCount() > 0
	end)
	button:HookScript("OnClick", function()
		Me:onRefreshClicked()
	end)
	self.refreshButton = button

	StaticPopupDialogs[POPUP] = {
		text = "",
		button1 = REFRESH,
		button2 = IGNORE,
		timeout = 0,
		OnShow = function(dialog)
			-- The popup is only shown out of combat, so reparenting this
			-- protected frame is safe here.
			local accept = dialogButton1(dialog)
			button:SetParent(dialog)
			button:SetAllPoints(accept)
			button:SetFrameLevel(accept:GetFrameLevel() + 1)
			button:Show()
			dialog.lastText = nil
			local text = Me:text()
			if text then
				dialog.lastText = text
				setDialogText(dialog, text)
			end
		end,
		OnHide = function(dialog)
			button:Hide()
			dialog.lastText = nil
			Me.manual = false
		end,
		OnAccept = function() end,
		OnCancel = function() end,
		OnUpdate = function(dialog)
			local left = Me:remaining()
			if left and left > C.ELIXIR_NOTICE_LEAD and not Me.manual then
				-- Refreshed by other means: the reminder is moot.
				dialog:Hide()
				return
			end
			local text = Me:text()
			if text and text ~= dialog.lastText then
				dialog.lastText = text
				setDialogText(dialog, text)
			end
		end,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = STATICPOPUPS_NUMDIALOGS,
	}
end

--- Called after the secure button consumed an elixir (if there was one).
function ElixirNotice:onRefreshClicked()
	local hadElixir = self.hasElixir
	self.hasElixir = nil
	if hadElixir then
		-- Refresh requested: allow the next expiry to warn again, and give
		-- the new aura a moment to land before tracking resumes.
		self.warnedExpiration = nil
		self.graceUntil = GetTime() + C.ELIXIR_NOTICE_GRACE
	else
		-- Nothing to consume; the player has been warned already, so keep the
		-- warned state and do not nag again for this buff.
		UIErrorsFrame:AddMessage(OUT_OF_ELIXIRS, 1, 0, 0)
	end
	StaticPopup_Hide(POPUP)
end

-- Singleton.
ns.elixirNotice = ElixirNotice:new()
ns.OnLogin(function()
	C_Timer.NewTicker(C.ELIXIR_NOTICE_INTERVAL, function()
		ns.elixirNotice:update()
	end)
end)

ns.RegisterCommand("elixir", function()
	ns.elixirNotice:show(true)
end, "Show the Elixir of Tongues reminder now (for testing the Refresh button).")
