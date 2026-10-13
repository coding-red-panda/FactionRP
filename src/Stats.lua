-- Stats.lua
--
-- Session-only traffic statistics for debugging: message rates, byte sizes
-- (average AND median), profile reassembly time (first to last chunk), per-leg
-- transmit time, per-medium breakdowns, cache outcomes, error tallies, queue
-- health, and a ring buffer of the most recent messages for close inspection.
--
-- Collection is gated on the "stats" debug category (or `all`): while
-- disabled, the recorder entry points (ns.statsIn / ns.statsOutLeg / ...) are
-- simply absent, so instrumentation call sites behind nil-guards cost one
-- table lookup and nothing runs. Debug.lua's ns.refreshDebugHooks re-applies
-- the installation via ns.applyStatsHooks whenever flags change.
--
-- Memory is bounded: sizes/durations live in fixed-cap reservoirs (only used
-- for medians and last-N queries), rates in a bucketed ring, and the recent
-- log in a ring buffer.

local _, ns = ...
local C = ns.Const

local GetTime = GetTime
local floor = math.floor
local sort = table.sort

local RES_CAP = C.STATS_RESERVOIR

-- Store ----------------------------------------------------------------------
-- One stable table, published as ns.stats and reset in place, so the recorder
-- implementations below can upvalue it and never look it up per call.

local stats = {}
ns.stats = stats

local function freshBuckets()
	local b = {}
	for i = 0, C.STATS_RATE_BUCKETS - 1 do
		b[i] = { s = -1, c = 0 }
	end
	return b
end

local function resetStore()
	for k in pairs(stats) do
		stats[k] = nil
	end
	stats.startedAt = GetTime()

	-- Logical messages (reassembled inbound / built outbound).
	stats.inMsgs, stats.inBytes = 0, 0
	stats.outMsgs, stats.outBytes = 0, 0
	-- Per-leg outbound completions and wire-level chunk counters.
	stats.outSends = 0
	stats.inChunks, stats.inWireBytes = 0, 0
	stats.outChunks, stats.outWireBytes = 0, 0
	stats.dupChunks = 0    -- duplicate chunk arrivals (retransmits)
	stats.incomplete = 0   -- reassembly buffers pruned (lost chunks)

	-- Fixed-cap sample reservoirs: { cap, n = live count, i = write cursor, ... }.
	local function res() return { cap = RES_CAP, n = 0, i = 0 } end
	stats.inSizes = res()
	stats.outSizes = res()
	stats.inChunkSizes = res()
	stats.outChunkSizes = res()
	stats.assembleMs = res() -- first->last chunk, inbound
	stats.transmitMs = res() -- enqueue->last chunk sent, per leg
	stats.originAge = res()  -- time() - originTime on receipt

	-- Per-medium counters keyed by channel kind ("CHANNEL", "BNET", ...).
	stats.mediumsIn = {}  -- [medium] = { msgs, bytes, chunks }
	stats.mediumsOut = {}
	stats.legs = {}       -- [leg] = sends ("channel","group","bnet","community","guild","pinned","req","ack","ok","nok","hi","serve","bnet_probe")

	stats.cache = { new = 0, updated = 0, refreshed = 0, rejected = 0 }
	stats.errors = {} -- [kind] = count

	stats.queue = { highWater = 0, dwellSum = 0, dwellN = 0, dwellMax = 0 }
	stats.queues = {} -- [name] = high-water depth ("inject", "received")

	stats.senders, stats.senderN = {}, 0
	stats.subjects, stats.subjectN = {}, 0

	stats.rateIn = { b = freshBuckets() }   -- logical inbound messages/s
	stats.rateOut = { b = freshBuckets() }  -- logical outbound messages/s
	stats.rateLegs = { b = freshBuckets() } -- per-leg outbound completions/s

	stats.recent = { cap = C.STATS_RECENT, n = 0, i = 0 } -- {dir, medium, peer, subject, bytes, chunks, ms, at}
end

resetStore()

-- Sample helpers ---------------------------------------------------------------

--- Append a value to a fixed-cap ring reservoir (cap is stored on the table).
local function push(t, v)
	local cap = t.cap
	local i = t.i + 1
	if i > cap then
		i = 1
	end
	t.i = i
	t[i] = v
	if t.n < cap then
		t.n = t.n + 1
	end
end

--- Median of a reservoir's live entries (copy + sort; query-time only).
local function median(t)
	local n = t.n
	if n == 0 then
		return 0
	end
	local copy = {}
	for i = 1, n do
		copy[i] = t[i]
	end
	sort(copy)
	local mid = floor((n + 1) / 2)
	if n % 2 == 1 then
		return copy[mid]
	end
	return (copy[mid] + copy[mid + 1]) / 2
end

--- Largest live entry of a reservoir.
local function reservoirMax(t)
	local n = t.n
	if n == 0 then
		return 0
	end
	local m = t[1]
	for i = 2, n do
		if t[i] > m then
			m = t[i]
		end
	end
	return m
end

-- Rolling rate ------------------------------------------------------------------
-- The window is divided into BUCKETS slots, each stamped with its slot index;
-- a bump re-zeros the bucket its slot rotates into, so the live window is at
-- most STATS_RATE_WINDOW seconds without any per-query pruning.

local RATE_SPAN = C.STATS_RATE_WINDOW / C.STATS_RATE_BUCKETS
local RATE_BUCKETS = C.STATS_RATE_BUCKETS

local function bumpRate(r, now)
	local slot = floor(now / RATE_SPAN)
	local b = r.b[slot % RATE_BUCKETS]
	if b.s ~= slot then
		b.s = slot
		b.c = 0
	end
	b.c = b.c + 1
end

--- Count of events within the last STATS_RATE_WINDOW seconds.
local function rateCount(r, now)
	local slot = floor(now / RATE_SPAN)
	local total = 0
	for i = 0, RATE_BUCKETS - 1 do
		local b = r.b[i]
		if b.s > slot - RATE_BUCKETS and b.s <= slot then
			total = total + b.c
		end
	end
	return total
end

local function bumpMedium(t, medium, msgs, bytes, chunks)
	local m = t[medium]
	if not m then
		m = { msgs = 0, bytes = 0, chunks = 0 }
		t[medium] = m
	end
	m.msgs = m.msgs + msgs
	m.bytes = m.bytes + bytes
	m.chunks = m.chunks + chunks
end

--- Write a record into the recent ring, reusing the slot's entry table so
-- recording allocates nothing once the ring has wrapped once.
local function pushRecent(dir, medium, peer, bytes, chunks, ms)
	local r = stats.recent
	local cap = r.cap
	local i = r.i + 1
	if i > cap then
		i = 1
	end
	r.i = i
	if r.n < cap then
		r.n = r.n + 1
	end
	local e = r[i]
	if not e then
		e = {}
		r[i] = e
	end
	e.dir = dir
	e.medium = medium
	e.peer = peer
	e.subject = nil -- stamped later via statsTagSubject
	e.bytes = bytes
	e.chunks = chunks
	e.ms = ms
	e.at = GetTime()
end

-- Recorders --------------------------------------------------------------------
-- Installed onto ns while the "stats" flag is on; absent otherwise. Each
-- upvalues the store and helpers directly — no flag checks, no extra lookups.

local function recChunkIn(medium, bytes)
	stats.inChunks = stats.inChunks + 1
	stats.inWireBytes = stats.inWireBytes + bytes
	push(stats.inChunkSizes, bytes)
	bumpMedium(stats.mediumsIn, medium, 0, bytes, 1)
end

local function recIn(full, senderKey, medium, chunks, elapsed, dupes)
	local bytes = #full
	stats.inMsgs = stats.inMsgs + 1
	stats.inBytes = stats.inBytes + bytes
	stats.dupChunks = stats.dupChunks + (dupes or 0)
	bumpMedium(stats.mediumsIn, medium, 1, 0, 0)
	push(stats.inSizes, bytes)
	push(stats.assembleMs, elapsed * 1000)
	bumpRate(stats.rateIn, GetTime())
	pushRecent("in", medium, senderKey, bytes, chunks, elapsed * 1000)
end

--- Stamp the subject GUID onto the newest inbound recent entry once Broadcast
--- has parsed the envelope (Comms only sees opaque bytes).
local function recTagSubject(subject)
	local r = stats.recent
	local e = r.n > 0 and r[r.i]
	if e and e.dir == "in" then
		e.subject = subject
	end
end

local function recChunkOut(medium, bytes, dwell)
	stats.outChunks = stats.outChunks + 1
	stats.outWireBytes = stats.outWireBytes + bytes
	push(stats.outChunkSizes, bytes)
	local q = stats.queue
	q.dwellSum = q.dwellSum + dwell
	q.dwellN = q.dwellN + 1
	if dwell > q.dwellMax then
		q.dwellMax = dwell
	end
end

--- A full message finished draining to one leg (last chunk dequeued).
-- @param elapsed number Seconds from first enqueue to last-chunk send.
local function recOutLeg(medium, target, bytes, chunks, elapsed)
	stats.outSends = stats.outSends + 1
	bumpMedium(stats.mediumsOut, medium, 1, bytes, chunks)
	push(stats.transmitMs, elapsed * 1000)
	bumpRate(stats.rateLegs, GetTime())
	pushRecent("out", medium, target, bytes, chunks, elapsed * 1000)
end

--- A logical outbound message was built (serve or request).
local function recOutMessage(bytes, chunks, subject, how)
	stats.outMsgs = stats.outMsgs + 1
	stats.outBytes = stats.outBytes + bytes
	push(stats.outSizes, bytes)
	local key = how or "send"
	stats.legs[key] = (stats.legs[key] or 0) + 1
	bumpRate(stats.rateOut, GetTime())
end

local function recQueue(depth)
	if depth > stats.queue.highWater then
		stats.queue.highWater = depth
	end
end

local function recQueueDepth(name, depth)
	local cur = stats.queues[name]
	if not cur or depth > cur then
		stats.queues[name] = depth
	end
end

local function recLeg(name, n)
	stats.legs[name] = (stats.legs[name] or 0) + n
end

local function recCache(result)
	local key = tostring(result)
	stats.cache[key] = (stats.cache[key] or 0) + 1
end

local function recError(kind)
	stats.errors[kind] = (stats.errors[kind] or 0) + 1
end

local function recPruned(n)
	stats.incomplete = stats.incomplete + n
end

local function recOriginAge(seconds)
	push(stats.originAge, seconds)
end

local function recPeer(sender, subject)
	if sender and not stats.senders[sender] then
		stats.senders[sender] = true
		stats.senderN = stats.senderN + 1
	end
	if subject and not stats.subjects[subject] then
		stats.subjects[subject] = true
		stats.subjectN = stats.subjectN + 1
	end
end

local RECORDERS = {
	statsChunkIn = recChunkIn,
	statsIn = recIn,
	statsTagSubject = recTagSubject,
	statsChunkOut = recChunkOut,
	statsOutLeg = recOutLeg,
	statsOutMessage = recOutMessage,
	statsQueue = recQueue,
	statsQueueDepth = recQueueDepth,
	statsLeg = recLeg,
	statsCache = recCache,
	statsError = recError,
	statsPruned = recPruned,
	statsOriginAge = recOriginAge,
	statsPeer = recPeer,
}

--- Install the recorders while the "stats" category (or `all`) is enabled;
--- remove them otherwise so call sites noop on a single nil check.
function ns.applyStatsHooks()
	local on = ns.debugEnabled and ns.debugEnabled("stats")
	for name, fn in pairs(RECORDERS) do
		ns[name] = on and fn or nil
	end
end

-- Snapshot ---------------------------------------------------------------------

ns.Stats = {}

--- Computed read-only summary for inspection (slash output now, UI later).
-- @return table
function ns.Stats.snapshot()
	local now = GetTime()
	local uptime = now - stats.startedAt
	local inN, outN = stats.inMsgs, stats.outMsgs
	return {
		uptime = uptime,
		inMsgs = inN,
		outMsgs = outN,
		outSends = stats.outSends,
		inBytes = stats.inBytes,
		outBytes = stats.outBytes,
		inChunks = stats.inChunks,
		outChunks = stats.outChunks,
		inWireBytes = stats.inWireBytes,
		outWireBytes = stats.outWireBytes,
		avgInSize = inN > 0 and stats.inBytes / inN or 0,
		avgOutSize = outN > 0 and stats.outBytes / outN or 0,
		medInSize = median(stats.inSizes),
		medOutSize = median(stats.outSizes),
		medInChunk = median(stats.inChunkSizes),
		medOutChunk = median(stats.outChunkSizes),
		medAssembleMs = median(stats.assembleMs),
		maxAssembleMs = reservoirMax(stats.assembleMs),
		medTransmitMs = median(stats.transmitMs),
		maxTransmitMs = reservoirMax(stats.transmitMs),
		medOriginAge = median(stats.originAge),
		rateIn = uptime > 0 and rateCount(stats.rateIn, now) / (uptime < C.STATS_RATE_WINDOW and uptime or C.STATS_RATE_WINDOW) or 0,
		rateOut = uptime > 0 and rateCount(stats.rateOut, now) / (uptime < C.STATS_RATE_WINDOW and uptime or C.STATS_RATE_WINDOW) or 0,
		rateLegs = uptime > 0 and rateCount(stats.rateLegs, now) / (uptime < C.STATS_RATE_WINDOW and uptime or C.STATS_RATE_WINDOW) or 0,
		rateInSession = uptime > 0 and inN / uptime or 0,
		rateOutSession = uptime > 0 and outN / uptime or 0,
		rateLegsSession = uptime > 0 and stats.outSends / uptime or 0,
		dupChunks = stats.dupChunks,
		incomplete = stats.incomplete,
		mediumsIn = stats.mediumsIn,
		mediumsOut = stats.mediumsOut,
		legs = stats.legs,
		cache = stats.cache,
		errors = stats.errors,
		queue = stats.queue,
		queues = stats.queues,
		senderN = stats.senderN,
		subjectN = stats.subjectN,
		recent = stats.recent,
	}
end

-- /factionrp stats -------------------------------------------------------------

local function fmtBytes(n)
	if n >= 1024 then
		return ("%.1fKB"):format(n / 1024)
	end
	return ("%dB"):format(n)
end

local function fmtMs(ms)
	if ms >= 1000 then
		return ("%.2fs"):format(ms / 1000)
	end
	return ("%.0fms"):format(ms)
end

local function offHint()
	if not ns.debugEnabled("stats") then
		ns.Print("|cffff5555(stats collection is off — '/frp debug stats' to enable)|r")
	end
end

local SECTIONS = {}

local function printSummary()
	local s = ns.Stats.snapshot()
	ns.Print(("stats | uptime %s | in %d msgs (%s, %.2f msg/s) | out %d msgs (%s, %.2f msg/s, %.2f legs/s) | legs %d"):format(
		("%ds"):format(s.uptime), s.inMsgs, fmtBytes(s.inBytes), s.rateIn,
		s.outMsgs, fmtBytes(s.outBytes), s.rateOut, s.rateLegs, s.outSends
	))
	ns.Print(("  sizes in avg/med %s/%s | out avg/med %s/%s | assemble med/max %s/%s | transmit med/max %s/%s"):format(
		fmtBytes(s.avgInSize), fmtBytes(s.medInSize),
		fmtBytes(s.avgOutSize), fmtBytes(s.medOutSize),
		fmtMs(s.medAssembleMs), fmtMs(s.maxAssembleMs),
		fmtMs(s.medTransmitMs), fmtMs(s.maxTransmitMs)
	))
	ns.Print(("  peers %d senders / %d subjects | incomplete %d | dup chunks %d | queue hw %d"):format(
		s.senderN, s.subjectN, s.incomplete, s.dupChunks, s.queue.highWater
	))
	ns.Print("  sections: mediums sizes timing cache errors queue last [n] | 'reset' zeroes")
end

function SECTIONS.mediums()
	local s = ns.Stats.snapshot()
	ns.Print("mediums in:")
	for m, v in pairs(s.mediumsIn) do
		ns.Print(("  %s: %d msgs, %d chunks, %s"):format(m, v.msgs, v.chunks, fmtBytes(v.bytes)))
	end
	ns.Print("mediums out:")
	for m, v in pairs(s.mediumsOut) do
		ns.Print(("  %s: %d msgs, %d chunks, %s"):format(m, v.msgs, v.chunks, fmtBytes(v.bytes)))
	end
	ns.Print("legs:")
	for leg, n in pairs(s.legs) do
		ns.Print(("  %s: %d"):format(leg, n))
	end
end

function SECTIONS.sizes()
	local s = ns.Stats.snapshot()
	ns.Print(("messages in:  avg %s | median %s | n=%d"):format(fmtBytes(s.avgInSize), fmtBytes(s.medInSize), s.inMsgs))
	ns.Print(("messages out: avg %s | median %s | n=%d"):format(fmtBytes(s.avgOutSize), fmtBytes(s.medOutSize), s.outMsgs))
	ns.Print(("chunks in:  median %s | n=%d | wire %s"):format(fmtBytes(s.medInChunk), s.inChunks, fmtBytes(s.inWireBytes)))
	ns.Print(("chunks out: median %s | n=%d | wire %s"):format(fmtBytes(s.medOutChunk), s.outChunks, fmtBytes(s.outWireBytes)))
end

function SECTIONS.timing()
	local s = ns.Stats.snapshot()
	ns.Print(("reassembly (first->last chunk): median %s | max %s"):format(fmtMs(s.medAssembleMs), fmtMs(s.maxAssembleMs)))
	ns.Print(("transmit (enqueue->last sent, per leg): median %s | max %s"):format(fmtMs(s.medTransmitMs), fmtMs(s.maxTransmitMs)))
	ns.Print(("origin age on receipt (approx, sender clock): median %s"):format(
		s.medOriginAge > 0 and ("%.0fs"):format(s.medOriginAge) or "n/a"))
	ns.Print(("queue dwell per chunk: avg %s | max %s"):format(
		s.queue.dwellN > 0 and fmtMs(s.queue.dwellSum / s.queue.dwellN * 1000) or "n/a",
		fmtMs(s.queue.dwellMax * 1000)))
end

function SECTIONS.cache()
	local c = ns.Stats.snapshot().cache
	ns.Print(("cache outcomes: new %d | updated %d | refreshed %d | rejected %d"):format(
		c.new or 0, c.updated or 0, c.refreshed or 0, c.rejected or 0))
end

function SECTIONS.errors()
	local e = ns.Stats.snapshot().errors
	local any = false
	for kind, n in pairs(e) do
		ns.Print(("  %s: %d"):format(kind, n))
		any = true
	end
	if not any then
		ns.Print("errors: none recorded")
	end
end

function SECTIONS.queue()
	local s = ns.Stats.snapshot()
	ns.Print(("send queue: depth %d | high-water %d | dwell avg %s max %s"):format(
		ns.comms and ns.comms:queueDepth() or 0, s.queue.highWater,
		s.queue.dwellN > 0 and fmtMs(s.queue.dwellSum / s.queue.dwellN * 1000) or "n/a",
		fmtMs(s.queue.dwellMax * 1000)))
	for name, depth in pairs(s.queues) do
		ns.Print(("  %s queue high-water: %d"):format(name, depth))
	end
end

local function printLast(n)
	local r = ns.stats.recent
	local total = r.n
	if total == 0 then
		ns.Print("no recent messages recorded")
		return
	end
	n = math.min(n or 10, total)
	ns.Print(("last %d message(s):"):format(n))
	-- Walk the ring backwards from the newest entry.
	for k = 0, n - 1 do
		local idx = ((r.i - 1 - k) % r.cap) + 1
		local e = r[idx]
		if e then
			local arrow = e.dir == "in" and "|cff66ccff<-|r" or "|cffffd200->|r"
			local extra = e.dir == "in" and (e.subject and (" subject " .. e.subject) or "") or ""
			ns.Print(("  %s %s %s%s: %s, %d chunks, %s"):format(
				arrow, tostring(e.medium), tostring(e.peer or "?"), extra,
				fmtBytes(e.bytes), e.chunks, fmtMs(e.ms)))
		end
	end
end

ns.RegisterCommand("stats", function(arg)
	arg = arg and ns.Util.trim(arg) or ""
	offHint()
	if arg == "reset" then
		resetStore()
		ns.Print("stats reset")
		return
	end
	local section, rest = arg:match("^(%S*)%s*(.-)$")
	if section == "last" then
		printLast(tonumber(rest))
		return
	end
	if section ~= "" and SECTIONS[section] then
		SECTIONS[section]()
		return
	end
	if section ~= "" then
		ns.Print("unknown stats section '" .. section .. "'")
	end
	printSummary()
end, "Show traffic statistics; sections: mediums sizes timing cache errors queue last [n] | 'reset'")

-- /factionrp mem ---------------------------------------------------------------
-- Memory diagnostics. GetAddOnMemoryUsage is a cached counter, so every read
-- is preceded by UpdateAddOnMemoryUsage; a forced collect first makes the
-- figure report live (retained) memory rather than pending garbage.

local function memKB()
	collectgarbage("collect")
	UpdateAddOnMemoryUsage()
	return GetAddOnMemoryUsage(C.ADDON_NAME)
end

local function mapSize(t)
	local n = 0
	for _ in pairs(t or {}) do
		n = n + 1
	end
	return n
end

local function printCensus()
	ns.Print(("mem census | %.1f KB (after GC + refresh)"):format(memKB()))
	local comms = ns.comms
	if comms then
		local bufs, senders = 0, 0
		for _, per in pairs(comms.assembler.buffers) do
			senders = senders + 1
			for _ in pairs(per) do
				bufs = bufs + 1
			end
		end
		ns.Print(("  send queue %d | reassembly %d bufs / %d senders | bnet memo %d ids"):format(
			comms:queueDepth(), bufs, senders, #comms.bnetAcctMemo.ids))
		local conf, probing, ignored = comms:bnetPeerCounts()
		ns.Print(("  bnet peers %d conf / %d probing / %d ignored | blocked senders %d"):format(
			conf, probing, ignored, mapSize(comms.rejectedSenders)))
	end
	if ns.cache then
		ns.Print(("  cache entries %d"):format(ns.cache:count()))
	end
	local b = ns.broadcast
	if b then
		ns.Print(("  inject %d | relays %d | contacts %d | commUsage %d | pinned %d | reqs %d | serves %d"):format(
			b:injectDepth(), mapSize(b.relays), mapSize(b.xfacContacts),
			mapSize(b.commUsage), mapSize(b.forcedTargets),
			mapSize(b.requests), mapSize(b.pendingServes)))
	end
	local sc = ns.scanner
	if sc then
		ns.Print(("  received q %d / pending %d | selected %d | lastShared %d"):format(
			#sc.receivedQueue, mapSize(sc.receivedPending), mapSize(sc.selected),
			mapSize(sc.lastSharedVersion)))
	end
	local roster = ns.Util._roster and ns.Util._roster()
	if roster then
		ns.Print(("  roster xfac %d / guild %d | names %d | guids %d | guidMemo %d"):format(
			#roster.xfac, #roster.xfacGuild, mapSize(roster.factionByName),
			mapSize(roster.guidByName), mapSize(ns.Util._guidMemo and ns.Util._guidMemo())))
	end
end

ns.RegisterCommand("mem", function(arg)
	arg = arg and ns.Util.trim(arg) or ""
	local sub, rest = arg:match("^(%S*)%s*(.-)$")
	sub = sub and sub:lower() or ""
	if sub == "churn" then
		-- Sample the (uncollected) counter each second after a forced GC: the
		-- peak-to-baseline delta approximates the allocation backlog, i.e.
		-- churn between GC cycles.
		local ticks = math.max(1, math.floor(tonumber(rest) or 10))
		local baseline = memKB()
		local peak = baseline
		local elapsed = 0
		ns.Print(("mem baseline %.1f KB; sampling churn over %ds ..."):format(baseline, ticks))
		local ticker
		ticker = C_Timer.NewTicker(1, function()
			elapsed = elapsed + 1
			UpdateAddOnMemoryUsage()
			local kb = GetAddOnMemoryUsage(C.ADDON_NAME)
			if kb > peak then
				peak = kb
			end
			if elapsed >= ticks then
				ticker:Cancel()
				ns.Print(("mem churn: %.1f KB -> %.1f KB (peak %.1f, +%.1f KB backlog)"):format(
					baseline, kb, peak, peak - baseline))
			end
		end)
		return
	end
	if sub == "census" then
		printCensus()
		return
	end
	ns.Print(("mem: %.1f KB (after GC + refresh)"):format(memKB()))
	ns.Print("  sections: churn [n] census")
end, "Show live addon memory; 'churn [n]' samples allocation rate, 'census' counts suspect tables")
