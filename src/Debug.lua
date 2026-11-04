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

	-- A fixed CBOR payload decodes end to end (gen-6 codec).
	local cborPayload = C_EncodingUtil.DecodeHex(CODEC_CBOR_PIPELINE_HEX)
	check("CBOR payload decodes (dialect 6)",
		cborPayload ~= nil and deepEqual(
			dial.decodeProfile(cborPayload, 6), CODEC_CBOR_PROFILE))

	-- The dialect round-trips a profile table.
	local rt6 = dial.encodeProfile(CODEC_PROFILE, 6)
	check("encode/decode round-trip (dialect 6)",
		rt6 ~= nil and deepEqual(dial.decodeProfile(rt6, 6), CODEC_PROFILE))

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
-- discovery. The selectable generations are the supported dialects — only
-- generation 6 today, exercising the CBOR path.

--- Render a profile data table as flat "path = value" lines for display.
-- Sections get bracket headers; nested tables flatten with dotted paths.
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
-- whisper leg at generation `gen`. Exercises the whole pipeline minus peer
-- discovery. Progress lands on ns.selfxRun for the debug UI.
-- @return table|nil The run state, or nil with a printed reason.
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
	local profile = adapter:extract(unitID)
	if not profile then
		ns.Print("selfx: extract failed for " .. unitID)
		return
	end
	local snapshot = CopyTable(profile.data)
	-- Simulate a serve from the subject itself: encode and stamp `gen`.
	local encoded = dial.encodeProfile(profile.data, gen)
	if not encoded then
		ns.Print("selfx: encode failed at gen " .. gen)
		return
	end
	local own = ns.Util.getUnitID("player")
	if not own then
		ns.Print("selfx: own unitID unavailable")
		return
	end
	-- Stage the receive: drop our cache copy so the store is NEW, mark the
	-- subject as requested so the data leg is honoured, open the echo
	-- window, and clear the per-sender REQ throttle repeat runs would hit.
	ns.cache.entries[guid] = nil
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
			b.selfxNoPull = nil
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
			b.selfxNoPull = nil
			run.done = true
			run.same = false
			ns.Print(("selfx: FAIL | ctl %d, data never landed")
				:format(#ctlChunks + 1))
		end
	end)
	return run
end

