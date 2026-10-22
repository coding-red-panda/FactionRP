# FactionRP Changelog

## 0.4.1

### Fixes
- No longer read your own message to mesh channel.

## 0.4.0

### Changed
- New protocol (again).
- Probe for relays faster.
- Only probe BNet friends if their current character is xfac.
- Re-scan Communities members when opening Communities Panel.
- Ignored members may now be reprobed if offline on re-scan.
- BNet friends confirm and recover faster.
- Scaling cooldown system for local mesh to spread load across users.
- More intelligent throttling across the board.
- FRP cache received profile metadata so to not clobber servers with pointless REQs.
- Progress indicator
- FRP now uses TRP's own functions to pull updated profiles. (and yes it's throttled)
- Profile requests are now serial: one subject at a time, asked of a single
  contact (BNet first, then guild, then community relays, round-robin).
  On contact failure or a stalled serve, total strangers (no shared club,
  group, or BNet link) get one channel REQ on the faction mesh: ACK offers
  collect for a short window and the freshest — judged by content claim
  and TRP3 directory last-seen — wins the grant.
- Received profiles suppress local re-requests for a while (REQ_HELD_TTL)
  while the profile still exists in the register; a purge releases it.
- Granted serves now expire on stall (no chunks for REQ_DATA_STALL) rather
  than only at the absolute data timeout, so dead serves free the request
  slot sooner.
- Now requests fresh TRP profiles from subjects being served, but only if server has already seen them before.
- Default profiles are now ignored and not served.

## 0.3.5

### Changed

- NEW PROTOCOL VERSION!
- Stale copies should no longer regress a fresher profile in session. NOTE: This is still very sketch and may be unreliable, but it should at least not be any worse than it was. Hopefully :)
- REQ and ACK calls now also include additional metadata to help inform when who should serve what.


## 0.3.4

### Fixes
- Entering a follower dungeon no longer kills profile requests with
  `attempt to concatenate local 'realm' (a nil value)` (issue #26). A client
  mid-transition can report no realm at all, and the secrecy check cannot
  tell "absent" from "accessible": units whose realm cannot be read are now
  skipped instead of raising, and control envelopes stamp an empty `unitID`
  field while our own realm is unknown — the wire's documented "not
  asserted" form — so requests keep flowing until the realm is readable
  again.

## 0.3.3

### Added
- One-time version broadcast on login (issue #19): shortly after entering the
  world a single `VER <version>` control message is announced on the comm
  channel. Peers that hear a newer version than their own print an update
  notice in chat (deduped per session by the highest version announced).
  `/frp status` now shows the newest version announced by a peer.

## 0.3.2

### Fixes
- No longer NOK on failed ack (was clogging our queue), just be quiet. Profiles REQs should transmit much quicker as a result.
- No longer requests xfac profiles from players in the same guild or community; TRP3 does that already.
- Message send rates now travel travel faster.

## 0.3.1

### Fixes
- Channel reordering should no longer cause stale sends to pass on to the
  old channel index.

### Changed
- Added debug option to display reorder ops: `/frp debug reorders`
- Messages have been slowed way the hell down.
- FRP now handshakes passively with potential relays, rather than fanning out on demand.
  This does have the effect of slowing down the rate of profiles when the mesh is thin.
- If too many serves are granted within 30 seconds, stop answering REQs
  until the cooldown expires. `/frp relays` will show the mute countdown.
- `REQ` now includes subject unitID alongside GUID for validation.
  This helps serve profiles you haven't seen this session if they're already
  in the register.
- Outbound send rate reduced to `SEND_RATE` = 1 chunk/sec.
- Whisper relays are now actively probed (`HELLO`/`HI` over addon whispers,
  same lifecycle as BNet): candidates are probed in bursts of 3 every 2 min,
  confirmed relays are re-probed to stay fresh, and targets that ignore 3
  probes are skipped for 30 min. `/frp relays` shows probing/ignored buckets.
- `COMM_RELAY_LIMIT`/`GUILD_RELAY_LIMIT` halved to 5 each — relay lists are
  maintained per client, so request coverage is distributed across the mesh.
- `REQ` whisper legs now reach only confirmed relays and known xfac
  contacts — unproven roster candidates are left to the probe rotation, so
  a request never whispers strangers.
- Relays/contacts are skipped while the roster marks them offline, and
  `/frp relays` badges each whisper relay with its leg membership
  (`[C]`/`[G]`/`[C+G]`) and resolves BNet accounts to character names.
- Roster fix: a factionless guild record no longer hides cross-faction
  guild members — faction claims accumulate across clubs, unknown members
  defer to end-of-build.
- Probe fairness: never-probed candidates are targeted before re-probes
  (was front-of-roster-first, which starved deeper candidates until the
  front ones were ignored); guild members probe before community.
- Realm normalisation now strips spaces, hyphens and periods.


## 0.3.0

### Changed — pull model (breaking protocol change)

- **Profile data no longer floods.** The push-gossip fanout is replaced by a
  pull exchange: selecting an opposite-faction player (mouseover/target)
  sends a single-chunk `REQ <guid>` to the mesh; the first peer that can
  serve the profile `ACK`s, is granted `OK`, and pushes the data envelope
  directly to the requester. Later `ACK`s receive `NOK`. Requests dedupe per
  subject, expire (15s no-ACK / 30s no-data), cool down per subject (60s),
  and are bounded (`REQ_MAX_PENDING`).
- Hard protocol partition: every envelope carries `C.PROTO_MAJOR` (currently
  3) as a dedicated field, and receivers reject lower generations before any
  peer-state side effect — older or modified clients cannot confirm a relay,
  serve a request, or feed the cache. The comm channel is now `frp3comms`,
  so older clients sit on a disjoint channel entirely; on load and each
  re-join we also actively leave the legacy `FactionRP` channel and any
  foreign-generation `frp<N>comms` channel, since channel membership
  survives `/reload`.
- Data is never relayed: inbound profiles are cached and injected into the
  RP AddOn's register only. Local extraction (`Scanner`) now *publishes* to
  the cache without touching the wire, so every client can serve what it
  has seen.
- All control traffic is the FRP1 control channel — ordinary envelopes with
  the reserved subject `_frp` and `data = "FRP1 <verb> <arg>"` — never
  cached, injected, or relayed, and harmlessly dropped by older clients.
- Wire format documented in `doc/protocol.md`.

### Added

- Battle.net peer confirmation handshake (`HELLO`/`HI`): BNet data and `REQ`
  legs go only to accounts that have proven they run the AddOn. Unconfirmed
  friends receive rotating probes; 3 unanswered probes ignore an account for
  30 min (cleared early by friend-presence events). Confirmations expire
  after 10 min without fresh proof.
- New `peers` debug category logging probes, confirmations, ignores, and
  REQ/ACK/OK/NOK exchange events. `/frp relays` now shows BNet peer buckets
  and pending request/serve counts.
- `TRP3Adapter:canServe` (cheap existence check for the server path) and a
  roster `guid -> unitID` map for resolving request subjects.

### Changed

- Outbound pacing is a single dial: `C.SEND_RATE` chunks/second (token
  bucket on the 0.2s tick) replaces `SEND_BURST`; default 7.5 (~50% lower).
- Community/guild relay limits raised to 10 each — these legs now carry
  single-chunk control messages, not profile data.
- `sendChunks*` return false on whole-leg queue drop so callers (probes,
  grants) only stamp state for sends that actually queued.
- `RELAY_TO_FRIENDS` and the `broadcast` debug category removed (no data
  fanout remains); `/frp mem census` reports BNet peer and exchange counts.

## 0.2.3

### Added

- Fractionalised debug flags: `/frp debug` now lists categories, `/frp debug
  <category>` toggles one (broadcast, receive, cache, queue, fanout, chunks,
  targets, stats), and `/frp debug all` toggles everything. Existing
  `debug = true` settings migrate to `all`.
- `/frp debug chunks` logs every wire chunk in and out (very noisy).
- Pinned whisper targets (`/frp debug target`) are now gated on the `targets`
  category rather than the global debug switch.
- Session-only traffic statistics while the `stats` category is enabled:
  message rates (rolling 60s + session), byte sizes (average and median),
  profile reassembly time (first to last chunk), per-leg transmit time,
  per-medium and per-leg breakdowns, cache outcome and error tallies, queue
  high-water marks, origin age, unique senders/subjects, and a 50-entry
  recent-message ring buffer. Inspect with `/frp stats [section|last n|reset]`
  or `ns.Stats.snapshot()`.
- `/frp mem` memory diagnostics: forced-GC live memory reading, `churn [n]`
  allocation-rate sampling, and `census` live counts of the internal tables.
- `Util.newPool` shared table-pool primitive (acquire/release/size).
- `/frp relays` inspects relay selection: learned relays/contacts, online
  roster candidates, and the last fanout's chosen targets per leg. The
  `fanout` debug category now prints the picked names, not just counts.
- Roster rebuilds are gated on `C_Club.ClubsHaveBeenLoaded`, and a build
  that collected GUIDs but saw no faction values (member info still
  streaming) is discarded and retried after `C.ROSTER_RETRY` seconds
  instead of publishing an empty-faction roster for a whole memo window.
- The send queue is bounded at `C.SEND_QUEUE_CAP` (384) chunks: a leg that
  cannot fit entirely is dropped whole (per-leg atomic), counted under
  `send_queue_drop` in `/frp stats errors`. Prevents unbounded backlog
  when outbound demand exceeds the ~15/s drain capacity.

### Changed

- Allocation-churn reduction across the hot paths (measured via `/frp mem
  churn`; the 40 MB sawtooth was garbage backlog, not leaks):
  - The send queue now holds pooled descriptor records instead of a closure
    per chunk, ring-indexed (no `table.remove` shifts); per-leg completion is
    flat fields on the last descriptor rather than a `legDone` closure.
  - Inbound transport contexts are persistent scratch tables (reused per
    event, never retained past the synchronous handler).
  - `ChunkReassembler` buffers key two-level by sender→msgId (no per-chunk
    key concat), parse headers positionally, pool buffer/piece tables, and
    return metadata as multiple return values instead of a meta table.
  - `parseMessage`/`buildMessage`/`chunk` avoid split/join tables and
    `string.format`.
  - Fanout: the five per-call closures are hoisted to methods/file-locals;
    leg candidate lists, seen-maps and sent-key sets are wiped shared
    scratch; `commUsage` entries reset in place on window expiry; the
    Battle.net account list is memoized (`C.BNET_MEMO` = 15s) instead of a
    per-fanout friends-list scan.
  - The club roster rebuild writes into a persistent back buffer and swaps
    atomically, so the 45s rebuild no longer re-allocates O(roster) tables;
    the per-slice timer closure is hoisted.
  - `receivedPending` records are pooled; `injectOrder` is ring-indexed;
    `guidMemo` entries reset in place; TRP3 injection unrolls its section
    map; the stats recent ring reuses entry slots.
  - Disabled debug/stats paths remain a single nil-guarded lookup.

- Debug log hooks and stats recorders are installed/removed with their flags
  instead of checking flags per call, so disabled debug facilities cost a
  single nil-guarded table lookup at each call site.
- `ChunkReassembler:add` now returns reassembly metadata (chunk count,
  first-to-last-chunk elapsed, duplicate arrivals) alongside the completed
  message, and `prune` returns the number of dropped buffers.

## 0.2.2

### Added

- Profile broadcasts now also happen over GUILD, via the same rules enforced by Communities broadcasts.
- Added `/frp purge` to purge cache.
- Added `/frp debug target` to pin a relay target for testing, i.e `/frp debug target Arru`.
- Added `/frp debug target clear` to reset the pinned target.

## 0.2.1

### Fixed

- Map scan breakage and duplicated results (issue #1): a gossip loop around
  the RP AddOn's register flooded the comm bus while TRP3 scan traffic ran.
  The Scanner now only re-originates for units the user actually selected
  (mouseover/target) and collapses update events whose content version is
  unchanged since our last originate (`lastSharedVersion` guard), so our own
  register injections no longer cycle back as new gossip.
- Unthrottled addon-message bursts contending with other add-ons during
  bursts: outbound sends are now routed through **Chomp** (the ChatThrottleLib
  wrapper TRP3 ships) on the `LOW` priority queue, with a raw fallback when
  Chomp is absent. Battle.net game-data sends are throttled the same way.
- The hidden comm channel is joined only when not already joined; repeated
  joins fired channel-list churn events that could transiently confuse other
  add-ons' channel bookkeeping.

## 0.2.0

### Added

- Re-broadcast profiles reported as received over the RP AddOn's own comm
  channels (TRP3 exchange protocol and MSP), debounced with a random jitter
  and drained through a capped queue so receipt bursts cannot flood the
  send queue.
- Cross-faction reach via communities: opposite-faction members of our own
  WoW clubs are pinged with capped addon whispers; confirmed FRP peers and
  known cross-faction contacts are preferred, with round-robin fair use so
  no member acts as a relay server.
- Registration into the RP AddOn's update/receipt signals (`ba05b62`), plus
  tentative MSP support and MSP-version folding into content versions.
- Directory injection: gossip-stored profiles populate the RP AddOn's register
  through a bounded queue (no more tooltip-only population).
- Best-effort GUID resolution helpers (unit tokens, Battle.net friends, club
  rosters) with memoization and incremental club-roster building.
- Expanded debug output and a richer `/factionrp status`.

## 0.1.1

- Bump interface to `120100`

## 0.1.0

- Initial implementation
- Implement communication protocol