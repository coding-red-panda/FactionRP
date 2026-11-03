-- DebugUI.lua
--
-- A reusable debug panel: schema-driven rows built once on first open and
-- only re-textured/re-texted afterwards. One ticker drives all refresh
-- while the window is shown; closing stops it.
--
--   /frp debug     toggle the panel (bare command opens this)
--
-- Left column is the debug category toggles (Const.DEBUG_CATEGORIES).
-- Right side: live relay/stats panes, the selfx launcher, a progress bar,
-- and sent/received payload viewers.

local _, ns = ...
local C = ns.Const
local Util = ns.Util

local UI = ns.Class("DebugUI")
ns.DebugUI = UI

function UI:init()
	self.built = false
	self.genSel = C.PROTO_MAJOR
	self.ticker = nil
end

-- Widget factories ----------------------------------------------------------
-- Each returns a control created once; refresh paths only SetText/SetValue.

local function makeLabel(parent, text, x, y, w, font)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
	fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	if w then
		fs:SetWidth(w)
	end
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
	return fs
end

local function makeCheck(parent, label, x, y, onClick)
	local cb = CreateFrame("CheckButton", nil, parent,
		"UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	cb:SetSize(24, 24)
	cb.text:SetText(label)
	cb:SetScript("OnClick", onClick)
	return cb
end

local function makeButton(parent, label, x, y, w, onClick)
	local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	btn:SetSize(w or 90, 22)
	btn:SetText(label)
	btn:SetScript("OnClick", onClick)
	return btn
end

-- One reused copy dialog: clicking a viewer opens its current text in a
-- focusable EditBox for select-all/copy.
local copyBox
local function showCopy(title, text)
	if not copyBox then
		copyBox = CreateFrame("Frame", "FactionRPDebugCopy", UIParent,
			"BackdropTemplate")
		copyBox:SetSize(520, 340)
		copyBox:SetPoint("CENTER", 0, 60)
		copyBox:SetFrameStrata("DIALOG")
		copyBox:SetMovable(true)
		copyBox:EnableMouse(true)
		copyBox:RegisterForDrag("LeftButton")
		copyBox:SetScript("OnDragStart", copyBox.StartMoving)
		copyBox:SetScript("OnDragStop", copyBox.StopMovingOrSizing)
		copyBox:SetBackdrop({
			bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		copyBox:SetBackdropColor(0.08, 0.09, 0.12, 0.97)
		copyBox.title = makeLabel(copyBox, "", 12, -10, 480, "GameFontNormal")
		local close = CreateFrame("Button", nil, copyBox,
			"UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", copyBox, "TOPRIGHT", -4, -4)
		local scroll = CreateFrame("ScrollFrame", nil, copyBox,
			"UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", copyBox, "TOPLEFT", 12, -34)
		scroll:SetPoint("BOTTOMRIGHT", copyBox, "BOTTOMRIGHT", -30, 12)
		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetAutoFocus(false)
		edit:SetFontObject("ChatFontSmall")
		edit:SetSize(460, 296) -- viewport-sized; the EditBox scrolls text itself
		edit:SetScript("OnEscapePressed", function() copyBox:Hide() end)
		edit:SetScript("OnEnterPressed",
			function(b) b:ClearFocus() copyBox:Hide() end)
		-- detect the Ctrl+C keystroke and dismiss once copy has landed.
		edit:SetScript("OnKeyDown", function(_, key)
			if key == "C" and IsControlKeyDown() then
				C_Timer.After(0.05, function()
					if copyBox:IsShown() then
						copyBox:Hide()
					end
				end)
			end
		end)
		-- Click re-selects everything; user edits revert. Copy box, not
		-- an editor.
		edit:SetScript("OnMouseUp", function(b) b:HighlightText() end)
		edit:SetScript("OnTextChanged", function(b, userInput)
			if userInput and copyBox.text
				and b:GetText() ~= copyBox.text
			then
				b:SetText(copyBox.text)
			end
		end)
		scroll:SetScrollChild(edit)
		copyBox.edit = edit
		copyBox.scroll = scroll
	end
	copyBox.title:SetText(title or "")
	copyBox.text = text
	copyBox.edit:SetText(text or "")
	copyBox.scroll:UpdateScrollChildRect()
	copyBox:Show()
	copyBox.edit:SetFocus()
	copyBox.edit:HighlightText()
end

local function makeViewer(parent, title, x, y, w, h)
	makeLabel(parent, title, x, y, w, "GameFontNormalSmall")
	-- Plain ScrollFrame: the UIPanel template's scrollbar re-shows itself
	-- on every range change, and these panes scroll by wheel only.
	local scroll = CreateFrame("ScrollFrame", nil, parent)
	scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 14)
	scroll:SetSize(w, h)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(w - 8, h)
	scroll:SetScrollChild(child)
	local fs = child:CreateFontString(nil, "OVERLAY", "ChatFontSmall")
	fs:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0)
	fs:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, 0)
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("TOP")
	local bg = scroll:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.05, 0.07, 0.9)
	scroll:EnableMouse(true)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(f, delta)
		f:SetVerticalScroll(math.max(0,
			f:GetVerticalScroll() - delta * 30))
	end)
	local view = { title = title }
	scroll:SetScript("OnMouseUp", function()
		showCopy(view.title, view.text)
	end)
	function view:SetText(text, toBottom)
		view.text = text
		fs:SetText(text or "")
		child:SetHeight(math.max(h, (fs:GetStringHeight() or 0) + 8))
		if toBottom then
			-- Recalc the range now; the rect refresh is deferred otherwise.
			scroll:UpdateScrollChildRect()
			scroll:SetVerticalScroll(scroll:GetVerticalScrollRange())
		else
			scroll:SetVerticalScroll(0)
		end
	end
	return view
end

-- Refresh producers -----------------------------------------------------------

local function relayLines(b)
	local lines, conf, prob, ign = {}, 0, 0, 0
	local now = GetTime()
	for _, p in pairs(b.relays or {}) do
		local gen = p.proto and (" g" .. p.proto) or ""
		if p.ign ~= 0 then
			ign = ign + 1
		elseif p.conf ~= 0 and (now - p.conf) < C.RELAY_CONFIRM_TTL then
			conf = conf + 1
			lines[#lines + 1] = "|cff66ff66C|r " .. (p.name or "?") .. gen
		elseif p.pr > 0 then
			prob = prob + 1
			lines[#lines + 1] = "|cffffcc00P|r " .. (p.name or "?") .. gen
		end
	end
	local bc, bp, bi = 0, 0, 0
	if ns.comms then
		bc, bp, bi = ns.comms:bnetPeerCounts()
	end
	lines[#lines + 1] = ("|cff888888bnet: %d conf / %d probe / %d ign|r")
		:format(bc, bp, bi)
	lines[#lines + 1] = ("|cff888888whisper probing: %d | ignored: %d|r")
		:format(prob, ign)
	return lines
end

local function statsLine()
	local b = ns.broadcast
	return ("cache %d | sendq %d | injectq %d | requests %d | serves %d | mesh %d")
		:format(
			ns.cache and ns.cache:count() or 0,
			ns.comms and ns.comms:queueDepth() or 0,
			b and b:injectDepth() or 0,
			b and (function()
				local n = 0
				for _ in pairs(b.requests or {}) do n = n + 1 end
				return n
			end)() or 0,
			b and (function()
				local n = 0
				for _ in pairs(b.pendingServes or {}) do n = n + 1 end
				return n
			end)() or 0,
			ns.comms and ns.comms:meshCount() or 0)
end

-- Build ----------------------------------------------------------------------

function UI:build()
	if self.built then
		return
	end
	self.built = true

	local f = CreateFrame("Frame", "FactionRPDebugFrame", UIParent,
		"BackdropTemplate")
	f:SetSize(920, 560)
	f:SetPoint("CENTER")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetFrameStrata("HIGH")
	f:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	f:SetBackdropColor(0.08, 0.09, 0.12, 0.95)
	f:Hide()
	self.frame = f

	makeLabel(f, "FactionRP debug", 12, -10, 400, "GameFontNormalLarge")
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

	-- Left column: debug category toggles, one check per Const entry.
	makeLabel(f, "Categories", 12, -40, 160, "GameFontNormal")
	local d = function() return ns.db and ns.db.debug end
	local function applyFlags()
		-- Writes alone do nothing: hooks install via refreshDebugHooks.
		if ns.refreshDebugHooks then
			ns.refreshDebugHooks()
		end
	end
	-- Everything the user can poke, locked while a selfx run is live.
	self.lockable = {}
	local allCb = makeCheck(f, "all", 12, -58, function(cb)
		if d() then
			-- Same semantics as setFlag("all"): write every category too.
			local on = cb:GetChecked() == true
			for _, cat in ipairs(C.DEBUG_CATEGORIES) do
				d()[cat.key] = on
			end
			d().all = on
			applyFlags()
		end
	end)
	self.allCheck = allCb
	self.lockable[#self.lockable + 1] = allCb
	self.catChecks = {}
	local y = -82
	for _, cat in ipairs(C.DEBUG_CATEGORIES) do
		local key = cat.key
		local cb = makeCheck(f, key, 12, y, function(self)
			if d() then
				d()[key] = self:GetChecked() == true
				applyFlags()
			end
		end)
		self.catChecks[key] = cb
		self.lockable[#self.lockable + 1] = cb
		y = y - 24
	end

	-- Right column: live panes.
	makeLabel(f, "Relays", 300, -40, 300, "GameFontNormal")
	self.relayText = makeLabel(f, "", 300, -56, 600, "ChatFontSmall")
	self.relayText:SetMaxLines(9)

	makeLabel(f, "Stats", 300, -180, 300, "GameFontNormal")
	self.statsText = makeLabel(f, "", 300, -196, 600, "ChatFontSmall")

	-- selfx section.
	makeLabel(f, "selfx loopback", 300, -230, 300, "GameFontNormal")
	self.genBtn = makeButton(f, "gen " .. self.genSel, 300, -246, 60,
		function()
			self.genSel = (self.genSel == 6) and 5 or 6
			self.genBtn:SetText("gen " .. self.genSel)
		end)
	self.lockable[#self.lockable + 1] = self.genBtn
	local input = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	input:SetPoint("TOPLEFT", f, "TOPLEFT", 370, -246)
	input:SetSize(150, 22)
	input:SetAutoFocus(false)
	input:SetTextInsets(4, 4, 0, 0)
	self.nameBox = input
	self.lockable[#self.lockable + 1] = input
	local runBtn = makeButton(f, "run", 530, -246, 60, function()
		local name = input:GetText()
		ns.RunSelfx(self.genSel, name ~= "" and name or nil)
		self:updateLockState()
	end)
	self.lockable[#self.lockable + 1] = runBtn
	self.statusText = makeLabel(f, "", 600, -250, 300, "ChatFontSmall")

	local bar = CreateFrame("StatusBar", nil, f)
	bar:SetPoint("TOPLEFT", f, "TOPLEFT", 300, -276)
	bar:SetSize(600, 10)
	bar:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	bar:SetStatusBarColor(0.2, 0.8, 0.4)
	bar.bg = bar:CreateTexture(nil, "BACKGROUND")
	bar.bg:SetAllPoints()
	bar.bg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
	self.bar = bar

	-- Payload viewers.
	self.sentView = makeViewer(f, "sent", 300, -296, 290, 240)
	self.recvView = makeViewer(f, "received", 610, -296, 290, 240)

	-- Log sink under the category column: ns.Print lands here while open.
	self.logView = makeViewer(f, "log", 12, -310, 270, 226)

	f:SetScript("OnShow", function()
		self:refresh()
		self.ticker = C_Timer.NewTicker(1, function()
			self:refresh()
		end)
	end)
	f:SetScript("OnHide", function()
		if self.ticker then
			self.ticker:Cancel()
			self.ticker = nil
		end
	end)
end

--- Disable every interactive control while a selfx run is live; nothing
-- in the panel may toggle mid-test.
function UI:updateLockState()
	if not self.lockable then
		return
	end
	local lock = ns.selfxRun and not ns.selfxRun.done
	for _, c in ipairs(self.lockable) do
		c:SetEnabled(not lock)
	end
end

--- Re-text/re-state every control. Runs on show and once a second while open.
function UI:refresh()
	self:updateLockState()
	local d = ns.db and ns.db.debug
	if d then
		self.allCheck:SetChecked(d.all == true)
		for key, cb in pairs(self.catChecks) do
			cb:SetChecked(d[key] == true or d.all == true)
		end
	end

	local b = ns.broadcast
	if b then
		self.relayText:SetText(table.concat(relayLines(b), "\n"))
	end
	self.statsText:SetText(statsLine())

	local run = ns.selfxRun
	if not run then
		self.statusText:SetText("idle")
		self.bar:SetValue(0)
		return
	end
	local status
	if run.done then
		status = (run.same and "|cff66ff66PASS|r" or "|cffff5555FAIL|r")
			.. " | gen " .. run.gen .. " | " .. run.chunks .. " chunks"
		self.bar:SetMinMaxValues(0, 1)
		self.bar:SetValue(1)
	elseif run.recvTotal then
		status = ("receiving %d/%d"):format(run.recvGot or 0, run.recvTotal)
		self.bar:SetMinMaxValues(0, run.recvTotal)
		self.bar:SetValue(run.recvGot or 0)
	else
		status = "awaiting data leg..."
		self.bar:SetValue(0)
	end
	self.statusText:SetText(status)

	-- Viewers re-fill only when their content changes.
	if run.sentText ~= self._sentShown then
		self._sentShown = run.sentText
		self.sentView:SetText(run.sentText)
	end
	local recv = run.receivedText or (run.done and "(nothing landed)" or "")
	if recv ~= self._recvShown then
		self._recvShown = recv
		self.recvView:SetText(recv)
	end
end

--- Whether the panel is built and shown; gates the ns.Print reroute.
function UI:IsOpen()
	return self.built and self.frame and self.frame:IsShown()
end

--- Append a line to the log pane (the chat sink while the panel is open).
function UI:Print(msg)
	local buf = self.logBuf or {}
	buf[#buf + 1] = date("%H:%M:%S") .. " " .. msg
	if #buf > 300 then
		table.remove(buf, 1)
	end
	self.logBuf = buf
	self.logView:SetText(table.concat(buf, "\n"), true)
end

function UI:toggle()
	self:build()
	if self.frame:IsShown() then
		self.frame:Hide()
	else
		self.frame:Show()
	end
end

ns.debugUI = UI:new()
