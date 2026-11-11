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
--- query for non-hook call sites (Broadcast's `targets` gate, Stats).
--- @param category string One of Const.DEBUG_CATEGORIES keys.
--- @return boolean
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

local function logAbout(event, requestID, detail)
--  tracing the "about" exchange
	ns.Print("|cff66ccff[about]|r " .. tostring(event)
		.. (requestID and (" [" .. tostring(requestID) .. "]") or "")
		.. (detail and (" | " .. tostring(detail)) or ""))
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
	debugAbout     = { "peers",     logAbout },
}

--- Install enabled log hooks onto ns, remove disabled ones, and refresh
--- the stats collector. Safe before saved variables load.
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
		-- Bare /frp debug opens the panel; flags toggle from there.
		ns.debugUI:toggle()
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
end, "Open the debug panel; '<category>' toggles one, 'all' toggles all, 'target <name>' pins a whisper test target")

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
		local gen = p.proto and (" g" .. p.proto) or ""
		if p.ign ~= 0 then
			ignored = ignored + 1
		elseif p.conf ~= 0 and (now - p.conf) < C.RELAY_CONFIRM_TTL then
			conf[#conf + 1] = p.name .. tag .. gen
		elseif p.pr > 0 then
			probing[#probing + 1] = p.name .. tag .. gen
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
	local function protoSuffix(id)
		local p = ns.comms and ns.comms.bnetPeers[id]
		return (p and p.proto) and (" g" .. p.proto) or ""
	end
	local bnetConf, bnetProb, bnetIgn = {}, {}, {}
	for _, id in ipairs(lists.confirmed) do
		bnetConf[#bnetConf + 1] = bnetName(id) .. protoSuffix(id)
	end
	for _, id in ipairs(lists.probing) do
		bnetProb[#bnetProb + 1] = bnetName(id) .. protoSuffix(id)
	end
	for _, id in ipairs(lists.ignored) do
		bnetIgn[#bnetIgn + 1] = bnetName(id) .. protoSuffix(id)
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
	local decks = b.contactDecks or {}
	local deckStr = {}
	for tier = 1, 3 do
		local d = decks[tier]
		deckStr[tier] = d and ("%d/%d"):format(#d.draw, #d.spent) or "0/0"
	end
	ns.Print(("contact decks | bnet %s | guild %s | comm %s | pinned: %d"):format(
		deckStr[1], deckStr[2], deckStr[3], mapSize(b.forcedTargets or {})))
end, "Show learned relays/contacts and the pull pipeline state")

-- /factionrp codec --------------------------------------------------------
--
-- Known-answer vectors produced by the vendored LibDeflate before removal.
-- They pin the wire format so the native codec can be verified in-game.
-- The CBOR vector is {"k":"v","n":5} encoded -> deflate -> channel escape.

local CODEC_FIXTURE = "FactionRP codec selftest fixture: the quick brown fox jumps over the lazy dog. 1234567890"
local CODEC_DEFLATE_HEX = "734B4C2EC9CCCF0B0A5048CE4F494D56284ECD492B492D2E5148CBAC28292D4AB55228C94855282CCD4CCE56482ACA2FCF5348CBAF50C82ACD2D2856C82F4B2D024BE72456552AA4E4A7EB29181A199B989A995B581A00FE"
local CODEC_RAW = "FRP\000codec\001selftest\000vector"
local CODEC_CHANNEL_HEX = "4652500102636F646563010373656C66746573740102766563746F72"
local CODEC_PROFILE = {
	profileID = "selftest",
	sections = { characteristics = { FN = "Ald", LN = "Vane" } },
	clientInfo = { client = "Total RP 3", msp = false },
}
local CODEC_PIPELINE_HEX = "63345B949C93999A57E2999796AF66945B5C909104115814925F9298A31014A060DC549C9A5C92999F572CF6293923B12831B924B528B3B82433B9584DC9C7CF292C312F55C9CDCFC83127655241517E5A664EAAA70B504F4E5A496A7109E0"
local CODEC_CBOR_PROFILE = { k = "v", n = 5 }
local CODEC_CBOR_PIPELINE_HEX = "5B94989D589698C70A0102"

local function deepEqual(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

ns.RegisterCommand("codec", function()
	local ser = ns.Serializer
	local dial = ns.Dialect
	if not ser or not dial then
		return
	end
	local all = true
	local function check(name, ok, detail)
		local pass = ok == true
		all = all and pass
		ns.Print((pass and "|cff33ff66PASS|r" or "|cffff5555FAIL|r") .. " "
			.. name .. (detail and (" | " .. tostring(detail)) or ""))
		return pass
	end

	-- A LibDeflate-produced raw deflate stream decodes natively.
	local inflated = C_EncodingUtil.DecompressString(
		C_EncodingUtil.DecodeHex(CODEC_DEFLATE_HEX),
		Enum.CompressionMethod.Deflate)
	check("LibDeflate vector decompresses natively", inflated == CODEC_FIXTURE)

	-- Native output must be raw deflate; a 0x78 first byte is zlib magic.
	local packed = C_EncodingUtil.CompressString(CODEC_FIXTURE,
		Enum.CompressionMethod.Deflate, Enum.CompressionLevel.OptimizeForSize)
	check("native output is raw deflate",
		packed ~= nil and packed:byte(1) ~= 0x78,
		packed and ("first byte 0x" .. ("%02x"):format(packed:byte(1))))

	-- The inline escape must match the old codec byte-for-byte.
	local chanVec = C_EncodingUtil.DecodeHex(CODEC_CHANNEL_HEX)
	check("channel escape byte-identical", chanVec ~= nil
		and ser.channelEncode(CODEC_RAW) == chanVec
		and ser.channelDecode(chanVec) == CODEC_RAW)

	-- A real pre-change wire payload decodes end to end (gen-5 LibSerialize).
	local payload = C_EncodingUtil.DecodeHex(CODEC_PIPELINE_HEX)
	check("pre-change payload decodes (dialect 5)",
		payload ~= nil and deepEqual(dial.decodeProfile(payload, 5), CODEC_PROFILE))

	-- A fixed CBOR payload decodes end to end (gen-6 codec).
	local cborPayload = C_EncodingUtil.DecodeHex(CODEC_CBOR_PIPELINE_HEX)
	check("CBOR payload decodes (dialect 6)",
		cborPayload ~= nil and deepEqual(
			dial.decodeProfile(cborPayload, 6), CODEC_CBOR_PROFILE))

	-- Both dialects round-trip the same profile table.
	local rt5 = dial.encodeProfile(CODEC_PROFILE, 5)
	check("encode/decode round-trip (dialect 5)",
		rt5 ~= nil and deepEqual(dial.decodeProfile(rt5, 5), CODEC_PROFILE))
	local rt6 = dial.encodeProfile(CODEC_PROFILE, 6)
	check("encode/decode round-trip (dialect 6)",
		rt6 ~= nil and deepEqual(dial.decodeProfile(rt6, 6), CODEC_PROFILE))

	-- The About payload shape: { profileID, about } with TRP3's numeric-keyed
	-- template frames, through the stamped dialect path.
	local aboutPayload = { profileID = "selftest",
		about = { v = 1, TE = 2,
			T2 = { [1] = { TX = "first" }, [2] = { TX = "second", IC = 134414 } } } }
	local ab6 = dial.encodeProfile(aboutPayload, 6)
	check("about payload round-trip (dialect 6)",
		ab6 ~= nil and deepEqual(dial.decodeProfile(ab6, 6), aboutPayload))
	check("about payload honors maxBytes",
		dial.decodeProfile(ab6, 6, 1) == nil)

	-- About verbs ride the same ctl codec. The AD raw field must carry
	-- binary payloads (spaces, pipes, escapes, newlines) byte-for-byte.
	local function ctlArgs(verb, fields, gen)
		gen = gen or 6
		local data = dial.buildCtlData(verb, fields, gen)
		if not data then
			return nil
		end
		local ctl = dial.parseCtl({ data = data, protoVer = gen })
		return ctl and ctl.args
	end
	check("about wire format",
		dial.buildCtlData("AQ", { id = "a-1", unitID = "U-R", pid = "p1" }, 6)
			== "FRP1 AQ a-1 U-R p1")
	check("about AQ round-trip",
		deepEqual(ctlArgs("AQ", { id = "a-1", unitID = "U-R", pid = "p1" }),
			{ id = "a-1", unitID = "U-R", pid = "p1" }))
	local aoArgs = ctlArgs("AO", { id = "o-1", pid = "p", size = 32768 })
	check("about AO size is numeric",
		aoArgs ~= nil and aoArgs.size == 32768)
	local blob = "frp\001\002payload | with spaces\nand\t tabs"
	local adArgs = ctlArgs("AD", { id = "d-9", data = blob })
	check("about AD raw payload round-trip",
		adArgs ~= nil and adArgs.data == blob)
	check("about AD requires data",
		ctlArgs("AD", { id = "d-9" }) == nil)
	check("about verbs absent from dialect 5",
		dial.buildCtlData("AQ", { id = "a", unitID = "u", pid = "p" }, 5) == nil)

	ns.Print(all and "codec selftest: all checks passed"
		or "|cffff5555codec selftest: FAILURES - do not ship|r")
end, "Verify the wire codec against LibDeflate known-answer vectors")

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

-- /factionrp selfx -----------------------------------------------------------
--
-- Live loopback: serve a real register profile to ourselves over a whisper
-- leg at a chosen generation. The payload travels the same pipeline as a
-- normal serve (encode -> envelope -> chunks -> paced send -> reassembly ->
-- gates -> data-leg verify -> decode -> cache -> inject), minus peer
-- discovery. selfx 5 proves we still decode the proto-5 dialect; selfx 6
-- proves the CBOR path.

--- Render a profile data table as flat "path = value" lines for display.
--- Sections get bracket headers; nested tables flatten with dotted paths.
function ns.FormatProfileData(data)
	if type(data) ~= "table" then
		return tostring(data)
	end
	local out = {}
	local function flatten(t, prefix)
		local keys = {}
		for k in pairs(t) do
			keys[#keys + 1] = k
		end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, k in ipairs(keys) do
			local v = t[k]
			local path = prefix and (prefix .. "." .. tostring(k)) or tostring(k)
			if type(v) == "table" then
				flatten(v, path)
			else
				out[#out + 1] = path .. " = " .. tostring(v)
			end
		end
	end
	if data.profileID then
		out[#out + 1] = "profileID = " .. tostring(data.profileID)
	end
	if type(data.sections) == "table" then
		for name, section in pairs(data.sections) do
			out[#out + 1] = "[" .. tostring(name) .. "]"
			flatten(section, nil)
		end
	end
	if type(data.clientInfo) == "table" then
		out[#out + 1] = "[clientInfo]"
		flatten(data.clientInfo, nil)
	end
	for k, v in pairs(data) do
		if k ~= "profileID" and k ~= "sections" and k ~= "clientInfo" then
			if type(v) == "table" then
				out[#out + 1] = "[" .. tostring(k) .. "]"
				flatten(v, nil)
			else
				out[#out + 1] = tostring(k) .. " = " .. tostring(v)
			end
		end
	end
	return table.concat(out, "\n")
end

--- Run a live loopback serve of a real register profile to ourselves over a
--- whisper leg at generation `gen`. Exercises the whole pipeline minus peer
--- discovery. Progress lands on ns.selfxRun for the debug UI.
--- @return table|nil The run state, or nil with a printed reason.
function ns.RunSelfx(gen, name)
	local comms, b, dial = ns.comms, ns.broadcast, ns.Dialect
	if not (comms and b and dial) then
		return
	end
	if ns.selfxRun and not ns.selfxRun.done then
		ns.Print("selfx: a run is already in progress")
		return
	end
	gen = gen or C.PROTO_MAJOR
	if not dial.DIALECTS[gen] then
		ns.Print("selfx: no dialect for gen " .. tostring(gen))
		return
	end
	if ns.Util.isPaused() or ns.Util.commsRestricted() then
		ns.Print("selfx: comms paused right now, try again")
		return
	end
	local adapter = ns.getAvailableAdapter()
	if not adapter then
		ns.Print("selfx: no RP adapter")
		return
	end
	-- Subject: the named unit, else the first directory record the register
	-- can still serve.
	local guid, unitID
	if name then
		unitID = ns.Util.fullUnitName(name)
		guid = unitID and ns.Util.resolveGUID(unitID)
	else
		-- Reservoir sample: uniform pick among the records the register can
		-- still serve, without building a candidate list.
		local n = 0
		for g, rec in pairs(ns.db and ns.db.seen or {}) do
			if g ~= UnitGUID("player") and rec.unitID
				and adapter:canServe(rec.unitID)
			then
				n = n + 1
				if math.random(n) == 1 then
					guid, unitID = g, rec.unitID
				end
			end
		end
	end
	if not (guid and unitID and adapter:canServe(unitID)) then
		ns.Print("selfx: no servable profile (pass a Name-Realm)")
		return
	end
	-- Run inside the adapter's register sandbox so reads and injects hit
	-- copies, not TRP3's live tables.
	local sandboxed, sbReason = adapter:openSandbox(unitID)
	if not sandboxed then
		ns.Print("selfx: sandbox failed (" .. tostring(sbReason) .. ")")
		return
	end
	local profile = adapter:extract(unitID)
	if not profile then
		ns.Print("selfx: extract failed for " .. unitID)
		adapter:closeSandbox()
		return
	end
	local snapshot = CopyTable(profile.data)
	-- Simulate a serve from the subject itself: encode and stamp `gen`.
	local encoded = dial.encodeProfile(profile.data, gen)
	if not encoded then
		ns.Print("selfx: encode failed at gen " .. gen)
		adapter:closeSandbox()
		return
	end
	local own = ns.Util.getUnitID("player")
	if not own then
		ns.Print("selfx: own unitID unavailable")
		adapter:closeSandbox()
		return
	end
	-- Stage the receive: drop our cache copy so the store is NEW, mark the
	-- subject as requested so the data leg is honoured, open the echo
	-- window, and clear the per-sender REQ throttle repeat runs would hit.
	ns.cache.entries[guid] = nil
	local prevRecentReq = b.recentReqs[guid]
	b.recentReqs[guid] = GetTime()
	b.reqSenderAt[own] = nil
	-- A selfx REQ must never trigger a register pull: suppress refreshQuery
	-- for the window so the compare has a still subject.
	b.selfxNoPull = true
	comms.selfEchoUntil = GetTime() + 120
	-- A stamped-N REQ drives the real serve chain: parseCtl(dialect N) ->
	-- canServe -> ACK + pendingServe. We grant it ourselves with an OK so
	-- serveData fires encode at min(own, N); sequential pacing orders them.
	local ctlChunks = {}
	local function ctl(verb, fields)
		local data = ns.Dialect.buildCtlData(verb, fields, gen)
		for _, chunk in ipairs(ns.Serializer.chunk(ns.Serializer.buildMessage({
			sender = guid, subject = C.CTL_SUBJECT,
			addon = profile.addon, originTime = 0,
			contentVersion = "", protoVer = gen, data = data,
		}))) do
			ctlChunks[#ctlChunks + 1] = chunk
		end
	end
	ctl("REQ", { guid = guid, unitID = unitID, seenAt = 0 })
	ctl("OK", { guid = guid })
	local chunks = ctlChunks
	-- Below our own gen the serve leg returns stamped-6/payload-N, which
	-- our decode clamp cannot self-read (that decode is the requester's
	-- job). A fabricated stamped-N data leg covers the inbound codec.
	if gen < C.PROTO_MAJOR then
		local dataChunks = ns.Serializer.chunk(ns.Serializer.buildMessage({
			sender = guid, subject = guid,
			unitID = unitID, addon = profile.addon,
			originTime = b:claimAt(guid, unitID, profile.addon),
			contentVersion = profile.contentVersion,
			protoVer = gen, data = encoded,
		}))
		for _, chunk in ipairs(dataChunks) do
			chunks[#chunks + 1] = chunk
		end
	end
	comms:sendChunksAddon(chunks, "WHISPER", own)
	local run = {
		gen = gen, guid = guid, unitID = unitID,
		chunks = #chunks, bytes = #encoded,
		snapshot = snapshot, senderKey = own,
		sentText = ns.FormatProfileData(snapshot),
	}
	ns.selfxRun = run
	ns.Print(("selfx: serving %s to self at gen %d, %d ctl chunks"):format(
		unitID, gen, #ctlChunks))
	local tries = 0
	local ticker
	ticker = C_Timer.NewTicker(1, function()
		tries = tries + 1
		-- Any buffered inbound during the window is ours; the raw sender
		-- string may differ from our unitID by realm formatting.
		for senderKey in pairs(comms.assembler.buffers) do
			local got, total = comms.assembler:progress(senderKey)
			if got and total then
				run.recvGot, run.recvTotal = got, total
			end
		end
		local entry = ns.cache:get(guid)
		if entry then
			ticker:Cancel()
			adapter:closeSandbox()
			b.selfxNoPull = nil
			b.recentReqs[guid] = prevRecentReq
			-- Snapshot match proves the codec byte-for-byte; a fresh
			-- re-extract match tolerates register drift from refreshQuery
			-- (v bumps, volatile fields) that the payload never carried.
			local vsSnapshot = deepEqual(entry.data, snapshot)
			local fresh = adapter:extract(unitID)
			local vsFresh = fresh and deepEqual(entry.data, fresh.data)
			-- refreshQuery races: a fresher copy can land before we poll,
			-- replacing what our leg stored. Same profileID is still a
			-- codec pass, just not a byte-for-byte one.
			local sameProfile = entry.data
				and entry.data.profileID == snapshot.profileID
			run.same = vsSnapshot or vsFresh or sameProfile or false
			run.receivedText = ns.FormatProfileData(entry.data)
			run.done = true
			-- Wire legs we know for sure: staged ctl + the ACK echo, then
			-- the landed data message's observed chunk count.
			ns.Print(("selfx: %s | ctl %d, data %s chunks, payload %s")
				:format(
					run.same and "PASS" or "FAIL",
					#ctlChunks + 1,
					tostring(run.recvTotal or "?"),
					vsSnapshot and "identical"
						or (vsFresh and "identical (register drifted)")
						or (sameProfile and "fresher copy landed")
						or "DIFFERS"))
			return
		end
		if tries > 120 then
			ticker:Cancel()
			adapter:closeSandbox()
			b.selfxNoPull = nil
			b.recentReqs[guid] = prevRecentReq
			run.done = true
			run.same = false
			ns.Print(("selfx: FAIL | ctl %d, data never landed")
				:format(#ctlChunks + 1))
		end
	end)
	return run
end

-- /factionrp selfabout ---------------------------------------------------------
--
-- Live loopback for the About exchange against a directory profile: the pull
-- is whispered to ourselves inside the selfEcho window. Covers the whole
-- directed path (request -> AQ -> AO -> AG -> AD -> inject -> cache) minus
-- channel discovery and BNet, which cannot echo to self. No tooltip needed.

--- Drop remembered sources that point back at ourselves; a stale self
--- source would route real pulls to a peer that never answers.
local function selfaboutClearSources(about, ownKey)
	for id, record in pairs(about.sources) do
		if record.route and record.route.medium == "WHISPER"
			and ns.Util.normalizeUnitName(record.route.target) == ownKey
		then
			about.sources[id] = nil
		end
	end
end

--- True when the register holds a servable About section for the unit.
local function selfaboutHasAbout(adapter, unitID)
	local profile = adapter:profileFor(unitID)
	local about = profile and profile.about
	-- A numeric v and a 1-3 template mirror what extractAbout/validateAbout
	-- demand on the wire; MSP profiles carry about = {} (data lives in
	-- mspver fields).
	local template = type(about) == "table"
		and (about.TE == nil and 1 or about.TE) or nil
	return type(about) == "table" and type(about.v) == "number"
		and (template == 1 or template == 2 or template == 3)
		and ns.Util.fieldsUsable(about, "TE")
end

--- Compact state dump for a failed run: whether the holder's AD leg ever
--- queued, the last inbound chunk age under our sender key (a stale stamp
--- means the echo never came back), rejectedSenders and stale reassembly
--- buffers — the three "invisible drop" states — plus queue and serve.
local function selfaboutDiag(about, comms, run, own)
	local key = comms:senderKeyFor("WHISPER", own)
	local last = comms.lastChunkFrom[key]
	local blocked = comms.rejectedSenders[key]
	local partials = 0
	for _ in pairs(comms.assembler.buffers[key] or {}) do
		partials = partials + 1
	end
	return (" | %s, %s, %s, %d partials, queue %d, serve %s"):format(
		run.encoded and "data leg queued" or "no data leg",
		last and ("lastchunk " .. math.floor(GetTime() - last) .. "s ago")
			or "no inbound chunks",
		blocked and ("blocked " .. math.ceil(blocked - GetTime()) .. "s left")
			or "not blocked",
		partials, comms:queueDepth(), tostring(about.serve ~= nil))
end

--- Post-run verification: decode the wire payload the holder actually sent
--- (captured at the serve grant) and compare it against what the holder read
--- before the pull and what the register holds after. A PASS means the About
--- page crossed the wire byte-exact, not just that finish() reported cached.
local function selfaboutVerify(adapter, run, unitID, profileID)
	if type(run.encoded) ~= "string" then
		return " | WARN no wire payload captured"
	end
	local ok, data = pcall(ns.Dialect.decodeProfile, run.encoded,
		C.PROTO_MAJOR, C.ABOUT_MAX_RAW)
	if not (ok and type(data) == "table") then
		return " | WARN served payload failed to decode"
	end
	if data.profileID ~= profileID then
		return " | WARN payload profileID mismatch"
	end
	if not deepEqual(data.about, run.preAbout) then
		return " | WARN decoded About differs from served About"
	end
	if not deepEqual(data.about, adapter:extractAbout(unitID, profileID)) then
		return " | WARN register About differs from wire"
	end
	return (" | verified %d bytes end-to-end"):format(#run.encoded)
end

--- Run a live loopback About pull against a directory profile. Progress
--- lands on ns.selfaboutRun; the verdict is requestStatus's terminal reason.
--- @param arg string? "Name-Realm", plus keywords "fixture" (inject a test
---   About first), "reset" (clear cooldown/cache/self-sources) and "big"
---   (lift the size bounds for the run).
--- @return table|nil The run state, or nil with a printed reason.
function ns.RunSelfabout(arg)
	local comms, about = ns.comms, ns.about
	if not (comms and about) then
		return
	end
	if ns.selfaboutRun and not ns.selfaboutRun.done then
		ns.Print("selfabout: a run is already in progress")
		return
	end
	if ns.Util.isPaused() or ns.Util.commsRestricted() then
		ns.Print("selfabout: comms paused right now, try again")
		return
	end
	local adapter = ns.getAdapter(C.SOURCE.TRP3)
	if not adapter or not ns.trp3About or not TRP3_API then
		ns.Print("selfabout: no TRP3 adapter")
		return
	end
	local own = ns.Util.getUnitID("player")
	local ownKey = own and ns.Util.normalizeUnitName(own)
	if not ownKey then
		ns.Print("selfabout: own unitID unavailable")
		return
	end

	-- Args: [Name-Realm] [fixture] [reset] [big] in any order. 'big' lifts the
	-- protocol size bounds for the run; a real peer still enforces them.
	local name, fixture, reset, big
	for token in tostring(arg or ""):gmatch("%S+") do
		local lower = token:lower()
		if lower == "fixture" then
			fixture = true
		elseif lower == "reset" then
			reset = true
		elseif lower == "big" then
			big = true
		else
			name = token
		end
	end
	if reset then
		about.cooldowns, about.cache = {}, {}
		selfaboutClearSources(about, ownKey)
	end

	-- Target: the named unit, else a reservoir pick among directory records
	-- whose register profile still carries an About (selfx's pattern).
	local unitID
	if name then
		unitID = ns.Util.fullUnitName(name)
	else
		local n = 0
		for g, rec in pairs(ns.db and ns.db.seen or {}) do
			if g ~= UnitGUID("player") and rec.unitID
				and adapter:canServe(rec.unitID)
				and selfaboutHasAbout(adapter, rec.unitID)
			then
				n = n + 1
				if math.random(n) == 1 then
					unitID = rec.unitID
				end
			end
		end
	end
	if unitID and ns.Util.normalizeUnitName(unitID) == ownKey then
		ns.Print("selfabout: cannot pull our own About (the adapter rejects self)")
		return
	end
	if not (unitID and adapter:canServe(unitID)) then
		ns.Print("selfabout: no profile with an About (pass Name-Realm)")
		return
	end
	local profileID = TRP3_API.register.getUnitIDProfileID(unitID)
	if type(profileID) ~= "string" or profileID == "" then
		ns.Print("selfabout: no profileID for " .. unitID)
		return
	end
	-- Run inside the adapter's register sandbox so reads and injects hit
	-- copies, not TRP3's live tables.
	local sandboxed, sbReason = adapter:openSandbox(unitID)
	if not sandboxed then
		ns.Print("selfabout: sandbox failed (" .. tostring(sbReason) .. ")")
		return
	end
	if not selfaboutHasAbout(adapter, unitID) then
		if not (fixture and name) then
			ns.Print("selfabout: " .. unitID
				.. " has no About section (pass 'fixture' to inject a test one)")
			adapter:closeSandbox()
			return
		end
		-- Opt-in fixture: minimal T2 template, versioned high so it wins
		-- the version check. Lands in the sandbox only.
		local ok, reason = adapter:injectAbout(unitID, profileID, {
			v = 900001, TE = 2,
			T2 = { [1] = { TX = "selfabout fixture biography" } },
		}, adapter:captureAboutState(unitID, profileID))
		if not ok then
			ns.Print("selfabout: fixture inject failed ("
				.. tostring(reason) .. ")")
			adapter:closeSandbox()
			return
		end
	end
	local status = about:requestStatus(unitID, profileID)
	if status ~= "idle" then
		ns.Print("selfabout: not idle (" .. tostring(status) .. ")")
		adapter:closeSandbox()
		return
	end
	-- Seed the source map the way a real prior serve leaves it, then open
	-- the whisper self-echo window for the exchange.
	about:rememberSource(unitID, profileID,
		{ medium = "WHISPER", senderName = own })
	-- Invisible-drop states persist between runs: a malformed self-echo
	-- blocks our sender key for REJECTED_SENDER_TTL and a stale partial
	-- stream holds a reassembly slot. Clear both for a deterministic run.
	local ownSenderKey = comms:senderKeyFor("WHISPER", own)
	comms.rejectedSenders[ownSenderKey] = nil
	comms.assembler:drop(ownSenderKey)
	-- What the holder will serve, captured before the pull so the decoded
	-- wire payload can be compared against it afterwards.
	local run = { unitID = unitID, profileID = profileID, phase = "starting",
		preAbout = adapter:extractAbout(unitID, profileID) }
	local savedLimits
	if big then
		savedLimits = { raw = C.ABOUT_MAX_RAW, encoded = C.ABOUT_MAX_ENCODED,
			timeout = C.ABOUT_TIMEOUT, chunks = C.REASSEMBLY_MAX_CHUNKS,
			reasm = C.REASSEMBLY_TIMEOUT, queue = C.SEND_QUEUE_CAP }
		C.ABOUT_MAX_RAW = 1048576
		C.ABOUT_MAX_ENCODED = 524288
		C.ABOUT_TIMEOUT = 1800
		C.REASSEMBLY_MAX_CHUNKS = 8192
		C.REASSEMBLY_TIMEOUT = 3600
		C.SEND_QUEUE_CAP = 8192
	end
	local prevEcho, prevNoPull = comms.selfEchoUntil, ns.broadcast.selfxNoPull
	local prevDebugAbout = ns.debugAbout
	-- The window must outlive the worst-case drain: at SEND_RATE chunks per
	-- second a full AD leg takes longer than a couple of minutes.
	comms.selfEchoUntil = GetTime() + C.ABOUT_TIMEOUT
	ns.broadcast.selfxNoPull = true
	-- Narrate the exchange hops for the run so a failure names the dead leg.
	ns.debugAbout = logAbout
	-- Capture the wire bytes at the serve grant; a drain shorter than the
	-- ticker interval would otherwise slip past unseen.
	local prevSendData = about.sendData
	about.sendData = function(self, serve)
		run.encoded = serve and serve.encoded
		return prevSendData(self, serve)
	end
	ns.selfaboutRun = run
	local function cleanup()
		adapter:closeSandbox()
		if run.reqKey then
			about.cooldowns[run.reqKey] = run.prevCooldown
			about.cache[run.reqKey] = run.prevCache
		end
		selfaboutClearSources(about, ownKey)
		comms.selfEchoUntil, ns.broadcast.selfxNoPull = prevEcho, prevNoPull
		ns.debugAbout = prevDebugAbout
		-- About:sendData is class-defined; nil drops the instance field so
		-- the real method resolves again, even after a leaked run.
		about.sendData = nil
		if savedLimits then
			C.ABOUT_MAX_RAW = savedLimits.raw
			C.ABOUT_MAX_ENCODED = savedLimits.encoded
			C.ABOUT_TIMEOUT = savedLimits.timeout
			C.REASSEMBLY_MAX_CHUNKS = savedLimits.chunks
			C.REASSEMBLY_TIMEOUT = savedLimits.reasm
			C.SEND_QUEUE_CAP = savedLimits.queue
		end
	end
	-- requestAbout re-validates the live tooltip context; patch it for the
	-- synchronous call only so later UI updates see the real (empty) one.
	-- pcall + nil-restore: an error inside requestAbout must not leak the
	-- patch, and nil removes the instance field outright so the class
	-- method resolves again even if a previous run left one behind.
	ns.trp3About.getContext = function()
		return { profileID = profileID, unitID = unitID }, nil, unitID, false, false
	end
	local ok, started = pcall(about.requestAbout, about, unitID, profileID)
	ns.trp3About.getContext = nil
	if not (ok and started) then
		cleanup()
		ns.selfaboutRun = nil
		ns.Print("selfabout: requestAbout refused"
			.. (ok and " (see /frp debug about)" or (" | " .. tostring(started))))
		return
	end
	-- Snapshot the request's cooldown/cache records so cleanup can undo
	-- them.
	local reqKey = about.request and about.request.key
	run.reqKey = reqKey
	run.prevCooldown = reqKey and about.cooldowns[reqKey]
	run.prevCache = reqKey and about.cache[reqKey]
	ns.Print(("selfabout: pulling %s about %s via self-whisper")
		:format(unitID, tostring(profileID)))
	local tries = 0
	-- The exchange bounds itself (loadUntil ~= expectedChunks/SEND_RATE +
	-- stall); the cap only covers the case where even that bookkeeping dies.
	local maxTries = math.ceil(C.ABOUT_TIMEOUT) + 60
	local ticker
	ticker = C_Timer.NewTicker(1, function()
		tries = tries + 1
		local req = about.request
		if req and req.key then
			run.phase = req.phase
		end
		-- Discovery means the self route was not live; channel AR cannot
		-- echo, so fail fast instead of waiting out the timeout.
		if run.phase == "waiting" or run.phase == "discovering"
			or run.phase == "discovery-wait"
		then
			ticker:Cancel()
			about:finish("paused")
			run.done = true
			ns.Print("selfabout: FAIL | fell back to discovery "
				.. "(self route not live)" .. selfaboutDiag(about, comms, run, own))
			cleanup()
			return
		end
		local st, _, reason = about:requestStatus(unitID, profileID)
		if st == "cooldown" then
			ticker:Cancel()
			run.done = true
			local pass = reason == "cached"
			local detail = pass
				and selfaboutVerify(adapter, run, unitID, profileID)
				or selfaboutDiag(about, comms, run, own)
			ns.Print(("selfabout: %s | phase %s, reason %s%s")
				:format(pass and "PASS" or "FAIL",
					tostring(run.phase), tostring(reason or "ok"), detail))
			cleanup()
			return
		end
		if st == "idle" and not req then
			ticker:Cancel()
			run.done = true
			ns.Print("selfabout: FAIL | request vanished without a verdict"
				.. selfaboutDiag(about, comms, run, own))
			cleanup()
			return
		end
		if tries > maxTries then
			ticker:Cancel()
			about:finish("paused")
			run.done = true
			ns.Print("selfabout: FAIL | timed out in phase "
				.. tostring(run.phase) .. selfaboutDiag(about, comms, run, own))
			cleanup()
		end
	end)
	return run
end

ns.RegisterCommand("selfabout", function(arg)
	ns.RunSelfabout(arg)
end, "Loopback-test the About pull over a self whisper ([Name-Realm] [fixture] [reset] [big])")

-- /frp echotest -----------------------------------------------------------
--
-- Delivery probe for the self-whisper path. Sends AD-shaped variants over
-- the identical envelope/chunk/WHISPER route and reports which echo back as
-- chunks vs which reach the About layer. Exists to answer "does the wire
-- text itself kill delivery" after a handoff AD + timeout run: 'raw-chunk'
-- is an envelope-invalid bare chunk (delivery control), 'ascii' a pure-text
-- ctl payload, 'encoded' a real encodeProfile output, 'sweep' every byte
-- value channel-escaped.
ns.RegisterCommand("echotest", function()
	local comms, about = ns.comms, ns.about
	if not (comms and about and ns.broadcast) then
		ns.Print("echotest: comms not ready")
		return
	end
	if ns.echotestRun and not ns.echotestRun.done then
		ns.Print("echotest: a run is already in progress")
		return
	end
	local own = ns.Util.getUnitID("player")
	local guid = ns.broadcast:senderGUID()
	if not (own and guid) then
		ns.Print("echotest: own identity unavailable")
		return
	end
	local run = { done = false }
	ns.echotestRun = run

	local realEnc = ns.Dialect.encodeProfile({
		profileID = "probe",
		about = { v = 1, TE = 2, T2 = { [1] = { TX = "echotest" } } },
	}, C.PROTO_MAJOR)
	local bytes = {}
	for b = 0, 255 do
		bytes[#bytes + 1] = string.char(b)
	end
	local sweep = ns.Serializer.channelEncode(table.concat(bytes))
	local variants = {
		-- A parseable envelope under an unrecognized subject: exercises the
		-- same binary chunk delivery, then drops at verifyDataLeg without
		-- tripping blockSender (a malformed envelope would mute our own
		-- sender key for REJECTED_SENDER_TTL and poison the run).
		{ id = "et-raw", name = "raw-subj", subject = "_frptest",
			payload = sweep },
		{ id = "et-ascii", name = "ascii", payload = ("a"):rep(46) },
		{ id = "et-bin", name = "encoded", payload = realEnc },
		{ id = "et-sweep", name = "sweep", payload = sweep },
		-- Sent via AddOn_Chomp directly with a dispatch callback: separates
		-- "queued but never handed to the wire" (CTL backlog) from "sent
		-- but no echo".
		{ id = "et-ctl", name = "ctl-direct", payload = ("b"):rep(46),
			direct = true },
	}

	-- Arrival is counted twice: the raw chunk string (delivery) and the
	-- About dispatch (valid ctl). A variant that echoes but never reaches
	-- About was corrupted or parse-dropped, not undelivered.
	local chunkHits, hits = {}, {}
	local prevHandle, prevOnMessage = comms.handleIncoming, about.onMessage
	comms.handleIncoming = function(self, chunkString, context)
		for _, v in ipairs(variants) do
			if not chunkHits[v.id] and chunkString:find(v.id, 1, true) then
				chunkHits[v.id] = true
			end
		end
		return prevHandle(self, chunkString, context)
	end
	about.onMessage = function(self, ctl, msg, context)
		if ctl and ctl.args and ctl.args.id then
			hits[ctl.args.id] = true
		end
		return prevOnMessage(self, ctl, msg, context)
	end

	local prevEcho, prevNoPull = comms.selfEchoUntil, ns.broadcast.selfxNoPull
	comms.selfEchoUntil = GetTime() + 60
	ns.broadcast.selfxNoPull = true
	local function cleanup()
		comms.selfEchoUntil, ns.broadcast.selfxNoPull = prevEcho, prevNoPull
		-- Both are class methods; nil drops the instance field so the real
		-- one resolves again, even after a leaked run.
		comms.handleIncoming = nil
		about.onMessage = nil
		run.done = true
	end

	local i = 0
	local ticker
	ticker = C_Timer.NewTicker(2, function()
		i = i + 1
		if i <= #variants then
			local v = variants[i]
			local text = ns.Dialect.buildCtlData("AD",
				{ id = v.id, data = v.payload }, C.PROTO_MAJOR)
			local message = ns.Serializer.buildMessage({
				sender = guid, subject = v.subject or C.ABOUT_SUBJECT,
				unitID = own, addon = "FRP",
				originTime = time(), contentVersion = "0",
				data = text })
			local sent
			if v.direct and AddOn_Chomp and AddOn_Chomp.SendAddonMessage then
				-- The callback fires when CTL actually hands the message
				-- to the wire, not when we queue it.
				local t0 = GetTime()
				AddOn_Chomp.SendAddonMessage(comms.prefix,
					ns.Serializer.chunk(message)[1], "WHISPER", own,
					"LOW", nil, function()
						ns.Print(("echotest: ctl-direct on the wire +%.1fs")
							:format(GetTime() - t0))
					end)
				sent = true
			else
				sent = comms:sendChunksAddon(ns.Serializer.chunk(message),
					"WHISPER", own)
			end
			ns.Print(("echotest: sent %-9s | %s"):format(v.name,
				sent and "queued" or "QUEUE FAILED"))
		elseif i > #variants + 3 then
			ticker:Cancel()
			for _, v in ipairs(variants) do
				ns.Print(("echotest: %-9s | chunk %s | about %s"):format(
					v.name,
					chunkHits[v.id] and "echoed" or "MISSING",
					v.subject and "n/a (other subject)"
						or (hits[v.id] and "reached" or "dropped")))
			end
			cleanup()
		end
	end)
	return run
end, "Probe which AD-leg variants echo over a self whisper")


ns.RegisterCommand("aboutbtn", function()
	ns.debugAboutBtn = not ns.debugAboutBtn
	ns.Print("aboutbtn: same-faction gate "
		.. (ns.debugAboutBtn and "bypassed (button can show)" or "restored"))
	if ns.trp3About then
		ns.trp3About:update()
	end
end, "Toggle the About pull button on same-faction profiles for UI testing")
