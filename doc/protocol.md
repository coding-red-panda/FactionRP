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

Cross-faction addon whispers are only possible between members of the same
community/guild club — that is what makes club rosters the whisper relay
pool. BNet works between any friends.

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
| `originTime`     | `time()` when the data was authored                              |
| `contentVersion` | opaque version string (`c#:k#:m#` section versions)              |
| `protoMajor`     | wire-protocol generation (`C.PROTO_MAJOR`, currently 3)          |
| `data`           | payload; may itself contain `||` — it is always the last field   |

A message is malformed unless all seven separators are present and
`originTime` parses as a number.

### Protocol versioning

`protoMajor` is a hard interop gate: receivers reject any envelope
advertising a lower generation (`statsError("proto_old")`), *before* any
peer-state side effect — a too-old or forged message cannot confirm a relay,
serve a request, or enter the cache. The comm channel also carries the
generation (`frp3comms`), so older-protocol clients sit on a disjoint channel
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
expire after `C.REASSEMBLY_TIMEOUT` (60s); duplicate chunks are counted and
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
| `REQ`   | subjectGuid [unitID]| pull request — "who can serve this profile?"|
| `ACK`   | subjectGuid         | "I can serve it"                            |
| `OK`    | subjectGuid         | grant — "you may send it"                   |
| `NOK`   | subjectGuid         | deny — "stand down"                         |
| `MISS`  | subjectGuid         | miss reply — "got your REQ, can't serve"    |

`REQ` is the only two-argument verb: `unitID` is the subject's
`"Name-Realm"` as computed by the requester's RP AddOn — the exact key its
register uses. It is optional (older/adapter-less clients send the guid
alone) and lets any server answer straight from its register without local
guid→unitID state. `ACK`/`OK`/`NOK` still carry the guid only — it is the
wire identity.

### BNet peer confirmation

We never assume a silent BNet friend runs FactionRP. Per-account state
(session-only):

```
unconfirmed → probing → (3 unanswered probes) → ignored
                 ↑               │                    │
                 └───────────────┴── TTL / presence ──┘
any parseable inbound message → confirmed (10 min TTL)
```

- **Probing**: every `BNET_PROBE_INTERVAL` (10s) we send `HELLO <ver>` to the
  next online, unconfirmed, non-ignored account (round-robin, ≥45s between
  probes per account).
- **Confirming**: any complete, parseable FRP message from an account —
  `HELLO`, `HI`, `REQ`, or data — confirms it for `BNET_CONFIRM_TTL` (10min).
- **Replying**: `HELLO` is answered with `HI <ver>` (rate-limited to one
  per `BNET_HI_COOLDOWN`=30s per account). `HI` is never answered — the
  exchange terminates after one round-trip.
- **Ignoring**: after `BNET_PROBE_MAX` (3) unanswered probes an account is
  ignored for `BNET_IGNORE_TTL` (30min). Only `BN_FRIEND_ACCOUNT_ONLINE`
  clears ignore flags — `BN_FRIEND_INFO_CHANGED`/`FRIENDLIST_UPDATE` merely
  invalidate the online-account memo (they fire on zone/status churn and
  would otherwise resurrect ignored accounts before their TTL).
  `BN_DISCONNECTED` wipes the map.
- **Data and REQ legs on BNet go to confirmed accounts only.**

Whisper peers need no handshake: sending `REQ` to unconfirmed cross-faction
club members doubles as discovery — any parseable inbound whisper from a club
member confirms them (`knownRelays`), and non-FRP recipients simply cannot
answer.

## The pull exchange

Profiles move on demand. A pull is triggered when the user mouseovers or
targets an opposite-faction player whose profile we do not hold fresh.

```
requester                                candidate servers
    │  REQ <guid> [unitID] ──────────────────► (channel + group +
    │                                          confirmed BNet +
    │                                          xfac whisper relays)
    │                                          └ can extract? → ACK
    │                                            cannot?  → MISS on whispers,
    │                                            silent on channel/group
    │  ◄── ACK <guid> ── (first wins)
    │  ── OK <guid> ──► winner only
    │  ── NOK <guid> ─► every later ACKer
    │  ◄── data envelope ── winner serves direct
```

**Requester rules**
- Skip if the subject is already cached-fresh, a request is pending, or the
  subject is on `REQ_COOLDOWN` (60s) after a prior attempt.
- At most `REQ_MAX_PENDING` (32) outstanding requests.
- `open` state expires after `REQ_ACK_TIMEOUT` (15s) without an ACK;
  `awaiting-data` expires after `REQ_DATA_TIMEOUT` (30s) without data.
- Data received for a pending subject completes the request from any source;
  if it arrived from a non-winner, the winner is NOK'd best-effort.
- A `MISS` is informational: the request stays open for other candidates.
  It confirms the sender as a relay and distinguishes "can't serve" from
  "never delivered".

**Server rules**
- A `REQ` is ACKed only when we can actually extract the profile: the
  subject resolves to a unitID *and* the RP AddOn's register holds the
  profile (`adapter:canServe` reads the register live — including profiles
  received in earlier sessions; the register is persisted state, unlike
  our cache).
- Subject identity resolves by **consensus**: every claim we hold for the
  guid — our cache's guid→unitID map, the client player-info cache
  (`GetPlayerInfoByGUID`), the club roster, and the requester-asserted
  wire unitID — must agree on one unitID. Any disagreement is a silent
  miss: we never serve on conflicting identities. A guid-only `REQ`
  (older peer, or a requester that could not compute the unitID) resolves
  from local claims alone. `REQ` for our own guid answers directly —
  we are the authority on ourselves.
- Misses answer `MISS <guid>` **only to a direct-whisper `REQ`** — those
  recipients are bounded by the requester's own relay caps, so a reply per
  non-holder stays cheap and doubles as relay confirmation. Channel/group
  recipients stay silent: a reply per listener there would cost more than
  the requester's timeout. Replies are throttled to one per requester+subject
  per `MISS_REPLY_COOLDOWN` (30s).
- An ACK records a *pending serve* (`SERVE_PENDING_CAP`=16, expires at
  `SERVE_TIMEOUT`=30s). `OK` triggers extraction and a direct send;
  `NOK` discards it.
- Served data uses a normal data envelope stamped with the server's
  `originTime` (the original authoring time is unknowable server-side).

**What changed vs. push-gossip**: there is no relay leg for data at all.
Inbound data is cached and injected into the RP AddOn's register — never
re-sent. Same-faction distribution remains the RP AddOn's own job; FactionRP
only bridges faction boundaries.
