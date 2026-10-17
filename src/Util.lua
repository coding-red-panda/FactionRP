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

local REALM_STRIP = "[%s%-%.]+"

function Util.getUnitID(unit)
	if not Util.canWeUse(unit) then
		return nil
	end
	-- The token checks out, but the results themselves can still be secret.
	local isPlayer = UnitIsPlayer(unit)
	local name, realm = UnitName(unit)
	if not Util.canWeUse(isPlayer, name, realm)
		or not isPlayer or not name or name == ""
	then
		return nil
	end
	if not realm or realm == "" then
		realm = GetNormalizedRealmName()
		if not Util.canWeUse(realm) then
			return nil
		end
	else
		realm = realm:gsub(REALM_STRIP, "")
	end
	-- Issue #26: GetNormalizedRealmName() can hand back nil while the client is
	-- mid-transition (entering a follower dungeon), and canWeUse(nil) is true —
	-- nil is accessible, merely absent — so the secrecy guard above cannot catch
	-- it. Refuse an unusable realm instead of concatenating it: every caller
	-- already treats a nil result as "unit not identified".
	if type(realm) ~= "string" or realm == "" then
		return nil
	end
	return name .. "-" .. realm
end

--- Whether `unit` is a player belonging to the faction opposite the viewer.
-- @param unit string A unit token.
-- @return boolean
function Util.isOppositeFaction(unit)
	if not Util.canWeUse(unit) then
		return false
	end
	local isPlayer = UnitIsPlayer(unit)
	local theirs = UnitFactionGroup(unit)
	local mine = UnitFactionGroup("player")
	if not Util.canWeUse(isPlayer, theirs, mine) or not isPlayer then
		return false
	end
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
	if not Util.canWeUse(name) or not name or name == "" then
		return nil
	end
	local char, realm = name:match("^([^-]+)-?(.*)$")
	if not char or char == "" then
		return nil
	end
	if not realm or realm == "" then
		realm = GetNormalizedRealmName() or ""
	else
		realm = realm:gsub(REALM_STRIP, "")
	end
	return (char .. "-" .. realm):lower()
end
Util.normalizeUnitName = normalizeUnitName

--- Same normalization as normalizeUnitName but preserving case: produces the
--- "Name-Realm" form suitable for a whisper target.
local function fullUnitName(name)
	if not Util.canWeUse(name) or not name or name == "" then
		return nil
	end
	local char, realm = name:match("^([^-]+)-?(.*)$")
	if not char or char == "" then
		return nil
	end
	if not realm or realm == "" then
		realm = GetNormalizedRealmName() or ""
	else
		realm = realm:gsub(REALM_STRIP, "")
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
		communityByName = {}, -- normalized name -> true (community members)
		onlineByName = {},  -- normalized name -> true (logged-in members)
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
-- Consecutive builds discarded by the suspect-faction guard; capped so a
-- client that never populates `faction` does not retry the build forever.
local suspectBuilds = 0

-- ClubMemberInfo.faction is a PvPFaction (0 = Horde, 1 = Alliance, NeverSecret).
local function selfFaction()
	local f = UnitFactionGroup("player")
	return Util.canWeUse(f) and f == "Alliance" and 1 or 0
end

-- raceID -> PvPFaction, memoized: race determines faction unambiguously
-- (dual-faction races use distinct raceIDs). Sole faction source —
-- ClubMemberInfo.faction arrives absent on the current client.
local raceFaction = {}
local function factionFromRace(race)
	if type(race) ~= "number" or not Util.canWeUse(race) then
		return nil
	end
	local f = raceFaction[race]
	if f == nil then
		local info = C_CreatureInfo and C_CreatureInfo.GetFactionInfo
			and C_CreatureInfo.GetFactionInfo(race)
		local tag = type(info) == "table" and Util.canWeUse(info.groupTag)
			and info.groupTag
		f = (tag == "Alliance") and 1 or (tag == "Horde") and 0 or false
		raceFaction[race] = f
	end
	return f ~= false and f or nil
end

local function mapCount(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

local function finishRosterBuild(build)
	-- A build that collected GUIDs but saw no faction data likely raced the
	-- member-info stream (faction arrives lazily). Publishing it would give
	-- the whisper legs an empty roster for a whole memo window, so keep the
	-- old roster and retry shortly instead.
	if not build.sawFaction and next(build.target.guidByName) then
		suspectBuilds = suspectBuilds + 1
		if suspectBuilds < 3 then
			rebuildRetryAt = GetTime() + C.ROSTER_RETRY
			rosterBuild = nil
			if ns.debugPeer then
				ns.debugPeer("roster build suspect (guids but no factions) — retrying")
			end
			return
		end
		if ns.debugPeer then
			ns.debugPeer("roster build suspect — publishing anyway (no faction data)")
		end
	end
	-- Deferred members (online, faction unknown at their scan point): classify
	-- now that every club's faction claims are accumulated.
	for _, d in ipairs(build.deferred) do
		local f = build.target.factionByName[d.key]
		if f ~= nil and f ~= selfFaction() then
			local list = d.guild and build.target.xfacGuild or build.target.xfac
			local seen = d.guild and buildSeenGuild or buildSeenXfac
			local dk = d.guid or d.key
			if not seen[dk] then
				seen[dk] = true
				list[#list + 1] = d.name
			end
		end
	end
	-- The build wrote into the back buffer; publish it by swapping buffers.
	rosterBack.at = GetTime()
	rosterFront, rosterBack = rosterBack, rosterFront
	rosterBuild = nil
	suspectBuilds = 0
	if ns.debugPeer then
		ns.debugPeer(("roster published: %d guild / %d community / %d xfac"):format(
			mapCount(rosterFront.guildByName),
			mapCount(rosterFront.communityByName),
			#rosterFront.xfac + #rosterFront.xfacGuild))
	end
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
			if ok and not Util.canWeUse(members) then
				rebuildRetryAt = GetTime() + C.ROSTER_RETRY
				rosterBuild = nil
				if ns.debugPeer then
					ns.debugPeer("roster build aborted: secret members (club "
						.. tostring(club.id) .. ")")
				end
				return
			end
			build.members = (ok and type(members) == "table") and members or {}
			build.m = 1
			if ns.debugPeer then
				ns.debugPeer("roster club " .. tostring(club.id) .. " -> "
					.. #build.members .. " members")
			end
		end
		local memberId = build.members[build.m]
		if not Util.canWeUse(memberId) then
			-- Sporadically secret element: skip the member, keep building.
			build.m = build.m + 1
			budget = budget - 1
		elseif not memberId then
			build.members = nil
			build.c = build.c + 1
		else
			build.m = build.m + 1
			budget = budget - 1
			local okInfo, info = pcall(C_Club.GetMemberInfo, club.id, memberId)
			if okInfo and Util.fieldsUsable(info, "isSelf", "name", "guid", "presence")
				and not info.isSelf and info.name then
				local key = normalizeUnitName(info.name)
				if key then
					local t = build.target
					local faction = factionFromRace(info.race)
					if faction ~= nil then
						build.sawFaction = true
						t.factionByName[key] = faction
					end
					if club.guild then
						t.guildByName[key] = true
					else
						t.communityByName[key] = true
					end
					if info.guid then
						t.guidByName[key] = info.guid
						t.nameByGuid[info.guid] = fullUnitName(info.name)
					end
					if PRESENCE_ONLINE[info.presence] then
						t.onlineByName[key] = true
						-- A member's faction can be absent on *this* club's
						-- record (race doesn't always populate): any club's
						-- claim counts. Still-unknown members defer to
						-- end-of-build so a later club's record can supply it.
						local faction = t.factionByName[key]
						if faction ~= nil and faction ~= selfFaction() then
							-- Dedup per leg: a member in the guild AND a
							-- community is a candidate in both lists.
							local list = club.guild and t.xfacGuild or t.xfac
							local seen = club.guild and buildSeenGuild or buildSeenXfac
							local dk = info.guid or key
							if not seen[dk] then
								seen[dk] = true
								list[#list + 1] = fullUnitName(info.name)
							end
						elseif faction == nil then
							build.deferred[#build.deferred + 1] = {
								key = key, guid = info.guid,
								name = fullUnitName(info.name),
								guild = club.guild == true,
							}
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
	if not ok or type(clubs) ~= "table" or not Util.canWeUse(clubs) then
		if ns.debugPeer then
			ns.debugPeer("roster build skipped: GetSubscribedClubs "
				.. (not ok and "failed" or "unusable"))
		end
		return
	end
	-- Our own guild is a club too (C_Club.GetGuildClubId) and gets the same
	-- coverage — cross-faction guilds make its opposite-faction members
	-- whisper-reachable. It is kept as a separate target list.
	local list = {}
	for _, club in ipairs(clubs) do
		if Util.fieldsUsable(club, "clubId", "clubType") then
			local isGuild = Enum and Enum.ClubType and club.clubType == Enum.ClubType.Guild
			list[#list + 1] = { id = club.clubId, guild = isGuild or nil }
		end
	end
	local okGuild, guildClubId = pcall(C_Club.GetGuildClubId)
	if ns.debugPeer then
		ns.debugPeer("roster clubs: " .. #list .. " subscribed, guild club "
			.. tostring(okGuild and guildClubId or nil))
	end
	if okGuild and Util.canWeUse(guildClubId) and guildClubId then
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
	wipe(back.onlineByName)
	wipe(buildSeenXfac)
	wipe(buildSeenGuild)
	rosterBuild = {
		clubs = list, c = 1, m = 1, members = nil, target = back,
		deferred = {},
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

--- Whether a "Name-Realm" is a club member currently logged in (per the
-- roster memo's presence field — mobile-app presences count as offline).
function Util.isClubMemberOnline(unitID)
	local key = normalizeUnitName(unitID)
	return key ~= nil and clubRoster().onlineByName[key] == true
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

--- Reverse lookup via the client's own player-info cache
-- (GetPlayerInfoByGUID -> name + normalizedRealmName).
-- @param guid string
-- @return string|nil "Name-Realm", or nil if the GUID is unknown to the client.
function Util.unitForGuidFromClient(guid)
	if not guid or not GetPlayerInfoByGUID then
		return nil
	end
	-- May fail outright or yield secret values during lockdown.
	local ok, _, _, _, _, _, name, realm = pcall(GetPlayerInfoByGUID, guid)
	if not ok or not Util.canWeUse(name, realm)
		or not name or name == ""
	then
		return nil
	end
	return fullUnitName((realm and realm ~= "") and (name .. "-" .. realm) or name)
end

local function guidFromUnits(unitID)
	for _, token in ipairs(GUID_UNIT_TOKENS) do
		-- Unit APIs may yield secret values during lockdown; skip those.
		local ok, guid = pcall(UnitGUID, token)
		if ok and Util.canWeUse(guid) and guid then
			local okID, id = pcall(Util.getUnitID, token)
			if okID and Util.canWeUse(id) and id and id:lower() == unitID then
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
	local numFriends = BNGetNumFriends()
	if not Util.canWeUse(numFriends) then
		return
	end
	for i = 1, numFriends or 0 do
		local numAccounts = C_BattleNet.GetFriendNumGameAccounts(i)
		if Util.canWeUse(numAccounts) then
			for j = 1, numAccounts or 0 do
				local acct = C_BattleNet.GetFriendGameAccountInfo(i, j)
				if Util.fieldsUsable(acct, "clientProgram", "characterName", "realmName", "playerGuid")
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

--- Retarget FRP messages still queued in CTL after channel reorder,
--- so that the queue sends to the correct channel.
function Util.fixChompChannelTargets(channelInx)
	if type(channelInx) ~= "number" or channelInx == 0 then
		return
	end
	local debug = ns.debugEnabled("reorders")
	if debug then
		ns.Print("fixChompChannelTargets, index: " .. channelInx)
	end
	local ctl = ChatThrottleLib
	if not ctl or type(ctl.Prio) ~= "table" then
		-- if it doesn't exist or if something corrupted ctl.Prio into a non-table,
		-- fuck off
		return
	end
	local rewritten = 0
	local currentId = {}
	local function findUniqueNums()
		local seen, out = {}, {}
		for i = 1, #currentId do
			local id = currentId[i]
			if id and not seen[id] then
				seen[id] = true
				out[#out + 1] = tostring(id)
			end
		end
		return table.concat(out, ", ")
	end
	-- Find FRP's messages in the pipeline and edit targets in place
	if debug then 
		ns.Print("Looping ctl.Prio")
	end
	for _, prio in pairs(ctl.Prio) do
		for _, pipe in pairs(prio.ByName or {}) do
			for i = 1, #pipe do
				local msg = pipe[i]
				if type(msg) == "table" and msg[1] == C.MSG_PREFIX and msg[3] == "CHANNEL" then
					rewritten = rewritten + 1
					if debug then
						currentId[#currentId + 1] =  msg[4] or 0
					end
					-- we still want to fix and send nils
					-- msg.n == 3 if channel was nil
					if msg.n == 3 then
						msg.n = 4
					end
					msg[4] = channelInx
				end
			end
		end
	end
	if rewritten > 0 and debug then
		ns.Print("Rewrote " .. rewritten .. " from channels " .. findUniqueNums() .. " to channel " .. channelInx)
	end
end

--- Compare two dot-separated version strings numerically ("0.3.2", "1.0",
-- "2"). Non-numeric suffixes are ignored, so "0.3.2-beta" compares as "0.3.2";
-- short versions pad with zeros ("1.0" == "1.0.0").
-- @param a string First version.
-- @param b string Second version.
-- @return number -1 when a < b, 1 when a > b, 0 when equal.
function Util.versionCompare(a, b)
	if a == b then
		return 0
	end
	local av, bv = {}, {}
	for part in a:gmatch("%d+") do
		av[#av + 1] = part
	end
	for part in b:gmatch("%d+") do
		bv[#bv + 1] = part
	end
	local n = math.max(#av, #bv)
	for i = 1, n do
		local x = tonumber(av[i]) or 0
		local y = tonumber(bv[i]) or 0
		if x < y then
			return -1
		elseif x > y then
			return 1
		end
	end
	return 0
end

--- Deterministic 32-bit hash of a string, as 8 hex chars. Used to compare
-- content versions on the wire without shipping the whole string.
-- @param s string
-- @return string
function Util.hashStr(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 4294967296
	end
	return ("%08x"):format(h)
end

--- False (+ index of the offender) if any supplied value is secret or
--- inaccessible. A table result only certifies that it can be indexed.
--- Fields could still be secret which is what we have Util.fieldsUsable() for.
function Util.canWeUse(...)
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if type(v) == "table" then
			if not canaccesstable(v) then
				return false, i
			end
		elseif not canaccessvalue(v) then
			return false, i
		end
	end
	return true
end

--- Check if supplied table is indexable and, if it is,
--- discover whether the supplied fields contain secrets.
function Util.fieldsUsable(t, ...)
	if type(t) ~= "table" or not canaccesstable(t) then
		return false
	end
	for i = 1, select("#", ...) do
		if not canaccessvalue(t[select(i, ...)]) then
			return false
		end
	end
	return true
end
