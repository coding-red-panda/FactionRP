-- Debug.lua
--
-- Optional verbose logging, split into the Const.DEBUG_CATEGORIES list and
-- toggled via "/factionrp debug <category>" or "all".
--
-- Enabled hooks install onto ns (ns.debugReceive, ...); call sites are
-- nil-guarded so a disabled category costs one table lookup. The "targets"
-- category has no hook: it gates whether pinned whisper targets send.

local _, ns = ...
local C = ns.Const

--- Whether a debug category is enabled (directly or via `all`). The flag
-- query for non-hook call sites (Broadcast's `targets` gate, Stats).
-- @param category string One of Const.DEBUG_CATEGORIES keys.
-- @return boolean
function ns.debugEnabled(category)
	local d = ns.db and ns.db.debug
	return d ~= nil and (d.all or d[category]) == true
end

-- Log hook implementations ---------------------------------------------------
-- Each implementation is stored next to the category that gates it; the
-- installer below publishes them under their ns.* names while enabled.

local function logReceive(senderGUID, subjectGUID)
	ns.Print(("|cff66ccff[received]|r from %s (subject %s)"):format(tostring(senderGUID), tostring(subjectGUID)))
end

local function logStore(result, guid)
	local R = ns.Cache.RESULT
	if result == R.NEW then
		ns.Print("|cff33ff66[cache]|r stored " .. tostring(guid))
	elseif result == R.UPDATED then
		ns.Print("|cff33ff66[cache]|r updated " .. tostring(guid))
	elseif result == R.REFRESHED then
		ns.Print("|cff999999[cache]|r refreshed " .. tostring(guid))
	end
	-- REJECTED (stale) entries are intentionally not logged to avoid noise.
end

local function logReceived(unitID)
	ns.Print("|cff66ccff[received]|r profile data for " .. tostring(unitID) .. " (queued)")
end

local function logSkip(unitID, reason)
	ns.Print(("|cffffd200[skip]|r %s (%s)"):format(tostring(unitID), tostring(reason)))
end

local function logFanout(pick)
	ns.Print("|cffffd200[fanout]|r req -> " .. tostring(pick))
end

local function logChunk(direction, medium, peer, bytes)
	ns.Print(("|cff8888ff[chunk]|r %s %s %s (%dB)"):format(
		direction, tostring(medium), tostring(peer or ""), bytes
	))
end

local function logPeer(text)
	ns.Print("|cff66ccff[peers]|r " .. text)
end

-- [ns.* hook name] = { category, implementation }
local HOOKS = {
	debugReceive   = { "receive",   logReceive },
	debugStore     = { "cache",     logStore },
	debugReceived  = { "queue",     logReceived },
	debugSkip      = { "queue",     logSkip },
	debugFanout    = { "fanout",    logFanout },
	debugChunk     = { "chunks",    logChunk },
	debugPeer      = { "peers",     logPeer },
}

--- Install enabled log hooks onto ns, remove disabled ones, and refresh
-- the stats collector. Safe before saved variables load.
function ns.refreshDebugHooks()
	for name, hook in pairs(HOOKS) do
		ns[name] = ns.debugEnabled(hook[1]) and hook[2] or nil
	end
	if ns.applyStatsHooks then
		ns.applyStatsHooks()
	end
end

-- Apply once saved variables are ready (Core's ADDON_LOADED handler is
-- registered first, so ns.db is already populated/normalised here).
ns.RegisterEvent("ADDON_LOADED", function(_, loaded)
	if loaded == ns.name then
		ns.refreshDebugHooks()
	end
end)

local function mapSize(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

-- /factionrp purge ----------------------------------------------------------

ns.RegisterCommand("purge", function()
	local n = ns.cache and ns.cache:clear() or 0
	ns.Print("cache purged (" .. n .. " entries dropped)")
end, "Empty the profile cache (testing)")

-- /factionrp debug [category|all|target] -------------------------------------

local function handleTarget(arg)
	arg = arg and ns.Util.trim(arg) or ""
	if arg == "" then
		local names = {}
		for _, name in pairs(ns.broadcast and ns.broadcast.forcedTargets or {}) do
			names[#names + 1] = name
		end
		ns.Print(#names > 0 and ("pinned targets: " .. table.concat(names, ", ")) or "no pinned targets")
	elseif arg:lower() == "clear" then
		local n = ns.broadcast and ns.broadcast:clearForcedTargets() or 0
		ns.Print("cleared " .. n .. " pinned target(s)")
	else
		local name = ns.broadcast and ns.broadcast:forceTarget(arg)
		ns.Print(name and ("pinned target: " .. name) or ("could not parse name: " .. arg))
	end
end

local function flagText(on)
	return on and "|cff33ff66on|r" or "|cffff5555off|r"
end

--- Print the current state of every debug category plus the `all` override.
local function printFlags()
	local d = ns.db.debug
	ns.Print("debug flags (" .. flagText(d.all) .. " = all):")
	for _, cat in ipairs(C.DEBUG_CATEGORIES) do
		ns.Print(("  %s: %s - %s"):format(cat.key, flagText(d.all or d[cat]), cat.desc))
	end
end

local function setFlag(key, on)
	-- write every flag when toggling `all`.
	if key == "all" then
		for _, cat in ipairs(C.DEBUG_CATEGORIES) do
			ns.db.debug[cat.key] = on
		end
	elseif ns.db.debug.all then
		for _, cat in ipairs(C.DEBUG_CATEGORIES) do
			ns.db.debug[cat.key] = true
		end
		ns.db.debug.all = false
	end
	ns.db.debug[key] = on
	ns.refreshDebugHooks()
	ns.Print(("debug |cff66ccff%s|r %s"):format(key, flagText(ns.db.debug[key])))
end

ns.RegisterCommand("debug", function(arg)
	if not ns.db then
		return
	end
	local sub, rest = (arg or ""):match("^(%S*)%s*(.-)$")
	sub = sub:lower()
	if sub == "target" then
		handleTarget(rest)
		return
	end
	if sub == "" then
		printFlags()
		return
	end
	if sub == "all" then
		rest = ns.Util.trim(rest or ""):lower()
		local on = (rest == "") and not ns.db.debug.all or (rest == "on" or rest == "true" or rest == "1")
		setFlag("all", on)
		return
	end
	for _, cat in ipairs(C.DEBUG_CATEGORIES) do
		if cat.key == sub then
			setFlag(sub, not ns.db.debug[sub])
			return
		end
	end
	ns.Print("unknown debug category '" .. sub .. "'; valid: all, " .. table.concat((function()
		local keys = {}
		for _, cat in ipairs(C.DEBUG_CATEGORIES) do
			keys[#keys + 1] = cat.key
		end
		return keys
	end)(), ", ") .. ", target")
end, "List debug flags; '<category>' toggles one, 'all' toggles all, 'target <name>' pins a whisper test target")

-- /factionrp relays ----------------------------------------------------------

local function joined(t)
	return #t > 0 and table.concat(t, ", ") or "none"
end

local function mapNames(t)
	local names = {}
	for _, v in pairs(t or {}) do
		names[#names + 1] = v
	end
	table.sort(names)
	return names
end

--- Show confirmed FRP relays, proven xfac contacts, roster candidates,
-- and pipeline state.
ns.RegisterCommand("relays", function()
	local b = ns.broadcast
	if not b then
		return
	end
	local now = GetTime()
	local conf, probing, ignored = {}, {}, 0
	for _, p in pairs(b.relays or {}) do
		local tag
		if ns.Util.isCommunityClubMember(p.name) then
			tag = ns.Util.isGuildClubMember(p.name) and " [C+G]" or " [C]"
		elseif ns.Util.isGuildClubMember(p.name) then
			tag = " [G]"
		else
			tag = " [?]" -- in neither club's current roster (left / stale)
		end
		if p.ign ~= 0 then
			ignored = ignored + 1
		elseif p.conf ~= 0 and (now - p.conf) < C.RELAY_CONFIRM_TTL then
			conf[#conf + 1] = p.name .. tag
		elseif p.pr > 0 then
			probing[#probing + 1] = p.name .. tag
		end
	end
	ns.Print("known relays (confirmed FRP): " .. joined(conf))
	ns.Print(("relay probes | probing: %s | ignored: %d"):format(joined(probing), ignored))
	ns.Print("xfac contacts (reachable, unconfirmed): " .. joined(mapNames(b.xfacContacts)))
	ns.Print(("roster candidates: %d community / %d guild"):format(
		#ns.Util.xfacClubMembers(), #ns.Util.xfacGuildMembers()))
	-- Raw membership counts (all factions): distinguishes "club never
	-- scanned" (0) from "scanned, none xfac" (>0 while candidates stay 0).
	local r = ns.Util._roster and ns.Util._roster()
	if r then
		ns.Print(("roster membership | community: %d | guild: %d | built %s"):format(
			mapSize(r.communityByName), mapSize(r.guildByName),
			r.at and r.at ~= 0 and (math.floor(GetTime() - r.at) .. "s ago") or "never"))
		local st = ns.Util._rosterState and ns.Util._rosterState()
		if st then
			ns.Print(("roster build | building: %s | club %d/%d | parked %d | retry in %ds | suspect %d"):format(
				tostring(st.building), st.club, st.clubs, st.parked,
				math.floor(st.retryIn), st.suspect))
		end
	end
	local lists = ns.comms and ns.comms:bnetPeerLists() or { confirmed = {}, probing = {}, ignored = {} }
	-- Resolve BNet account ids to character names where the API allows.
	local function bnetName(id)
		local ok, info = pcall(C_BattleNet.GetGameAccountInfoByID, id)
		local char = ok and ns.Util.fieldsUsable(info, "characterName", "realmName")
			and info.characterName
		if char and char ~= "" then
			local realm = info.realmName
			return (realm and realm ~= "") and (char .. "-" .. realm) or char
		end
		return tostring(id)
	end
	local bnetConf, bnetProb, bnetIgn = {}, {}, {}
	for _, id in ipairs(lists.confirmed) do
		bnetConf[#bnetConf + 1] = bnetName(id)
	end
	for _, id in ipairs(lists.probing) do
		bnetProb[#bnetProb + 1] = bnetName(id)
	end
	for _, id in ipairs(lists.ignored) do
		bnetIgn[#bnetIgn + 1] = bnetName(id)
	end
	ns.Print(("bnet peers | confirmed: %s | probing: %s | ignored: %s"):format(
		joined(bnetConf), joined(bnetProb), joined(bnetIgn)))
	local mute = ""
	if b.serveDrainPos and b:serveDraining(GetTime()) then
		mute = " | serving"
	elseif b.serveMuteUntil and GetTime() < b.serveMuteUntil then
		mute = (" | serve muted %ds"):format(math.ceil(b.serveMuteUntil - GetTime()))
	end
	ns.Print(("exchange | pending requests: %d | queued: %d | pending serves: %d | sends in flight: %d%s"):format(
		mapSize(b.requests or {}),
		b.reqQueueOrder and math.max(0, b.reqQueueOrder.tail - b.reqQueueOrder.head + 1) or 0,
		mapSize(b.pendingServes or {}),
		b.fanoutsInFlight and b:fanoutsInFlight() or 0, mute))
	ns.Print(("contact cursor: %d | pinned targets: %d"):format(
		b.contactIdx or 0, mapSize(b.forcedTargets or {})))
end, "Show learned relays/contacts and the pull pipeline state")

-- Richer status command (overrides the placeholder registered in Core).
ns.RegisterCommand("status", function()
	local adapter = ns.getAvailableAdapter()
	local relays = ns.broadcast and mapSize(ns.broadcast.relays) or 0
	local contacts = ns.broadcast and mapSize(ns.broadcast.xfacContacts) or 0
	local enabledCats = {}
	local d = ns.db and ns.db.debug
	if d and d.all then
		enabledCats[1] = "all"
	elseif d then
		for _, cat in ipairs(C.DEBUG_CATEGORIES) do
			if d[cat.key] then
				enabledCats[#enabledCats + 1] = cat.key
			end
		end
	end
	ns.Print(("version %s | cache: %d | pending: %d | send queue: %d | relays: %d | contacts: %d | RP adapter: %s | debug: %s | latest announced peer version: %s"):format(
		C.VERSION,
		ns.cache and ns.cache:count() or 0,
		ns.scanner and #ns.scanner.receivedQueue or 0,
		ns.comms and ns.comms:queueDepth() or 0,
		relays,
		contacts,
		adapter and adapter.name or "|cffff5555none|r",
		#enabledCats > 0 and table.concat(enabledCats, ",") or "off",
		ns.broadcast and ns.broadcast.topPeerVersion or "none"
	))
end, "Show version, cache size, pending sends, adapter and debug state")
