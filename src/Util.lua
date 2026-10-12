-- Util.lua
--
-- Small, pure helper functions shared across modules. Nothing here touches
-- AddOn state; everything is a stateless utility.

local _, ns = ...
local C = ns.Const

local Util = {}
ns.Util = Util

--- A tiny table pool: `acquire` returns a wiped reusable table (or a fresh one
-- when the pool is empty), `release` returns a table to the pool, and `size`
-- reports pooled count.
-- @param cap number Maximum tables retained in the pool.
-- @return acquire, release, size
function Util.newPool(cap)
	local pool, n = {}, 0
	return function()
		if n > 0 then
			local t = pool[n]
			pool[n] = nil
			n = n - 1
			return wipe(t)
		end
		return {}
	end, function(t)
		if n < cap then
			n = n + 1
			pool[n] = t
		end
	end, function()
		return n
	end
end

--- Trim leading/trailing whitespace.
-- @param s string
-- @return string
function Util.trim(s)
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--- Build the "Name-Realm" identifier for a unit, matching the convention used
-- by RP AddOns for keying their character store.
--
-- NOTE: realm names are normalized by stripping spaces (e.g. "Argent Dawn" ->
-- "ArgentDawn"). The TRP3 adapter prefers TRP3's own unit-id helper when
-- available (see TRP3Adapter) so register keys match exactly; this generic
-- version is the fallback used for our own bookkeeping.
-- @param unit string A unit token (e.g. "mouseover", "target", "player").
-- @return string|nil "Name-Realm", or nil if the unit is not a player.
function Util.getUnitID(unit)
	if not UnitIsPlayer(unit) then
		return nil
	end
	local name, realm = UnitName(unit)
	if not name or name == "" then
		return nil
	end
	if not realm or realm == "" then
		realm = GetNormalizedRealmName()
	else
		realm = realm:gsub("%s+", "")
	end
	return name .. "-" .. realm
end

--- Whether `unit` is a player belonging to the faction opposite the viewer.
-- @param unit string A unit token.
-- @return boolean
function Util.isOppositeFaction(unit)
	if not UnitIsPlayer(unit) then
		return false
	end
	local theirs = UnitFactionGroup(unit)
	local mine = UnitFactionGroup("player")
	-- UnitFactionGroup returns "Alliance"/"Horde"/"Neutral"/nil. Treat any
	-- mismatch between two known, differing groups as opposite faction.
	return theirs ~= nil and mine ~= nil and theirs ~= mine
end

-- GUID resolution -----------------------------------------------------------
--
-- The wire format and cache key profiles by the subject's real GUID, but
-- profiles received over the RP AddOn's comm channels arrive keyed only by
-- "Name-Realm". resolveGUID is a best-effort, name-based lookup over every
-- source that can map a character name to a GUID: nearby unit tokens,
-- Battle.net friends, and WoW community/club rosters.

-- Unit tokens that can refer to other players near enough to have a GUID.
local GUID_UNIT_TOKENS = { "target", "targettarget", "mouseover", "focus", "softenemy" }
for i = 1, MAX_PARTY_MEMBERS or 4 do
	GUID_UNIT_TOKENS[#GUID_UNIT_TOKENS + 1] = "party" .. i
end
for i = 1, MAX_RAID_MEMBERS or 40 do
	GUID_UNIT_TOKENS[#GUID_UNIT_TOKENS + 1] = "raid" .. i
end
for i = 1, 40 do
	GUID_UNIT_TOKENS[#GUID_UNIT_TOKENS + 1] = "nameplate" .. i
end
for i = 1, 5 do
	GUID_UNIT_TOKENS[#GUID_UNIT_TOKENS + 1] = "arena" .. i
end

--- Normalize a character name to "Name-Realm" for comparison: strips spaces
-- from the realm (matching getUnitID) and defaults a missing realm to the
-- local realm.
-- @param name string "Name" or "Name-Realm".
-- @return string|nil
local function normalizeUnitName(name)
	if not name or name == "" then
		return nil
	end
	local char, realm = name:match("^([^-]+)-?(.*)$")
	if not char or char == "" then
		return nil
	end
	if not realm or realm == "" then
		realm = GetNormalizedRealmName() or ""
	else
		realm = realm:gsub("%s+", "")
	end
	return (char .. "-" .. realm):lower()
end
Util.normalizeUnitName = normalizeUnitName

--- Same normalization as normalizeUnitName but preserving case: produces the
--- "Name-Realm" form suitable for a whisper target.
local function fullUnitName(name)
	if not name or name == "" then
		return nil
	end
	local char, realm = name:match("^([^-]+)-?(.*)$")
	if not char or char == "" then
		return nil
	end
	if not realm or realm == "" then
		realm = GetNormalizedRealmName() or ""
	else
		realm = realm:gsub("%s+", "")
	end
	return char .. "-" .. realm
end
Util.fullUnitName = fullUnitName

-- Community roster ----------------------------------------------------------
--
-- Members of our own subscribed WoW communities are the one group of
-- opposite-faction players we can reach directly: addon whispers work between
-- community members across factions, and ClubMemberInfo exposes a NeverSecret
-- `faction` field we can filter on. The roster also doubles as the name->GUID
-- map for resolveGUID's club fallback.
--
-- A full scan is O(total club membership) — too much for one frame on large
-- communities — so a stale roster is rebuilt incrementally: ROSTER_SLICE
-- member lookups per frame via self-rescheduling timers, then the memo is
-- swapped atomically. Callers always see the last complete roster (possibly
-- stale or, before the first build finishes, empty); lookups during a build
-- degrade to graceful misses.

-- ClubMemberPresence values that mean the character is logged in (1 Online,
-- 4 Away, 5 Busy). OnlineMobile (2) is the phone app and cannot receive addon
-- messages; Unknown (0) and Offline (3) are useless targets.
local PRESENCE_ONLINE = { [1] = true, [4] = true, [5] = true }

local function rosterTables()
	return {
		xfac = {},          -- online opposite-faction community members (names)
		xfacGuild = {},     -- online opposite-faction guild members (names)
		factionByName = {}, -- normalized name -> PvPFaction (may be nil)
		guidByName = {},    -- normalized name -> GUID
		nameByGuid = {},    -- GUID -> display "Name-Realm" (request serving)
		guildByName = {},   -- normalized name -> true (guild members)
		communityByName = {} -- normalized name -> true (community members)
	}
end

-- Two persistent table-sets: builds write into rosterBack while readers keep
-- rosterFront; finishing a build swaps them atomically. This keeps the every-
-- COMM_ROSTER_MEMO rebuild from re-allocating O(roster size) of tables.
local rosterFront = rosterTables()
rosterFront.at = 0
local rosterBack = rosterTables()
local rosterBuild = nil -- incremental build state, or nil when idle
local rebuildRetryAt = 0  -- no rebuild before this time (suspect-build retry)
-- Per-build dedup scratch, persistent and wiped at each build start.
local buildSeenXfac, buildSeenGuild = {}, {}

-- ClubMemberInfo.faction is a PvPFaction (0 = Horde, 1 = Alliance, NeverSecret).
local function selfFaction()
	return (UnitFactionGroup("player") == "Alliance") and 1 or 0
end

local function finishRosterBuild(build)
	-- A build that collected GUIDs but saw no faction data likely raced the
	-- member-info stream (faction arrives lazily). Publishing it would give
	-- the whisper legs an empty roster for a whole memo window, so keep the
	-- old roster and retry shortly instead.
	if not build.sawFaction and next(build.target.guidByName) then
		rebuildRetryAt = GetTime() + C.ROSTER_RETRY
		rosterBuild = nil
		return
	end
	-- The build wrote into the back buffer; publish it by swapping buffers.
	rosterBack.at = GetTime()
	rosterFront, rosterBack = rosterBack, rosterFront
	rosterBuild = nil
end

-- Forward declaration: stepRosterBuild reschedules via stepCurrentBuild,
-- which in turn calls stepRosterBuild.
local stepCurrentBuild

-- Process up to ROSTER_SLICE member lookups, then reschedule for the next
-- frame. On completion the accumulated tables replace the memo atomically.
local function stepRosterBuild(build)
	if build ~= rosterBuild then
		return -- superseded
	end
	local budget = C.ROSTER_SLICE
	while budget > 0 do
		local club = build.clubs[build.c]
		if not club then
			finishRosterBuild(build)
			return
		end
		if not build.members then
			local ok, members = pcall(C_Club.GetClubMembers, club.id)
			build.members = (ok and type(members) == "table") and members or {}
			build.m = 1
		end
		local memberId = build.members[build.m]
		if not memberId then
			build.members = nil
			build.c = build.c + 1
		else
			build.m = build.m + 1
			budget = budget - 1
			-- Club APIs can fail before init or yield secrets during lockdown.
			local okInfo, info = pcall(C_Club.GetMemberInfo, club.id, memberId)
			if okInfo and info and not info.isSelf and info.name and canaccessvalue(info.name) then
				local key = normalizeUnitName(info.name)
				if key then
					local t = build.target
					if info.faction ~= nil then
						build.sawFaction = true
					end
					t.factionByName[key] = info.faction -- may be nil
					if club.guild then
						t.guildByName[key] = true
					else
						t.communityByName[key] = true
					end
					if info.guid and canaccessvalue(info.guid) then
						t.guidByName[key] = info.guid
						t.nameByGuid[info.guid] = fullUnitName(info.name)
						if info.faction ~= nil
							and info.faction ~= selfFaction()
							and PRESENCE_ONLINE[info.presence]
						then
							-- Dedup per leg: a member in the guild AND a
							-- community is a candidate in both lists.
							local list = club.guild and t.xfacGuild or t.xfac
							local seen = club.guild and buildSeenGuild or buildSeenXfac
							if not seen[info.guid] then
								seen[info.guid] = true
								list[#list + 1] = fullUnitName(info.name)
							end
						end
					end
				end
			end
		end
	end
	C_Timer.After(0, stepCurrentBuild)
end

-- Hoisted reschedule closure: reads the current build so the timer allocates
-- nothing per slice.
stepCurrentBuild = function()
	if rosterBuild then
		stepRosterBuild(rosterBuild)
	end
end

local function startRosterBuild()
	if not C_Club or not C_Club.GetSubscribedClubs or not C_Club.GetClubMembers then
		return
	end
	-- Club APIs can fail before clubs are initialized or during lockdown.
	-- Member info streams in lazily after login; build only once the client
	-- reports clubs fully loaded (the sawFaction check in finishRosterBuild
	-- is the backstop for clients where this API is absent or wrong).
	if C_Club.ClubsHaveBeenLoaded and not C_Club.ClubsHaveBeenLoaded() then
		return
	end
	local ok, clubs = pcall(C_Club.GetSubscribedClubs)
	if not ok or type(clubs) ~= "table" then
		return
	end
	-- Our own guild is a club too (C_Club.GetGuildClubId) and gets the same
	-- coverage — cross-faction guilds make its opposite-faction members
	-- whisper-reachable. It is kept as a separate target list.
	local list = {}
	for _, club in ipairs(clubs) do
		local isGuild = Enum and Enum.ClubType and club.clubType == Enum.ClubType.Guild
		list[#list + 1] = { id = club.clubId, guild = isGuild or nil }
	end
	local okGuild, guildClubId = pcall(C_Club.GetGuildClubId)
	if okGuild and guildClubId then
		local found = false
		for _, club in ipairs(list) do
			if club.id == guildClubId then
				club.guild = true
				found = true
				break
			end
		end
		if not found then
			list[#list + 1] = { id = guildClubId, guild = true }
		end
	end
	-- Rebuild into the back buffer (wiped); readers keep the front until swap.
	local back = rosterBack
	wipe(back.xfac)
	wipe(back.xfacGuild)
	wipe(back.factionByName)
	wipe(back.guidByName)
	wipe(back.nameByGuid)
	wipe(back.guildByName)
	wipe(back.communityByName)
	wipe(buildSeenXfac)
	wipe(buildSeenGuild)
	rosterBuild = {
		clubs = list, c = 1, m = 1, members = nil, target = back,
	}
	stepRosterBuild(rosterBuild)
end

local function clubRoster()
	if not rosterBuild
		and GetTime() >= rebuildRetryAt
		and (GetTime() - rosterFront.at) > C.COMM_ROSTER_MEMO
	then
		startRosterBuild()
	end
	return rosterFront
end

--- Online, opposite-faction members of our subscribed clubs — the players we
--- can reach with a cross-faction addon whisper.
-- @return table List of "Name-Realm" strings, deduplicated by GUID.
function Util.xfacClubMembers()
	return clubRoster().xfac
end

--- Whether a "Name-Realm" belongs to an opposite-faction member of one of our
--- clubs, per the roster's NeverSecret faction field.
function Util.isXfacClubMember(unitID)
	local key = normalizeUnitName(unitID)
	local faction = key and clubRoster().factionByName[key]
	return faction ~= nil and faction ~= selfFaction()
end

--- Online, opposite-faction members of our own guild — the players we can
--- reach with a cross-faction addon whisper (cross-faction guilds).
-- @return table List of "Name-Realm" strings, deduplicated by GUID.
function Util.xfacGuildMembers()
	return clubRoster().xfacGuild
end

--- Whether a "Name-Realm" is a member of our guild (per the roster memo).
function Util.isGuildClubMember(unitID)
	local key = normalizeUnitName(unitID)
	return key ~= nil and clubRoster().guildByName[key] == true
end

--- Whether a "Name-Realm" is a member of one of our (non-guild) communities.
function Util.isCommunityClubMember(unitID)
	local key = normalizeUnitName(unitID)
	return key ~= nil and clubRoster().communityByName[key] == true
end

--- Reverse lookup: the display "Name-Realm" of a club member by GUID, or nil.
-- Used to resolve request subjects to extractable unit IDs.
function Util.unitForGuid(guid)
	return guid and clubRoster().nameByGuid[guid] or nil
end

local function guidFromUnits(unitID)
	for _, token in ipairs(GUID_UNIT_TOKENS) do
		-- Unit APIs may yield secret values during lockdown; skip those.
		local ok, guid = pcall(UnitGUID, token)
		if ok and guid and not issecretvalue(guid) then
			local okID, id = pcall(Util.getUnitID, token)
			if okID and id and id:lower() == unitID then
				return guid
			end
		end
	end
end

local function guidFromBNetFriends(unitID)
	if BNFeaturesEnabledAndConnected and not BNFeaturesEnabledAndConnected() then
		return
	end
	if not C_BattleNet then
		return
	end
	local numFriends = BNGetNumFriends() or 0
	for i = 1, numFriends do
		local numAccounts = C_BattleNet.GetFriendNumGameAccounts(i) or 0
		for j = 1, numAccounts do
			local acct = C_BattleNet.GetFriendGameAccountInfo(i, j)
			if acct
				and acct.clientProgram == BNET_CLIENT_WOW
				and acct.characterName
				and acct.realmName
				and acct.playerGuid
				and normalizeUnitName(acct.characterName .. "-" .. acct.realmName) == unitID
			then
				return acct.playerGuid
			end
		end
	end
end

local function guidFromClubs(unitID)
	-- Shares the (memoized, incrementally-built) community roster rather than
	-- walking every club member itself.
	return clubRoster().guidByName[unitID]
end

local guidMemo = {} -- [lowered unitID] = { guid = guid|false, expires = GetTime() }
local memoPruneCounter = 0

--- Best-effort resolution of a "Name-Realm" unitID to a real player GUID.
-- Results (including misses) are memoized for C.GUID_RESOLVE_MEMO seconds.
-- @param unitID string "Name-Realm".
-- @return string|nil The GUID, or nil if it cannot be resolved.
function Util.resolveGUID(unitID)
	if not unitID then
		return nil
	end
	local key = unitID:lower()
	local now = GetTime()
	local memo = guidMemo[key]
	if memo and memo.expires > now then
		return memo.guid or nil
	end

	local guid = guidFromUnits(key)
		or guidFromBNetFriends(key)
		or guidFromClubs(key)

	-- Periodically prune expired memos so the table cannot grow unbounded
	-- over a long session.
	memoPruneCounter = memoPruneCounter + 1
	if memoPruneCounter >= 50 then
		memoPruneCounter = 0
		for k, m in pairs(guidMemo) do
			if m.expires <= now then
				guidMemo[k] = nil
			end
		end
	end

	if not guid and rosterBuild then
		-- The roster is mid-rebuild: this miss may resolve once it finishes,
		-- so do not memoize it as a negative result.
		return nil
	end
	if not memo then
		memo = {}
		guidMemo[key] = memo
	end
	memo.guid = guid or false
	memo.expires = now + C.GUID_RESOLVE_MEMO
	return guid
end

-- Diagnostics accessors for "/frp mem census" (read-only views of internals).
function Util._roster()
	return clubRoster()
end

function Util._guidMemo()
	return guidMemo
end
