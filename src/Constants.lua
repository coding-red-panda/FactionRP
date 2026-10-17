-- Constants.lua
--
-- Central, immutable configuration for the AddOn. Every magic value (prefixes,
-- timings, separators, enum keys) lives here so behaviour can be tuned in one
-- place and the rest of the code reads declaratively.

local _, ns = ...

local C = {}
ns.Const = C

-- Identity -----------------------------------------------------------------

C.ADDON_NAME = "FactionRP"
C.VERSION = "0.3.4"

-- Wire-protocol generation. Stamped into every envelope and the comm-channel
-- name; peers advertising a lower PROTO_MAJOR are rejected outright, so each
-- incompatible protocol change gets a hard partition (bump this).
C.PROTO_MAJOR = 4

-- Communication -------------------------------------------------------------

-- Addon-message prefix registered with the client. Must be <= 16 characters
-- and unique enough not to collide with other AddOns.
C.MSG_PREFIX = "FactionRP"

-- Name of the hidden chat channel used to relay messages between same-faction
-- clients (joined via JoinTemporaryChannel). Carries the protocol generation
-- so older-protocol clients sit on a disjoint channel and never interop.
C.COMM_CHANNEL = "frp" .. C.PROTO_MAJOR .. "comms" -- e.g. "frp4comms"
C.COMM_CHANNEL_PROTO3 = "frp3comms"

-- Field separator used inside a logical message payload. `||` is chosen
-- because it virtually never appears in serialized profile data.
C.SEPARATOR = "||"

-- A single in-game addon message is capped at 255 bytes. We reserve a margin
-- for the chunk-framing header (message id, index, total) and keep payload
-- bytes per chunk below this value.
C.CHUNK_SIZE = 220

-- Outbound send pacing. THE outbound rate dial: SEND_RATE chunks per second,
-- released on a SEND_INTERVAL tick via a fractional token bucket (credit
-- accumulates at SEND_RATE*SEND_INTERVAL per tick, capped at SEND_RATE so an
-- idle queue cannot bank an unbounded burst). Dial the whole send rate by
-- editing this one number.
C.SEND_INTERVAL = 0.2
C.SEND_RATE = 2

-- Cap on the reusable send-descriptor pool (the outbound queue stores pooled
-- record tables instead of closures). Beyond this depth sends simply allocate
-- — the pool bounds reuse, never work.
C.POOL_SEND_DESC = 256

-- Hard bound on queued send chunks. Outbound demand (inbound rate x chunks
-- x legs) can exceed the drain rate during bursts, and an unbounded queue
-- then grows monotonically with every chunk leaving stale. A leg that
-- cannot fit entirely is dropped whole — dropping individual chunks just
-- produces an incomplete message at the far end while still wasting the
-- siblings' sends.
C.SEND_QUEUE_CAP = 384

-- FRP1 control channel -----------------------------------------------------
-- Control messages are ordinary 7-field envelopes whose subject is the
-- reserved CTL_SUBJECT token (a subject is always a player GUID, so "_frp"
-- can never collide). The data field carries "FRP1 <verb> <arg>": FRP1 is the
-- control-protocol revision for forward compatibility. Verbs:
--   HELLO <version>  BNet peer probe ("I run FactionRP")
--   HI <version>     handshake reply
--   REQ <subjectGuid> [unitID] [seenAt] [profileID] [cvHash]
--      pull-exchange request: "who has this profile?" The unitID (subject's
--      "Name-Realm") lets any server answer straight from the RP AddOn's
--      register; the guid remains the wire identity carried back by
--      ACK/OK/NOK. seenAt/profileID/cvHash advertise what the requester
--      already holds so stale holders can skip their ACK.
--   ACK <subjectGuid> <seenAt>   "I can serve it, as of <seenAt>"
--   OK  <subjectGuid>   grant: "you may send it"
--   NOK <subjectGuid>   cancel: winner mid-send, data landed elsewhere
-- Control messages are never cached, injected, or relayed.
C.CTL_SUBJECT = "_frp"
C.CTL_PROTO = "FRP1"

-- How long (seconds) a partially-received multi-chunk message is kept before a
-- missing chunk causes it to be discarded. Must exceed the sender's worst-case
-- drain at SEND_RATE. At 2 chunks/s this covers ~240-chunk messages.
C.REASSEMBLY_TIMEOUT = 120

-- How long (seconds) the online Battle.net game-account list is memoized.
-- Enumerating WoW BNet friends allocates client tables per account, so the
-- REQ fanout reuses a cached list; a few seconds of presence staleness is
-- tolerable.
C.BNET_MEMO = 15

-- BNet peer confirmation (FRP1 HELLO/HI handshake). Data legs go only to
-- confirmed accounts; unconfirmed accounts receive HELLO probes on a rotating
-- cooldown. BNET_PROBE_MAX unanswered probes mark the account ignored for
-- BNET_IGNORE_TTL seconds (cleared early by friend-presence events).
-- A confirmation expires BNET_CONFIRM_TTL seconds after the peer's last
-- inbound proof, so a friend who stops running FactionRP decays back to
-- probe status on its own.
C.BNET_CONFIRM_TTL = 600
C.BNET_PROBE_INTERVAL = 10  -- probe ticker cadence (>=1 probe per tick)
C.BNET_PROBE_COOLDOWN = 45  -- per-account gap between probes
C.BNET_PROBE_MAX = 3        -- unanswered probes before ignoring
C.BNET_IGNORE_TTL = 1800    -- ignore-list decay
C.BNET_HI_COOLDOWN = 30     -- min gap between HI replies to the same account

-- Senders whose messages fail the protocol/malformed gates are blocked at
-- chunk level for this long: their chunks are dropped before reassembly, so
-- old-protocol peers cannot burn our inbound processing. Decays so a peer
-- that upgrades mid-session recovers automatically.
C.REJECTED_SENDER_TTL = 300

-- Pull exchange (REQ -> ACK -> OK -> data; losing ACKs simply time out).
-- Timeouts bound a
-- pending request; REQ_COOLDOWN keeps repeated sightings of the same subject
-- from re-requesting a profile nobody could serve.
C.REQ_ACK_TIMEOUT = 15   -- open request expires without an ACK
C.REQ_DATA_TIMEOUT = 120 -- granted request expires without data
C.REQ_COOLDOWN = 60      -- min gap between requests for the same subject
C.REQ_MAX_PENDING = 32   -- bound on outstanding requests

-- Request fanouts are also paced globally. Mouseover across a crowd of new
-- faces produces sightings faster than the mesh should hear them, and every
-- fanout wakes the whole channel plus its whisper legs. Fanout at most one time
-- per REQ_ISSUE_INTERVAL seconds; further subjects wait in a small
-- dedup'd FIFO.
C.REQ_ISSUE_INTERVAL = 4 -- min seconds between request fanouts
C.REQ_BACKLOG_CAP = 8    -- deferred subjects awaiting fanout
C.FANOUT_INFLIGHT_MAX = 3 -- initiated sends (REQ fanouts, HELLO probes)
                         -- allowed outstanding in the send queue
C.SERVE_PENDING_CAP = 16 -- bound on granted-or-awaiting serves per peer+subject
C.SERVE_TIMEOUT = 30     -- pending serve expires without an OK

-- Outbound serve breaker: once SERVE_RATE_LIMIT granted serves (ACKs we
-- were OK'd on) land within SERVE_RATE_WINDOW seconds we stop answering
-- REQs for SERVE_RATE_MUTE seconds. Only winning the ACK race counts,
-- volunteering and losing is free. REQs for our own GUID bypass the
-- breaker: we are the authoritative server for ourselves.
C.SERVE_RATE_WINDOW = 30
C.SERVE_RATE_LIMIT = 10
C.SERVE_RATE_MUTE = 60

-- Freshness floor ------------------------------------------------------------
--
-- db.seen[guid] persists the best "as of" claim we have accepted per subject
-- ({ at, unitID, pid, cv, addon }): servers stamp serves with their last-seen
-- time instead of the serve time, and copies claiming older than our floor are
-- rejected. The floor is clock-derived on both ends, so comparisons carry a
-- skew tolerance.
C.FRESHNESS_SKEW = 3600

-- Version announcement (issue #19) -----------------------------------------
--
-- Once per session, shortly after login, we broadcast our addon version
-- ("VER <version>") on the same-faction comm channel, read from the .toc
-- via C_AddOns.GetAddOnMetadata (see Broadcast.lua's ownVersion) rather
-- than C.VERSION. Receivers compare it against their own addon version and
-- print an update notice when it is newer. The announcement is retried
-- while the channel join is still pending.
C.VER_BROADCAST_DELAY = 15  -- seconds after login before the first attempt
C.VER_BROADCAST_RETRY = 30  -- gap between retries (channel join pending)
C.VER_BROADCAST_ATTEMPTS = 3 -- total attempts before giving up
-- The previous generation's channel is joined only to launch the
-- announcement; membership is held this long so the paced queue can flush
-- the chunk, then we leave again.
C.VER_PREV_CHANNEL_HOLD = 30

-- Caching -------------------------------------------------------------------

-- Time-to-live for a cached profile, in seconds (5 minutes per the design).
C.CACHE_TTL = 300

-- How often (seconds) the cache sweeps and removes expired entries.
C.CACHE_SWEEP_INTERVAL = 60

-- Received-profile re-publish ------------------------------------------------
--
-- When the RP AddOn reports profile data arriving over its own comm channels
-- (see ProfileAdapter:registerReceivedListener), the Scanner re-extracts it
-- and publishes it to the local cache so peers can request it. Under the pull
-- model this produces no wire traffic; these values bound the extraction
-- work that trigger can produce:
--
-- Receipts arrive as several per-section messages; we coalesce them by waiting
-- RECEIVED_DEBOUNCE seconds after the last one. A further random delay of up
-- to RECEIVED_JITTER seconds staggers simultaneous updates so they do not all
-- land on the same drain tick.
C.RECEIVED_DEBOUNCE = 1.5
C.RECEIVED_JITTER = 4

-- Received-trigger publishes drain through a bounded pending queue: at most
-- one extraction runs per RECEIVED_ORIGIN_INTERVAL seconds, and the queue
-- holds at most RECEIVED_ORIGIN_QUEUE entries (the oldest are dropped on
-- overflow).
C.RECEIVED_ORIGIN_INTERVAL = 5
C.RECEIVED_ORIGIN_QUEUE = 20

-- How long (seconds) a GUID-resolution result for a unitID is memoized, to
-- bound the cost of Battle.net/club roster scans.
C.GUID_RESOLVE_MEMO = 60

-- Community relays (cross-faction) ------------------------------------------
--
-- Opposite-faction members of our own WoW communities are reachable by addon
-- whisper, so profile REQUESTs fan out to a capped rotating set of them.
-- These legs carry single-chunk control messages, and every FRP client
-- maintains its own relay lists — coverage is distributed across requesters,
-- so a modest per-request cap suffices.
C.COMM_RELAY_LIMIT = 5

-- The guild is a second, independent whisper leg (cross-faction guilds exist):
-- its own capped target list on top of the community one.
C.GUILD_RELAY_LIMIT = 5

-- No single member should act as a relay server: each contact may be used at
-- most COMM_USAGE_LIMIT times per COMM_USAGE_WINDOW seconds. Exhausted
-- contacts are only re-used when too few fresh candidates remain — coverage
-- is never dropped for lack of fresh targets.
C.COMM_USAGE_LIMIT = 2
C.COMM_USAGE_WINDOW = 60

-- Whisper relay confirmation (HELLO/HI over addon whispers — same lifecycle
-- shape as the BNet handshake). A candidate gets at most RELAY_PROBE_MAX
-- probes before an unanswered one ignores it for RELAY_IGNORE_TTL; any
-- parseable inbound whisper confirms the sender for RELAY_CONFIRM_TTL.
C.RELAY_PROBE_INTERVAL = 120 -- gap between whisper probe bursts
C.RELAY_PROBE_BURST = 5      -- probe targets per burst
C.RELAY_CONFIRM_TTL = 600    -- relay confirmation expires without fresh proof
C.RELAY_PROBE_COOLDOWN = 45  -- per-target probe gap AND the answer window
C.RELAY_PROBE_MAX = 1        -- unanswered probes before ignoring
C.RELAY_IGNORE_TTL = 7200    -- ignore-list decay (2h)
C.RELAY_HI_COOLDOWN = 30     -- min gap between HI replies to the same target

-- How long (seconds) the scanned club roster (factions, GUIDs and opposite-
-- faction online members) is memoized. A stale roster is rebuilt
-- incrementally — ROSTER_SLICE member lookups per frame — so large
-- communities never stall a frame.
C.COMM_ROSTER_MEMO = 45
C.ROSTER_SLICE = 20

-- Club member data (notably `faction`) streams in lazily. A rebuild that
-- collected GUIDs but saw no faction values is assumed to have raced the
-- stream: it is not published, and a retry is scheduled this many seconds
-- out instead of waiting a full memo window.
C.ROSTER_RETRY = 5

-- Injection into the RP AddOn's register (populating its directory as
-- profiles arrive) is queued: register writes fire the AddOn's own update/UI events,
-- so bursts are amortized at INJECT_BURST entries per INJECT_INTERVAL.
C.INJECT_INTERVAL = 0.5
C.INJECT_BURST = 2

-- Debug & statistics ---------------------------------------------------------
--
-- Debug output is fractionalised into independently-toggleable categories
-- (ns.db.debug[category]); the `all` flag overrides every category. This is
-- the canonical, ordered list a future settings UI can enumerate — `all` is
-- deliberately absent (it is an override, not a category).
C.DEBUG_CATEGORIES = {

	{ key = "receive",   desc = "Log each fully-received inbound message" },
	{ key = "cache",     desc = "Log cache store/update/refresh results" },
	{ key = "queue",     desc = "Log received-profile queueing and skips" },
	{ key = "fanout",    desc = "Log per-leg whisper fanout counts" },
	{ key = "chunks",    desc = "Log every wire chunk in/out (very noisy)" },
	{ key = "targets",   desc = "Allow pinned whisper targets to send" },
	{ key = "peers",     desc = "Log BNet probe/confirm and REQ exchange events" },
	{ key = "stats",     desc = "Collect traffic statistics (/frp stats)" },
	{ key = "reorders",	 desc = "Print reorder ops in chat."}
}

-- Statistics collection is session-only and bounded: reservoirs cap how many
-- samples are kept for median/inspection, and rates use a bucketed ring so
-- memory stays flat regardless of session length.
C.STATS_RESERVOIR = 256 -- samples kept for median size/duration queries
C.STATS_RECENT = 50     -- per-message records kept in the recent ring buffer
C.STATS_RATE_WINDOW = 60 -- seconds covered by the rolling rate window
C.STATS_RATE_BUCKETS = 12 -- buckets the window is divided into

-- Profiles ------------------------------------------------------------------

-- Identifiers for the AddOn a profile originated from. Stored on every cache
-- entry and sent on the wire so the receiver knows which adapter to use.
C.SOURCE = {
	TRP3 = "TRP3",
}
