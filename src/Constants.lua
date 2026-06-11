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
C.VERSION = "0.1.0"

-- Communication -------------------------------------------------------------

-- Addon-message prefix registered with the client. Must be <= 16 characters
-- and unique enough not to collide with other AddOns.
C.MSG_PREFIX = "FactionRP"

-- Name of the hidden chat channel used to relay messages between same-faction
-- clients (joined via JoinTemporaryChannel).
C.COMM_CHANNEL = "FactionRP"

-- Field separator used inside a logical message payload. `||` is chosen
-- because it virtually never appears in serialized profile data.
C.SEPARATOR = "||"

-- A single in-game addon message is capped at 255 bytes. We reserve a margin
-- for the chunk-framing header (message id, index, total) and keep payload
-- bytes per chunk below this value.
C.CHUNK_SIZE = 220

-- Outbound send pacing. To avoid the client silently dropping messages under
-- its own throttle, we release at most SEND_BURST queued messages every
-- SEND_INTERVAL seconds rather than sending in one burst.
C.SEND_INTERVAL = 0.2
C.SEND_BURST = 3

-- How long (seconds) a partially-received multi-chunk message is kept before a
-- missing chunk causes it to be discarded.
C.REASSEMBLY_TIMEOUT = 60

-- Relaying to the regular (non-Battle.net) friends list is redundant with the
-- same-faction comm channel: any same-faction friend running the AddOn already
-- receives channel traffic, and connected realms share channels. The capability
-- exists per the design, but is disabled by default to avoid duplicate traffic.
C.RELAY_TO_FRIENDS = false

-- Caching -------------------------------------------------------------------

-- Time-to-live for a cached profile, in seconds (5 minutes per the design).
C.CACHE_TTL = 300

-- How often (seconds) the cache sweeps and removes expired entries.
C.CACHE_SWEEP_INTERVAL = 60

-- Profiles ------------------------------------------------------------------

-- The profile sections we replicate in v1. These mirror the section keys used
-- by TRP3's register so the TRP3 adapter can map directly onto them.
-- (ABOUT is intentionally excluded from v1 per the README.)
C.INFO_TYPE = {
	CHARACTERISTICS = "characteristics",
	CHARACTER = "character",
	MISC = "misc",
}

-- Identifiers for the AddOn a profile originated from. Stored on every cache
-- entry and sent on the wire so the receiver knows which adapter to use.
C.SOURCE = {
	TRP3 = "TRP3",
}
