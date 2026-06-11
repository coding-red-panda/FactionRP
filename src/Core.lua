-- Core.lua
--
-- The AddOn's backbone: it owns the shared event frame, a small event-dispatch
-- layer, the saved-variables bootstrap, a colourised print helper, and the
-- slash-command registry. Other modules attach to these services rather than
-- creating their own frames or slash handlers.

local addonName, ns = ...
local C = ns.Const

ns.name = addonName

-- Print --------------------------------------------------------------------

local PRINT_PREFIX = "|cff33ff99" .. C.ADDON_NAME .. "|r: "

--- Print a chat message prefixed and coloured with the AddOn name.
-- Accepts any number of values, joined with spaces.
function ns.Print(...)
	print(PRINT_PREFIX .. strjoin(" ", tostringall(...)))
end

-- Event dispatch ------------------------------------------------------------
--
-- A single hidden frame multiplexes all game events. Modules register a
-- handler per event via ns.RegisterEvent; multiple handlers may share an event.

local eventHandlers = {} -- [event] = { handler1, handler2, ... }

local frame = CreateFrame("Frame", "FactionRPEventFrame")
ns.frame = frame

frame:SetScript("OnEvent", function(_, event, ...)
	local handlers = eventHandlers[event]
	if not handlers then
		return
	end
	for i = 1, #handlers do
		handlers[i](event, ...)
	end
end)

--- Register a handler for a game event.
-- @param event   string   The event name (e.g. "PLAYER_TARGET_CHANGED").
-- @param handler function The callback, invoked as handler(event, ...).
function ns.RegisterEvent(event, handler)
	local handlers = eventHandlers[event]
	if not handlers then
		handlers = {}
		eventHandlers[event] = handlers
		frame:RegisterEvent(event)
	end
	handlers[#handlers + 1] = handler
end

--- Convenience: run `fn` once the player has fully logged in (UI and saved
-- variables are ready). If login already happened, runs on the next frame.
-- @param fn function Callback invoked as fn().
function ns.OnLogin(fn)
	if ns._loggedIn then
		C_Timer.After(0, fn)
	else
		ns.RegisterEvent("PLAYER_LOGIN", fn)
	end
end

-- Slash commands ------------------------------------------------------------
--
-- Modules register sub-commands ("/factionrp <sub> <args>") here. With no
-- recognised sub-command, usage for all registered commands is printed.

ns.commands = {} -- [subcommand] = { handler = fn, help = string }

--- Register a slash sub-command.
-- @param sub     string   The sub-command keyword (case-insensitive).
-- @param handler function Invoked as handler(argString).
-- @param help    string?  One-line description shown in the usage listing.
function ns.RegisterCommand(sub, handler, help)
	ns.commands[sub:lower()] = { handler = handler, help = help }
end

SLASH_FACTIONRP1 = "/factionrp"
SLASH_FACTIONRP2 = "/frp"
SlashCmdList["FACTIONRP"] = function(msg)
	-- First whitespace-delimited token is the sub-command; the rest are args.
	local sub, rest = msg:match("^(%S*)%s*(.-)$")
	local cmd = ns.commands[(sub or ""):lower()]
	if cmd then
		cmd.handler(rest)
	else
		ns.Print("Usage:")
		-- Stable-ish ordering is not guaranteed by pairs, which is fine for a
		-- short help listing.
		for name, c in pairs(ns.commands) do
			print(("  /factionrp %s|r - %s"):format(name, c.help or ""))
		end
	end
end

-- Lifecycle -----------------------------------------------------------------

-- Saved variables (declared in the .toc). Currently only the debug flag is
-- persisted; populated/normalised on ADDON_LOADED.
ns.RegisterEvent("ADDON_LOADED", function(_, loaded)
	if loaded ~= addonName then
		return
	end
	FactionRPDB = FactionRPDB or {}
	ns.db = FactionRPDB
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
	ns._loggedIn = true
end)

-- A built-in status sub-command so the foundation is observably alive.
ns.RegisterCommand("status", function()
	ns.Print(("version %s loaded."):format(C.VERSION))
end, "Show version and status")
