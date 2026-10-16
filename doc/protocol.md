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

**Every leg is a single hop.** The requester sends `REQ` on each medium
itself; a recipient that can serve replies `ACK` and, if granted, sends the
profile *directly* to the requester. "Relay" in this document means a
reachable cross-faction *endpoint* — never a forwarder: no client relays or
re-sends anything on behalf of another. A requester with no cross-faction
clubs or friends therefore still gets full use of the channel and group
legs — answering peers are faction-mates, so their reply whisper needs no
shared club.

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
| `NOK`   | subjectGuid         | cancel — winner mid-send, data landed elsewhere |

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

Whisper peers (cross-faction club members) use the same probe/confirm/ignore
lifecycle as BNet accounts:

- **Probing**: bursts of up to `RELAY_PROBE_BURST` (5) whispered
  `HELLO <ver>`s every `RELAY_PROBE_INTERVAL` (120s), walked in order by a
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
  (`RELAY_PROBE_COOLDOWN`=45s) kicks the target to the ignore list for
  `RELAY_IGNORE_TTL` (2h) at the next rotation pass; expired ignores
  re-enter rotation with a fresh slate — the slow recovery path. Ignored
  targets are skipped by `REQ` fanouts too.

`REQ` whisper legs reach only proven targets — confirmed relays and known
xfac contacts; the unconfirmed roster is the probe rotation's job, so a
request never whispers strangers.

## The pull exchange

Profiles move on demand. A pull is triggered when the user mouseovers or
targets an opposite-faction player whose profile we do not hold fresh.

```
requester                                candidate servers
    │  REQ <guid> [unitID] ──────────────────► (1 chunk on frp<N>comms —
    │                                          all same-faction listeners
    │                                          + group + confirmed BNet
    │                                          + one whisper per proven
    │                                          xfac relay)
    │                                          └ can extract? → ACK
    │                                            cannot?  → silent
    │  ◄── ACK <guid> ── (first wins, direct to requester)
    │  ── OK <guid> ──► winner only; later ACKers get
    │                     silence — their pendingServe
    │                     expires via SERVE_TIMEOUT
    │  ◄── data envelope ── winner serves direct
```

**Requester rules**
- Skip if the subject is already cached-fresh, a request is pending, or the
  subject is on `REQ_COOLDOWN` (60s) after a prior attempt.
- Skip if the subject shares a club with us (community or guild): the RP
  AddOn's own cross-faction whisper query already pulls that profile on
  mouseover/target — a `REQ` would duplicate the native pull, whose landing
  fills our cache via the received listener anyway.
- Fanouts are globally paced: at most one `REQ` fanout per
  `REQ_ISSUE_INTERVAL` (4s). Initiated sends — `REQ` fanouts and `HELLO`
  probes — also share an in-flight budget: no more than
  `FANOUT_INFLIGHT_MAX` (3) may occupy the send queue at once, so a new
  send waits for earlier chunks to drain. Sightings that arrive sooner
  wait in a dedup'd FIFO (`REQ_BACKLOG_CAP`=8, oldest dropped on
  overflow) and are re-validated on release — a subject cached or served
  while waiting never sends.
- At most `REQ_MAX_PENDING` (32) outstanding requests.
- `open` state expires after `REQ_ACK_TIMEOUT` (15s) without an ACK;
  `awaiting-data` expires after `REQ_DATA_TIMEOUT` (30s) without data.
- Data received for a pending subject completes the request from any source;
  if it arrived from a non-winner, the winner is NOK'd best-effort.
- Misses get no reply — relay confirmation rides the `HELLO`/`HI` probes
  instead of paying a reply per non-holder.

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
- Misses stay silent — a reply per non-holder costs more than the
  requester's timeout.
- An ACK records a *pending serve* (`SERVE_PENDING_CAP`=16, expires at
  `SERVE_TIMEOUT`=30s). `OK` triggers extraction and a direct send;
  `NOK` discards it.
- Our serve rate is breaker-limited: once `SERVE_RATE_LIMIT` (10) serves
  are *granted* inside `SERVE_RATE_WINDOW` (30s) we stop answering REQs
  for `SERVE_RATE_MUTE` (60s). Only winning the ACK race counts — an
  ungranted ACK never cost real work, and grants arriving while muted complete
  their serve without extending it. This is a silent bow-out, not a
  message — the requester's own timeout and subject-cooldown *are* the
  backpressure signal, so no wire traffic is spent reporting saturation.
  REQs for our own GUID bypass the breaker (we are the authoritative
  server for ourselves).
- Served data uses a normal data envelope stamped with the server's
  `originTime` (the original authoring time is unknowable server-side).

**What changed vs. push-gossip**: there is no relay leg for data at all.
Inbound data is cached and injected into the RP AddOn's register — never
re-sent. Same-faction distribution remains the RP AddOn's own job; FactionRP
only bridges faction boundaries.
