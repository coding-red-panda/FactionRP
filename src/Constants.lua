-- Constants.lua
--
-- Central configuration for the AddOn; every magic value lives here.

local _, ns = ...

local C = {}
ns.Const = C

-- Identity -----------------------------------------------------------------

C.ADDON_NAME = "FactionRP"
C.VERSION = "0.4.5"

-- Wire-protocol generation, stamped into every envelope and the channel
-- name. Peers on a lower PROTO_MAJOR are rejected; bump on breaking changes.
C.PROTO_MAJOR = 5

-- Communication -------------------------------------------------------------

-- Addon-message prefix registered with the client; max 16 characters.
C.MSG_PREFIX = "FactionRP"

-- Hidden channel for same-faction traffic. Carries the protocol generation
-- so older clients sit on a disjoint channel.
C.COMM_CHANNEL = "frp" .. C.PROTO_MAJOR .. "comms" -- e.g. "frp5comms"
-- Previous generation's channel, briefly joined to announce VER there.
C.COMM_CHANNEL_PROTO3 = "frp3comms"

-- Field separator inside a message payload; virtually never appears in data.
C.SEPARATOR = "||"

-- Addon messages cap at 255 bytes; payload per chunk stays below this
-- to leave room for the chunk-framing header.
C.CHUNK_SIZE = 220

-- Outbound pacing: SEND_RATE chunks per second released on a SEND_INTERVAL
-- tick via a fractional token bucket (credit capped at SEND_RATE).
C.SEND_INTERVAL = 0.2
C.SEND_RATE = 2

-- Cap on the reusable send-descriptor pool; sends beyond it just allocate.
C.POOL_SEND_DESC = 256

-- Hard bound on queued send chunks. A leg that cannot fit is dropped whole;
-- dropping individual chunks yields an incomplete message anyway.
C.SEND_QUEUE_CAP = 384

-- FRP1 control channel -----------------------------------------------------
-- Control messages are 7-field envelopes whose subject is CTL_SUBJECT
-- (subjects are always GUIDs, so "_frp" never collides). The data field
-- carries "FRP1 <verb> <arg>". Verbs:
--   HELLO <version>  BNet peer probe ("I run FactionRP")
--   HI <version>     handshake reply
--   REQ <subjectGuid> [unitID] [seenAt] [profileID] [cvHash] [m]
--      pull-exchange request: "who has this profile?" unitID lets a server
--      answer straight from the register; seenAt/profileID/cvHash advertise
--      what the requester already holds so stale holders skip their ACK.
--      A trailing "m" marks a sampled mesh REQ (see mesh sampling below):
--      the recipient runs channel REQ arbitration (ACK, then serve only
--      on OK) instead of serving a whispered REQ at once. Servers too
--      old to parse arg6 just serve immediately, which still works.
--   ACK <subjectGuid> <seenAt> [dirSeenAt]
--      "I can serve it, as of <seenAt>"; dirSeenAt is the server's TRP3
--      directory last-seen stamp (profile.time), a second freshness signal
--      for requesters collecting multiple offers.
--   OK  <subjectGuid>   grant: "you may send it"
--   NOK <subjectGuid>   cancel: winner mid-send, data landed elsewhere
-- Control messages are never cached, injected, or relayed.
C.CTL_SUBJECT = "_frp"
C.CTL_PROTO = "FRP1"

-- Seconds a partial multi-chunk message is kept before discard. Must exceed
-- the sender's worst-case drain at SEND_RATE.
C.REASSEMBLY_TIMEOUT = 120

-- Seconds the online BNet game-account list is memoized; enumeration
-- allocates client tables per account, so stale presence is acceptable.
C.BNET_MEMO = 15

-- BNet peer confirmation (FRP1 HELLO/HI handshake). Data goes only to
-- confirmed accounts; unconfirmed ones get rotating HELLO probes.
-- One HELLO per eligibility window: an unanswered probe ignores the
-- account after BNET_PROBE_DEADLINE until BNET_IGNORE_TTL decays it or
-- the account comes online. Confirmations expire BNET_CONFIRM_TTL after
-- the peer's last proof.
C.BNET_CONFIRM_TTL = 600
C.BNET_PROBE_INTERVAL = 5   -- probe ticker cadence (burst + sweep tick)
C.BNET_PROBE_DEADLINE = 60  -- an awaiting probe older than this is ignored
C.BNET_IGNORE_TTL = 600     -- ignore-list decay
C.BNET_HI_COOLDOWN = 30     -- min gap between HI replies to the same account

-- Seconds a sender failing the protocol/malformed gates is blocked at
-- chunk level. Decays so a peer upgrading mid-session recovers.
C.REJECTED_SENDER_TTL = 300

-- Pull exchange. Requests are serial: one subject at a time, REQ'd to a
-- single contact (round-robin over confirmed BNet peers, then guild and
-- community relays). A silent contact drops the subject outright unless it
-- is a total stranger (no shared club/guild, no group, no BNet friend):
-- strangers fall back to a single channel REQ, collecting whispered ACKs
-- for REQ_CHANNEL_WINDOW and granting the freshest offer.
C.REQ_CONTACT_TIMEOUT = 4  -- silent contact drops the request
C.REQ_DATA_TIMEOUT = 120   -- accepted request expires without data
C.REQ_DATA_STALL = 25      -- granted serve dies if no chunk lands this long
C.SERVE_REFRESH_TTL = 3600 -- held copies this fresh serve without a refresh query
C.REQ_COOLDOWN = 60        -- min gap between requests for the same subject
C.REQ_BACKLOG_CAP = 8      -- queued subjects awaiting their turn
C.MOUSEOVER_REQ_DELAY = 3  -- hover this long on an xfac unit before a REQ
C.REQ_SENDER_INTERVAL = 2  -- min gap between inbound unicast REQs per sender
C.FANOUT_INFLIGHT_MAX = 3 -- initiated sends (HELLO probes) allowed queued
C.SERVE_PENDING_CAP = 16 -- bound on granted-or-awaiting serves per peer+subject
C.SERVE_TIMEOUT = 30     -- pending serve expires without an OK

-- Channel fallback. One broadcast REQ per request, only for stranger
-- subjects. REQs park in "chan-wait" while REQ_CHANNEL_INTERVAL has not
-- elapsed since our last broadcast, giving up after REQ_CHANNEL_WAIT_MAX.
-- Inbound channel REQs are throttled per requester at
-- REQ_CHANNEL_SENDER_INTERVAL; we self-rate at the same pace, so only
-- old-version or abusive clients trip it.
C.REQ_CHANNEL_WINDOW = 3          -- collect ACKs this long, then grant best
C.REQ_CHANNEL_INTERVAL = 10       -- min gap between our channel REQs
C.REQ_CHANNEL_WAIT_MAX = 30       -- chan-wait gives up after this
C.REQ_CHANNEL_SENDER_INTERVAL = 10 -- per-requester inbound channel REQ throttle
C.REQ_CHANNEL_ACK_CAP = 8         -- offers recorded per broadcast

-- Mesh sampling. Above REQ_MESH_SAMPLE_AT members the channel leg
-- whispers its REQ (flagged REQ_MESH_FLAG) to REQ_MESH_SAMPLE_SIZE
-- random members instead of broadcasting, bounding the ACK barrage.
C.REQ_MESH_SAMPLE_AT = 10   -- mesh size above which channel REQs sample
C.REQ_MESH_SAMPLE_SIZE = 3  -- random members whispered per sampled REQ
C.REQ_MESH_FLAG = "m"       -- REQ arg6 marker: sampled mesh request

-- Held-copy suppression: after we accept a profile, local requests for the
-- subject are suppressed for REQ_HELD_TTL while the RP AddOn's register
-- still holds it (db.seen[guid].holdUntil). A register purge releases the
-- suppression early.
C.REQ_HELD_TTL = 1800

-- A servable server refreshes its held copy before ACKing; the reply
-- defers until data lands or the delay elapses.
C.REQ_FRESHEN_DELAY = 2 -- seconds a serve waits for a refresh
C.REQ_FRESHEN_MAX = 16  -- bound on deferred replies

-- Channel serve cooldown: while a granted serve's chunks sit in the send
-- queue we ACK no broadcast REQs at all, and once a mesh serve's last
-- chunk leaves the queue we stay muted for a window scaled by mesh size —
-- SERVE_CHANNEL_COOLDOWN_MIN on a thin mesh, growing linearly to the MAX
-- at SERVE_MESH_DENSE channel members (CHANNEL_COUNT_UPDATE count). The
-- mesh spreads each profile, so on a dense mesh back-to-back serves are
-- redundant load; on a thin one availability beats dedup. REQs for our
-- own GUID bypass it; we are authoritative for ourselves.
C.SERVE_CHANNEL_COOLDOWN_MIN = 10
C.SERVE_CHANNEL_COOLDOWN_MAX = 60
C.SERVE_MESH_DENSE = 10

-- Freshness floor ------------------------------------------------------------
--
-- db.seen[guid] persists the best "as of" claim accepted per subject
-- ({ at, unitID, pid, cv, addon }). Copies claiming older than the floor
-- are rejected; the floor is clock-derived, so a skew tolerance applies.
C.FRESHNESS_SKEW = 3600

-- Version announcement (issue #19) -----------------------------------------
--
-- Once per session we broadcast "VER <version>" on the comm channel, read
-- from the .toc via C_AddOns.GetAddOnMetadata. Receivers print an update
-- notice when it is newer.
C.VER_BROADCAST_DELAY = 15  -- seconds after login before the first attempt
C.VER_BROADCAST_RETRY = 30  -- gap between retries (channel join pending)
C.VER_BROADCAST_ATTEMPTS = 3 -- total attempts before giving up
-- The previous channel is joined only for the announcement; membership is
-- held this long so the queue can flush, then we leave.
C.VER_PREV_CHANNEL_HOLD = 30

-- Caching -------------------------------------------------------------------

-- Time-to-live for a cached profile, in seconds (5 minutes per the design).
C.CACHE_TTL = 300

-- How often (seconds) the cache sweeps and removes expired entries.
C.CACHE_SWEEP_INTERVAL = 60

-- Received-profile re-publish ------------------------------------------------
--
-- When the RP AddOn reports profile data arriving over its own channels
-- (ProfileAdapter:registerReceivedListener), the Scanner re-extracts and
-- publishes it to the local cache. These bounds cap the extraction work.
--
-- Receipts arrive as per-section messages; RECEIVED_DEBOUNCE coalesces them
-- after the last one, and RECEIVED_JITTER staggers simultaneous updates.
C.RECEIVED_DEBOUNCE = 1.5
C.RECEIVED_JITTER = 4

-- Received-trigger publishes drain through a bounded queue: one extraction
-- per RECEIVED_ORIGIN_INTERVAL, oldest dropped on overflow.
C.RECEIVED_ORIGIN_INTERVAL = 5
C.RECEIVED_ORIGIN_QUEUE = 20

-- Seconds a GUID-resolution result is memoized, bounding roster scan cost.
C.GUID_RESOLVE_MEMO = 60

-- Whisper relay confirmation (HELLO/HI over addon whispers, same lifecycle
-- as the BNet handshake). Any parseable inbound whisper confirms the sender.
-- Ignore is offline-aware, not time-driven: a member stays ignored while
-- continuously online (their silence is the answer) and is un-ignored only
-- after being observed offline by the roster scan — silence during an
-- absence explains itself, so they earn a retry when they return.
C.RELAY_PROBE_INTERVAL = 30 -- gap between whisper probe bursts
C.RELAY_PROBE_BURST = 5     -- probe targets per burst
C.RELAY_CONFIRM_TTL = 600   -- relay confirmation expires without fresh proof
C.RELAY_PROBE_COOLDOWN = 45 -- per-target probe gap AND the answer window
C.RELAY_PROBE_MAX = 1       -- unanswered probes before ignoring
C.RELAY_HI_COOLDOWN = 30    -- min gap between HI replies to the same target

-- Seconds the scanned club roster is memoized. Stale rosters rebuild
-- incrementally, ROSTER_SLICE member lookups per frame. Opening the
-- Communities UI triggers an early rebuild — member data streams in for
-- the UI anyway, so the scan is cheap then. The longer memo funds faster
-- probe bursts below.
C.COMM_ROSTER_MEMO = 90
C.ROSTER_SLICE = 20

-- Club member data streams in lazily; a build that raced it retries this
-- many seconds out instead of waiting a full memo window.
C.ROSTER_RETRY = 5

-- Min gap between UI-triggered roster rebuilds (Communities UI opens), so
-- frame spam cannot restart builds.
C.ROSTER_UI_REFRESH = 30

-- Injection into the RP AddOn's register is queued: register writes fire
-- the AddOn's own events, so bursts amortize at INJECT_BURST per interval.
C.INJECT_INTERVAL = 0.5
C.INJECT_BURST = 2

-- Debug & statistics ---------------------------------------------------------
--
-- Debug output splits into independently-toggleable categories
-- (ns.db.debug[category]); `all` overrides every category.
C.DEBUG_CATEGORIES = {

	{ key = "receive",   desc = "Log each fully-received inbound message" },
	{ key = "cache",     desc = "Log cache store/update/refresh results" },
	{ key = "queue",     desc = "Log received-profile queueing and skips" },
	{ key = "fanout",    desc = "Log the REQ contact pick" },
	{ key = "chunks",    desc = "Log every wire chunk in/out (very noisy)" },
	{ key = "targets",   desc = "Allow pinned whisper targets to send" },
	{ key = "peers",     desc = "Log BNet probe/confirm and REQ exchange events" },
	{ key = "stats",     desc = "Collect traffic statistics (/frp stats)" },
	{ key = "reorders",	 desc = "Print reorder ops in chat."}
}

-- Statistics collection is session-only and bounded: reservoirs cap samples,
-- rates use a bucketed ring so memory stays flat.
C.STATS_RESERVOIR = 256 -- samples kept for median size/duration queries
C.STATS_RECENT = 50     -- per-message records kept in the recent ring buffer
C.STATS_RATE_WINDOW = 60 -- seconds covered by the rolling rate window
C.STATS_RATE_BUCKETS = 12 -- buckets the window is divided into

-- Profiles ------------------------------------------------------------------

-- Identifiers for the AddOn a profile originated from; sent on the wire so
-- the receiver picks the right adapter.
C.SOURCE = {
	TRP3 = "TRP3",
}
