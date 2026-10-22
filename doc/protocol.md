# FactionRP Wire Protocol

This document describes the on-the-wire behavior of FactionRP: message
formats, chunking, the FRP1 control channel, the BNet peer handshake, and the
pull exchange that moves profile data cross-faction. All constants referenced
live in `src/Constants.lua`.

## Transport

All traffic uses the addon-message prefix `FactionRP` (`C.MSG_PREFIX`, ≤16
bytes) and travels over these mediums:

| Medium     | API path                                         | Reach                        |
|------------|--------------------------------------------------|------------------------------|
| `CHANNEL`  | `SendAddonMessage` on the `frp<N>comms` channel  | same-faction subscribers     |
| `PARTY`/`RAID`/`INSTANCE_CHAT` | `SendAddonMessage`      | current group                |
| `WHISPER`  | `SendAddonMessage` to a player                   | cross-faction club members   |
| `BNET`     | `BNSendGameData` to a `gameAccountID`            | BNet friends, any faction    |

`frp<N>comms` is an ordinary custom chat channel (like `/1`), joined via
`JoinTemporaryChannel`. Custom channels are faction-scoped — an
opposite-faction player can never be on it — so its job in the exchange is
the **same-faction holder pool**: every faction-mate who previously pulled
a subject is a candidate server, and one channel chunk reaches all of them.
Channel sends echo back to the sender; those self-echoes are dropped on
receipt (`sender == our GUID`).

There is no "COMMUNITY" medium — a club cannot carry addon messages at
all. Cross-faction addon whispers are only possible between members of the
same community/guild club, so club membership is what makes `WHISPER`
deliveries *legal* across factions; the roster exists purely to enumerate
those whisper-reachable targets. BNet works between any friends and ignores
faction entirely.

**Every leg is a single hop.** The requester unicasts `REQ` to one contact
at a time; a recipient that can serve replies `ACK` and sends the profile
*directly* to the requester. "Relay" in this document means a reachable
cross-faction *endpoint* — never a forwarder: no client relays or re-sends
anything on behalf of another. `REQ`s are broadcast only as a fallback,
once per request and only for stranger subjects (see "The pull exchange");
a channel answer can only be a faction-mate's cached copy.

Sends are routed through AddOn_Chomp's `SendAddonMessage`/`BNSendGameData`
when available (raw ChatThrottleLib passthrough — the prefix and text reach
receivers unwrapped), falling back to the raw APIs.

## Message envelope

A logical message is a single string of eight `||`-separated fields
(`C.SEPARATOR`):

```
sender || subject || unitID || addon || originTime || contentVersion || protoMajor || data
```

| Field            | Meaning                                                          |
|------------------|------------------------------------------------------------------|
| `sender`         | GUID of the *immediate* sender (us whenever we originate/serve)  |
| `subject`        | GUID of the profile owner, or the reserved token `_frp`          |
| `unitID`         | "Name-Realm" of the subject                                      |
| `addon`          | source RP AddOn id (`TRP3`) — `"FRP"` on control messages        |
| `originTime`     | freshness claim: `time()` for self-serves; the holder's last-seen "as of" stamp otherwise |
| `contentVersion` | opaque version string (`c#:k#:m#` section versions)              |
| `protoMajor`     | wire-protocol generation (`C.PROTO_MAJOR`, currently 5)          |
| `data`           | payload; may itself contain `||` — it is always the last field   |

A message is malformed unless all seven separators are present and
`originTime` parses as a number.

### Protocol versioning

`protoMajor` is a hard interop gate: receivers reject any envelope
advertising a lower generation (`statsError("proto_old")`), *before* any
peer-state side effect — a too-old or forged message cannot confirm a relay,
serve a request, or enter the cache. The comm channel also carries the
generation (`frp5comms`), so older-protocol clients sit on a disjoint channel
by construction. On load and on every (re)join we additionally *leave* the
legacy `FactionRP` channel and any `frp<N>comms` channel of a different
generation — channel membership survives `/reload` (until logout), so an
upgraded client would otherwise keep hearing the old fleet for the session.
Bump `C.PROTO_MAJOR` on any wire-incompatible change.

Because the version field lives inside the envelope, a chunk cannot be
classified until its message is fully reassembled. To keep old-protocol
senders from burning inbound processing anyway, any sender whose completed
message fails the version gate (or fails to parse at all) is recorded in a
sender-level blocklist: subsequent chunks from that sender are dropped
before reassembly for `REJECTED_SENDER_TTL` (300s). The block decays so a
peer that upgrades mid-session recovers automatically; blocked traffic is
still counted in inbound byte stats, it just never reaches the assembler.

- **Data envelopes**: `data` is the LibSerialize+LibDeflate-encoded profile
  table `{ profileID, sections }`.
- **Control envelopes**: `subject` is `_frp`; `data` is plain text
  `FRP1 <verb> <arg>`.

## Chunking and reassembly

Addon messages cap at 255 bytes. Each logical message is split into chunks
of at most `C.CHUNK_SIZE` (220) payload bytes with a framing header:

```
<messageId>:<index>:<total>:<payload>
```

Receivers reassemble per `(senderKey, messageId)` (two-level map — senderKey
is the whisper name/channel sender or `bn:<gameAccountID>`). Partial buffers
expire after `C.REASSEMBLY_TIMEOUT` (120s); duplicate chunks are counted and
ignored.

## Pacing and the send queue

Every outbound chunk — data or control — queues through a paced send queue:

- **Rate**: `C.SEND_RATE` chunks per second (the single outbound dial),
  released on a `C.SEND_INTERVAL` (0.2s) tick via a fractional token bucket.
- **Bound**: `C.SEND_QUEUE_CAP` (384) chunks. A *leg* (one message to one
  destination) that cannot fit entirely is dropped whole — partial legs only
  produce guaranteed-incomplete messages downstream.

## The FRP1 control channel

Control messages are ordinary envelopes with `subject = "_frp"` and
`data = "FRP1 <verb> <arg>"`. `FRP1` is the control-protocol revision.
Control messages are **never cached, never injected, never relayed** — they
terminate at the recipient. Clients without FRP1 parse the envelope, fail to
decode `data` as a profile, and drop it harmlessly.

| Verb    | Args                | Meaning                                     |
|---------|---------------------|---------------------------------------------|
| `HELLO` | addonVer            | BNet probe — "I run FactionRP"              |
| `HI`    | addonVer            | handshake reply                             |
| `VER`   | addonVer            | one-time version broadcast on login (see below) |
| `REQ`   | subjectGuid [unitID] [seenAt] [pid] [cvHash] | pull request — "who can serve this profile?" |
| `ACK`   | subjectGuid [seenAt]| "I can serve it, as of `seenAt`"            |
| `OK`    | subjectGuid         | grant — "you may send it"                   |
| `NOK`   | subjectGuid         | cancel — winner mid-send, data landed elsewhere |

`REQ` is the only multi-argument verb:

- `unitID` — the subject's `"Name-Realm"` as computed by the requester's RP
  AddOn — the exact key its register uses. It is optional
  (adapter-less requesters send the guid alone) and lets any server answer
  straight from its register without local guid→unitID state.
- `seenAt` — the requester's freshness floor: the best "as of" claim it has
  accepted for the subject (see *Freshness floor* below).
- `pid` — the profileID the requester's copy is bound to, or `-`.
- `cvHash` — an 8-hex-char hash of the requester's contentVersion, or `-`.

`seenAt`/`pid`/`cvHash` are only sent when `unitID` is present. A server
whose own claim (`seenAt`) is no newer than `seenAt` *and* whose held
profileID or contentVersion matches suppresses its ACK — serving identical
or staler lineage would only cost a wasted data leg. A server holding a
*different* profileID (the subject switched profiles) still ACKs: the
requester's floor arbitrates on arrival anyway.

`ACK` carries the server's own `seenAt` claim; the requester denies (no
`OK`) an ACK whose claim is below its floor — a fast-but-stale holder can
never win the grant. `OK`/`NOK` still carry the guid only — it is the wire
identity.

### BNet peer confirmation

We never assume a silent BNet friend runs FactionRP. Per-account state
(session-only):

```
unconfirmed → awaiting → (unanswered past deadline) → ignored
                 ↑              │                         │
                 └──────────────┴── TTL / presence ───────┘
any parseable inbound message → confirmed (10 min TTL)
```

- **Probing**: every `BNET_PROBE_INTERVAL` (5s) tick we burst `HELLO <ver>`
  to every eligible account — unconfirmed, non-ignored, and not already
  awaiting — bounded only by the shared in-flight send budget; the paced
  queue does the wire throttling. Each queued probe marks the account
  awaiting. The account pool is filtered at enumeration:
  same-faction WoW characters (`factionName` matching ours) are excluded —
  the faction channel reaches them already, so they are never a valid
  cross-faction relay. Unknown/unreadable factions stay in the pool.
- **Confirming**: any complete, parseable FRP message from an account —
  `HELLO`, `HI`, `REQ`, or data — confirms it for `BNET_CONFIRM_TTL` (10min).
- **Replying**: `HELLO` is answered with `HI <ver>` (rate-limited to one
  per `BNET_HI_COOLDOWN`=30s per account). `HI` is never answered — the
  exchange terminates after one round-trip.
- **Ignoring**: a probe unanswered past `BNET_PROBE_DEADLINE` (60s — covers
  a busy peer's queue drain) benches the account for `BNET_IGNORE_TTL`
  (10min). `BN_FRIEND_ACCOUNT_ONLINE` clears
  the ignore *of the account that logged in* (resolved friendId →
  gameAccountInfo) with a fresh probe slate — other accounts' ignores stay
  put. `BN_FRIEND_INFO_CHANGED`/`FRIENDLIST_UPDATE` merely invalidate the
  online-account memo (they fire on zone/status churn and would otherwise
  resurrect ignored accounts before their TTL). `BN_DISCONNECTED` wipes
  the map.
- **Data and REQ legs on BNet go to confirmed accounts only.**

Whisper peers (cross-faction club members) use the same probe/confirm/ignore
lifecycle as BNet accounts:

- **Probing**: bursts of up to `RELAY_PROBE_BURST` (5) whispered
  `HELLO <ver>`s every `RELAY_PROBE_INTERVAL` (30s), walked in order by a
  rotating cursor — guild members before community members, so every
  candidate gets a turn and unanswered probes never repeat on the same
  people. Each candidate gets exactly `RELAY_PROBE_MAX` (1) probe; a
  whispered `HELLO` is answered `HI` (rate-limited per sender by
  `RELAY_HI_COOLDOWN`=30s).
- **Confirming**: any parseable inbound whisper from an opposite-faction
  club member — `HI`, `ACK`, `REQ`, or data — confirms them for
  `RELAY_CONFIRM_TTL` (10min) and clears probe/ignore state. Confirmed
  relays get fanout priority and are never probed — real inbound traffic
  is the only thing keeping them warm, so a relay that goes silent decays
  back to unconfirmed on its own.
- **Ignoring**: an unanswered probe past its answer window
  (`RELAY_PROBE_COOLDOWN`=45s) kicks the target to the ignore list at the
  next rotation pass. Ignore is *offline-aware*, not time-driven: a
  member stays ignored while continuously online — their silence is the
  answer — and is un-ignored only after being observed *offline* by the
  roster scan, since silence during an absence explains itself. They earn
  a retry when they return. Ignored targets are skipped by `REQ` fanouts
  too. The underlying club roster is memoized `COMM_ROSTER_MEMO` (90s)
  and rebuilt incrementally; opening the Communities UI forces an early
  rebuild (rate-gated `ROSTER_UI_REFRESH`=30s) because member data streams
  in for the UI anyway. `startRosterBuild` itself no-ops while a build is
  in flight, so neither entry point can start or queue an overlapping
  scan.

`REQ` whisper legs reach only proven targets — confirmed BNet peers and
confirmed whisper relays; the unconfirmed roster is the probe rotation's
job, so a request never whispers strangers.

### Version announcement (`VER <addonVer>`)

Once per session, shortly after login, every client broadcasts its addon
version — a `VER <addonVer>` control chunk (addonVer read from the
.toc's `## Version:` via `C_AddOns.GetAddOnMetadata`) on the same-faction comm
channel only (no BNet/whisper legs; faction-mates logging in with an updated
build keep the channel covered anyway). Because old-generation peers sit on
a disjoint channel and could never hear the announcement otherwise, the
broadcast also joins the previous generation's channel
(`C.COMM_CHANNEL_PROTO3`, currently `frp3comms`) just long enough to launch
the chunk there — membership is dropped `VER_PREV_CHANNEL_HOLD` (30s) later.
Proto-3 clients accept a proto-4 `VER` (the gate only rejects *lower*
generations), so the notice still reaches them. A receiver that hears a newer version
than its own prints a chat notice that it is outdated. Notices are deduped by
the highest version already announced that session, so a wave of peers
logging in cannot spam the chat; `/frp status` shows the newest version
announced by any peer. No reply is ever sent — discovery/backpressure is not
the goal, awareness is.

## The pull exchange

Profiles move on demand. A pull is triggered when the user mouseovers or
targets an opposite-faction player whose profile we do not hold fresh.
Requests are **serial**: at most one subject is in flight, and each subject
is tried against exactly one contact. A round-robin cursor walks the
contact roster so every contact serves at most one request per cycle:

1. confirmed BNet peers (subject-first when the subject themselves is a
   BNet-reachable FRP peer — a self-serve is authoritative),
2. confirmed guild-club relays,
3. confirmed community-club relays.

The cursor wraps after the last contact; new requests resume from the
first.

```
requester                                one contact
    │  REQ <guid> [unitID] [seenAt] [pid] [cvHash] ─► (direct whisper/BNet)
    │                                          └ can serve? → ACK + data
    │                                            cannot?  → silence
    │  ◄── ACK <guid> <seenAt> [dirSeenAt] ── opens the data window
    │  ◄── data envelope ── holder serves direct
```

Silence is the only rejection — there is no `NOK` on the unicast path.
After the ACK the requester waits for the profile; the window is bounded
by `REQ_DATA_TIMEOUT` (120s, covering TRP3's own 60s query lifetime plus
margin) and by a stall watch — no chunk from the grantee for
`REQ_DATA_STALL` (25s) ends it early.

**Channel fallback.** When the unicast leg fails — no reachable contact,
a silent contact, or a serve that stalled or expired — the subject gets
one channel attempt *if it is a stranger*: the fallback is skipped when
the subject shares a guild or community club with us, is a BNet friend,
or sits in our group, because those relations already provide a native
or direct pull path. The fallback broadcasts a single `REQ` on
`frp<N>comms`, collects whispered `ACK` offers for
`REQ_CHANNEL_WINDOW` (3s), then `OK`s the offer with the best score —
`max(seenAt claim, dirSeenAt)` where `dirSeenAt` is the server's TRP3
directory last-seen stamp (`profile.time`), a second freshness signal
for when a holder has touched the subject's register entry more recently
than its copy's claim suggests. All other offerers get silence; their
pending serves expire via `SERVE_TIMEOUT`. A request parks in
`chan-wait` while `REQ_CHANNEL_INTERVAL` (10s) has not elapsed since our
last broadcast, giving up after `REQ_CHANNEL_WAIT_MAX` (30s):

```
listeners                                channel requester (fallback)
    │  ◄── REQ <guid> ... ── one chunk, realm-wide same-faction subscribers
    │                              └ can serve? → freshen, then whisper ACK
    │                                cannot?  → silent
    │  ── ACK <guid> <seenAt> <dirSeenAt> ──► collects offers (cap 8)
    │  ◄── OK <guid> ── best-scoring offer granted: extract, serve direct
    │       other ACKers: silence — pendingServe expires via SERVE_TIMEOUT
    │  ── data envelope ──►
```

The broadcast is spent at most once per request (`channeled` flag): a
channel-granted serve that stalls drops the subject to cooldown. A server
whose grant already failed us is excluded from a rebroadcast. The extra
`dirSeenAt` ACK field is optional on the wire — older proto-5 ACKs simply
arrive without it, and older requesters ignore it. Broadcast `REQ`s from
fanout-era builds are still answered with the same freshness and serve
rules (they just hit the per-requester channel throttle harder).

**Requester rules**
- Skip if the subject is already cached-fresh, a request is pending or
  queued, or the subject is on `REQ_COOLDOWN` (60s) after a prior attempt.
- Skip while the subject is held-suppressed: `db.seen[guid].holdUntil`
  re-arms to `time() + REQ_HELD_TTL` (30min) on every accepted store, and
  while it is in the future *and* the RP AddOn's register still holds the
  profile (`profileMeta` non-nil), local requests do not fire. A register
  purge ends the suppression early.
- Skip if the subject shares a club with us (community or guild): the RP
  AddOn's own cross-faction whisper query already pulls that profile on
  mouseover/target — a `REQ` would duplicate the native pull, whose landing
  fills our cache via the received listener anyway.
- Pending subjects queue dedup'd (`REQ_BACKLOG_CAP`=8, oldest dropped on
  overflow) and are re-validated on release — a subject cached or served
  while waiting never sends.
- `contact` state expires after `REQ_CONTACT_TIMEOUT` (4s) without an ACK;
  `awaiting-data` ends on stall (`REQ_DATA_STALL`, counted from the grant
  or the server's last chunk, whichever is newer) or `REQ_DATA_TIMEOUT`
  (120s). Every outcome frees the pump for the next queued subject.
- An `ACK` whose `seenAt` claim sits at or below our freshness floor is
  denied silently — a stale offer cannot win a grant. On the unicast leg
  the sole candidate's ACK opens the data window directly.
- On the channel leg, `ACK`s from any sender collect into a bounded offer
  list (`REQ_CHANNEL_ACK_CAP`=8); the window close grants the best score.
- A slow contact's `ACK` still lands while the request parks in
  `chan-wait` — it is granted there, skipping the broadcast entirely.
- If we hold the subject's profile ourselves, the fallback publishes it
  locally before broadcasting: the honest (possibly stale) originTime is
  a floor the mesh can only beat, and the pull yields content even when
  the mesh misses.
- Data received for a pending subject completes the request from any
  source.
- Misses get no reply — relay confirmation rides the `HELLO`/`HI` probes
  instead of paying a reply per non-holder.

**Server rules**
- A `REQ` is answered only when we can actually extract the profile: the
  subject resolves to a unitID *and* the RP AddOn's register holds the
  profile (`adapter:canServe` reads the register live — including profiles
  received in earlier sessions; the register is persisted state, unlike
  our cache).
- A servable REQ asks the RP AddOn to **refresh our held copy from the
  author** (`adapter:refreshQuery` — for TRP3, its own vernum and MSP
  queries, the same headless calls `/trp3 open` makes). The query is
  skipped entirely when the held copy is already fresh enough to serve:
  seen within `SERVE_REFRESH_TTL` (1h), or newer than the requester's
  `seenAt` claim by more than `FRESHNESS_SKEW`. On the unicast
  path the `ACK` goes out immediately (it only marks the requester's data
  window); the serve itself waits for updated profile data
  (`REGISTER_DATA_UPDATED`) or `REQ_FRESHEN_DELAY` (2s), so the payload
  carries post-refresh content. On the channel path the whole `ACK`
  decision defers the same way, since the claim it advertises must reflect
  the refreshed copy. Deferred replies are bounded (`REQ_FRESHEN_MAX`=16,
  overflow answers immediately) and are never self-requests — we are the
  authority on ourselves. If the adapter cannot or will not refresh, the
  REQ answers exactly as it would without the feature. A subject we merely
  know of but hold no profile for is never queried — `canServe` gates the
  whole branch.
- Unicast REQs are throttled per sender (`REQ_SENDER_INTERVAL`=2s).
  Channel REQs are throttled per requester at
  `REQ_CHANNEL_SENDER_INTERVAL` (10s) — the same pace clients self-rate
  their own broadcasts at — and bounded by the serve cooldown below, since
  a broadcast can reach many holders at once.
- Auto-generated default profiles are never served or stored. TRP3 marks
  them with a trailing `*` on the profileID; holders answer as if the
  subject were a miss, and wire data carrying a `*` profileID is rejected
  on ingest. The refresh query itself is not gated: a held default profile
  still triggers one, so an author's newly-created real profile can be
  discovered and served.
- Subject identity resolves by **consensus**: every claim we hold for the
  guid — our cache's guid→unitID map, the client player-info cache
  (`GetPlayerInfoByGUID`), the club roster, and the requester-asserted
  wire unitID — must agree on one unitID. Any disagreement is a silent
  miss: we never serve on conflicting identities. A guid-only `REQ`
  (older peer, or a requester that could not compute the unitID) resolves
  from local claims alone. `REQ` for our own guid answers directly —
  we are the authority on ourselves.
- Misses stay silent — a reply per non-holder costs more than the
  requester's timeout.
- On the channel path an `ACK <guid> <seenAt> <dirSeenAt>` records a
  *pending serve* (`SERVE_PENDING_CAP`=16, expires at `SERVE_TIMEOUT`=30s).
  `dirSeenAt` is our TRP3 directory last-seen stamp (`profile.time`) for
  the subject — a second freshness signal the requester weighs alongside
  the content claim. `OK` triggers extraction and a direct send; `NOK`
  discards it.
- Channel serves are cooldown-limited and drain-aware: while a granted
  serve's chunks sit in our send queue we ACK no broadcast REQs at all,
  and once a mesh serve's last chunk leaves the queue we stay muted for
  `SERVE_CHANNEL_COOLDOWN_MIN`–`MAX` (10–60s), scaling linearly with the
  comms channel's `CHANNEL_COUNT_UPDATE` member count up to
  `SERVE_MESH_DENSE` (10). On a thin mesh availability beats dedup — we
  may be the only holder — while a dense mesh spreads each profile, so
  back-to-back serves are redundant load. Only granted serves count —
  an ungranted ACK never cost real work, and grants already ACKed
  complete their serve without extending the mute. This is a silent
  bow-out, not a message — the requester's own timeout and
  subject-cooldown *are* the backpressure signal, so no wire traffic is
  spent reporting saturation. REQs for our own GUID bypass the cooldown
  (we are the authoritative server for ourselves).
- Served data uses a normal data envelope. Its `originTime` is the holder's
  *claim* for that copy — the persisted record's as-of stamp, or the
  register's own last-seen stamp when it holds content the record does not
  cover — never plain `time()`. Stamping "now" would launder an old copy
  into looking freshly authored; a stale relay must stay stale on the
  wire. Self-serves claim `time()` (we are the author).

### Traffic shape

The serial pipeline exists to bound per-request traffic. Rough message
counts per request, before profile data:

| Scenario (one subject request)        | Old fanout                          | New pipeline                     |
|---------------------------------------|-------------------------------------|----------------------------------|
| REQ legs sent                         | 1 channel + 1 group + N BNet + up to 10 relay whispers | 1 whisper; +1 channel chunk only on stranger fallback |
| ACKs generated                        | one per reachable holder            | 1 (contact); ≤8 collected offers on fallback |
| OK/NOK arbitration                    | 1 OK + implicit loser timeouts      | 1 OK to the best-scoring offer; losers expire silently |
| TRP3 refreshes triggered at the subject | up to one **per holder** (every ACKer queried) | ≤1 unicast; on fallback, one per holder that ACKs |
| Profile data legs                     | 1 (winner only)                     | 1 (winner only)                  |

Worst cases: under fanout, a subject nobody held could still wake every
listener plus 5 guild + 5 community whispers per request, and every holder
that ACKed had already paid a TRP3 vernum exchange at the subject — the
amplification the pipeline removes. Under the pipeline, a dead contact
costs 4s of silence then a single channel chunk; a contact that ACKs but
cannot deliver costs a stall-bounded window (≤120s), then the channel
fallback. The fallback itself fires at most once per request and only for
strangers, and our own channel REQs are spaced by REQ_CHANNEL_INTERVAL —
so a crowded scene produces a trickle of single-chunk broadcasts, not the
per-sighting fanout that made broadcasts delay real requests. Repeated
cycles only repeat the single-contact pattern — the cursor wraps rather
than fanning out.

### Freshness floor

Every client keeps a persisted per-subject record,
`FactionRPDB.seen[guid] = { at, unitID, pid, cv, addon, holdUntil }`, where
`at` is the highest "as of" claim ever accepted for that subject and
`holdUntil` suppresses local re-requests while the register still holds
the copy (REQ_HELD_TTL, see "Requester rules"). The record
survives relog (the session cache does not), so a stale serve cannot
re-enter after a restart once a fresher copy has landed.

- `at` advances on accepted NEW/UPDATED stores and on same-content
  REFRESHED sightings — never on rejects. Claims are clamped to
  `time() + FRESHNESS_SKEW` so a far-future claim cannot poison the floor.
- When no record exists, the floor seeds from the RP AddOn's own last-seen
  stamp (TRP3 `profile.time`) for the copy we hold.
- Candidates claiming `originTime < floor - FRESHNESS_SKEW` are REJECTED
  whether or not a cache entry exists. `FRESHNESS_SKEW` (3600s) absorbs
  cross-client clock skew: `time()` is each client's local epoch, not a
  shared clock.
- The record — not the register's `profile.time` — is authoritative once
  present: TRP3 re-stamps `profile.time` on every profile bind, including
  the binds our own injections perform, so the register stamp alone would
  let injected stale data launder itself as fresh.
- Records are reconciled against the RP AddOn's register on the cache
  sweep: a record whose unit no longer holds a profile is dropped (this
  follows the user's manual purges and the AddOn's own auto-purge, both of
  which can bypass observable events), and a record whose register-bound
  profileID has changed re-anchors `at` to the register's stamp — the
  subject switched profiles, so the old lineage's floor is released.
- Ordering is timestamp-only. A profileID is compared for *equality* (REQ
  suppression, sweep re-anchor), never for freshness: TRP3 mints IDs
  locally with no shared ordering, and a stale copy carrying an unfamiliar
  ID is still stale.

**What changed vs. push-gossip**: there is no relay leg for data at all.
Inbound data is cached and injected into the RP AddOn's register — never
re-sent. Same-faction distribution remains the RP AddOn's own job; FactionRP
only bridges faction boundaries.
