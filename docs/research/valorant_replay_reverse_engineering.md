# Valorant Replay Reverse Engineering Notes

This note captures the first pass at `.vrf` replay decoding for future Icarus
round replay support. The focus was locating the layer that contains player
position vectors, look direction, and time progression.

## Sample

- Replay directory: `C:\Users\shawn\AppData\Local\VALORANT\Saved\Demos`
- Current sample: `ff96dfb2-e766-40db-affb-a3af36a07b83.vrf`
- File size: `59465973` bytes
- Modified: `2026-06-16 09:16:58`
- Map from replay header: `/Game/Maps/Ascent/Ascent`
- Build branch from replay header: `++Ares-Core+release-12.11`

## Public references

- Riot says Valorant replay files are downloaded locally, support all ten first
  person perspectives, free cam, minimap/HUD viewing, and time or round
  navigation:
  - https://playvalorant.com/en-us/news/dev/replays-everything-you-need-to-know/
  - https://support.riotgames.com/en-us/valorant/gameplay/replays-faq-pro-tips
- Unreal Engine replays use `DemoNetDriver` plus replay streamers, and the
  local streamer writes chunked replay data:
  - https://dev.epicgames.com/documentation/unreal-engine/demonetdriver-and-streamers-in-unreal-engine
  - https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/FNetworkDemoHeader
- The initial pass did not find a public Valorant `.vrf` parser. The useful
  open source references were generic Unreal/Fortnite replay parsers:
  - https://github.com/exception/UnrealReplayReader
  - https://github.com/xNocken/replay-reader
- A later Discord lead surfaced a Valorant-specific playground:
  - https://github.com/michel-giehl/ValorantReplayParserPlayground
  - The key discovery there is that Valorant obfuscates the property
    replication payload inside `ReceivedReplicatorBunch`, not the outer local
    replay container.
  - Its Valorant reader is intentionally minimal after that transform: it uses
    the normal Unreal `ReceivedReplicatorBunch` / `ReceivedRPC` path, where
    `ReceiveProperties` consumes the usual RepLayout/RPC checksum bit. The
    refreshed source also includes a tentative native `ComponentDataStream`
    decoder that is useful as a verifier once a clean RPC payload is captured.

## Container layout

Valorant `.vrf` starts with a small Valorant wrapper, then embeds a normal
Unreal local replay chunk stream.

Observed wrapper:

- Offset `0x00000000`: `0x43f4efdd`
- Offset `0x00000004`: `0x00000007`
- Offset `0x0000002c`: UTF-16 Unreal `FString` containing the match/replay id
  `ff96dfb2-e766-40db-affb-a3af36a07b83`, padded with spaces.
- First Unreal local replay chunk starts at `0x24a`.

The local replay stream is:

```text
u32 chunk_type
i32 chunk_size
u8[chunk_size] chunk_payload
```

Chunk type mapping:

```text
0 = HEADER
1 = REPLAY_DATA
2 = CHECKPOINT
3 = EVENT
```

For the current sample the chunk table parses cleanly to the exact file end:

```text
272 chunks total
1 HEADER
23 REPLAY_DATA
22 CHECKPOINT
226 EVENT
```

## Header findings

The header chunk payload starts with standard Unreal replay magic `0x2cf5a13d`.
The parsed header contains:

- `NetworkVersion = 19`
- `EngineNetworkVersion = 32`
- `GameNetworkProtocolVersion = 0`
- Map: `/Game/Maps/Ascent/Ascent`
- Branch: `++Ares-Core+release-12.11`
- Header flags: `0x2`
- Game-specific JSON data:
  - `{"serializedVersion": 2}`
  - One larger object containing ten `playerLoadouts` entries.

The header JSON contains identities, character ids, and cosmetics, but not the
continuous player movement track.

The replay header `playerLoadouts` use the same stable content UUID surface as
Valorant-API/Henrik-style match data:

- `subject` is the player account UUID/PUUID-like identifier.
- `characterId` matches Valorant-API agent UUIDs. The current sample resolves
  Jett, Raze, Miks, Iso, Sova, KAY/O, Killjoy, Phoenix, Clove, and Sova.
- Riot official `val-content-v1` is accessible with a standard developer key
  and returns the same agent UUIDs/content ids for release `12.11`.
- Riot official `val-match-v1` returned `403 Forbidden` with the available
  developer key, while `val-status-v1` and `val-content-v1` returned `200`.
  That indicates this key is valid generally but not granted VAL match-detail
  access.
- HenrikDev v4 match lookup succeeded for
  `ff96dfb2-e766-40db-affb-a3af36a07b83`, returning 10 players, 22 rounds, and
  156 kills. Every replay-header `subject` matched a Henrik `players[].puuid`,
  confirming that `subject` is the practical match/player id to use for labels.
  Henrik reports this sample as `Unrated` on Ascent.
- Henrik kill records include sparse `player_locations` with `puuid`, `x/y`,
  and `view_radians`. For this sample those kill timestamps align to replay
  `characterDeath` events by subtracting about `10016ms` from Henrik
  `time_in_match_in_ms`.
- `tools/valorant_replay_probe/emit_henrik_match_track.mjs` converts those
  sparse kill snapshots into replay track JSON. The current sample produces 927
  labeled position/view samples across all 10 players.
- Valorant-API `developerName` matches replay class path codenames:
  `Wushu -> /Game/Characters/Wushu/Wushu_PC`, `Clay -> .../Clay_PC`,
  `Iris -> .../Iris_PC`, `Sequoia -> .../Sequoia_PC`,
  `Hunter -> .../Hunter_PC`, `Grenadier -> .../Grenadier_PC`,
  `Killjoy -> .../Killjoy_PC`, `Phoenix -> .../Phoenix_PC`, and
  `Smonk -> .../Smonk_PC`.
- Public match APIs can provide names, tags, teams, agents, weapon ids, and
  event-time locations keyed by PUUID, but continuous replay movement still
  needs the runtime Unreal `ShooterCharacterNetGuidValue` to be joined back to
  those `subject` ids.
- Agent class path matching is not enough for unique identity. This sample has
  two Sova/Hunter players, so the class NetGUID identifies the character class
  but cannot distinguish those two subjects.
- The Henrik sparse track is now the best validator for the `.vrf` movement
  decoder: if a decoded `ComponentDataStream` sample is near a kill snapshot in
  time, it should be close to one of the labeled Henrik player locations after
  the `10016ms` offset correction. The current heuristic `.vrf` packed-vector
  samples do not line up well enough yet, which confirms they should remain
  marked as candidates rather than promoted to player tracks.

## Event findings

Event chunks are straightforward and useful for indexing the replay timeline.
For the sample:

```text
characterDeath: 156
characterUltimateUsed: 35
roundStarted: 22
spikePlanted: 12
switchTeams: 1
```

They do not contain the continuous 10-player position stream. `characterDeath`
payloads are small event payloads rather than round-state snapshots.

## Replay data compression

Replay data chunks use the Unreal local chunk metadata followed by a Valorant
compression envelope. The first replay data chunk starts at `0x3d0aa`, with the
payload at `0x3d0b2`.

Observed replay data payload envelope:

```text
u32 start_ms
u32 end_ms
u32 chunk_payload_size
u32 decompressed_size
u32 decompressed_size_again
u32 compressed_size
u8[compressed_size] oodle_payload
```

For the first replay data chunk:

```text
start_ms = 0
end_ms = 47
chunk_payload_size = 78609
decompressed_size = 171493
compressed_size = 78601
```

`ooz-wasm` successfully decompresses this payload. The decompressed bytes begin
with replay packet data and path strings such as
`/Game/Characters/_Core/BaseReplayController.BaseReplayController`.

## Schema findings

After decompressing all 23 replay data chunks and walking frame envelopes,
NetFieldExport groups, and NetGUID path names, the schema pass reached:

```text
~244662 frame envelopes
519 unread schema groups
19425 NetGUID path names
0 schema-pass errors
```

The key discovery is that normal Valorant player character actor groups expose
state like `PlayerState`, `Controller`, `ReplayLastTransformUpdateTimeStamp`,
and `bIsPlayerCharacter`, but did not expose a direct `ReplicatedMovement`
property in this pass. Many ability/projectile actors do expose
`ReplicatedMovement`, but player movement appears to be carried by a replay
controller RPC instead.

Promising actor/controller group:

```text
/Game/Characters/_Core/BaseReplayController.BaseReplayController_C
  3: RemoteRole
  12: Role
  14: PlayerState
  18: SpawnLocation

BaseReplayController_C_ClassNetCache
  0: ClientReplayReceiveInputEventProcessingCapture
  3: ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous
  20: ClientGamePhaseBegin
  21: ClientGamePhaseEnded
  27: ClientOnWinningTeam
  64: ClientFlushLevelStreaming
  104: ClientUpdateMultipleLevelsStreamingStatus

/Script/ShooterGame.ReplayPlayerController:ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous
  0: bIsReplayFastForwardImportant
  1: RemoteCharacterUpdates
  2: ShooterCharacterNetGuidValue
  3: ComponentDataStream
```

Local `.usmap` mapping files in `C:\Users\shawn\Downloads` confirm the wrapper
struct for this layer without needing cooked asset decryption:

```text
RemoteCharacterUpdate
  0: ShooterCharacterNetGuidValue UInt32Property
  1: ComponentDataStream StructProperty(ComponentDataStream)

ComponentDataStream
  propertyCount: 0
```

`ComponentDataStream` being present but property-less in the mapping means the
remaining unknown is native/custom serialization inside that struct, not the
outer replay RPC shape.

Additional local usmap queries surface a related reflected type:

```text
RemoteClientMovementComponent : ActorComponent
  0: SharedRemoteTimeShiftMonitor ObjectProperty
  1: NumRebases IntProperty
  2: NumRebasesFromOverqueue IntProperty
  3: DebugForceRebase BoolProperty
  4: RemoteCharacterMovementComponents SetProperty(ObjectProperty)
  5: ShooterCharacterTickOrdering ArrayProperty(ObjectProperty)
  6: MovementComponentWithMostUnprocessedQueuedMoves ObjectProperty
  7: CachedReplayDataManager ObjectProperty
```

Snapshot-shaped reflected structs also exist in the same mapping:

```text
RemoteClientMovementSnapShot
  0: Location Vector
  1: Velocity Vector
  2: Acceleration Vector

ShooterSnapshotMove : ShooterSnapshot
  0: Location Vector
  1: Rotation Rotator
  2: Velocity Vector
  3: ControlRotation Rotator
  4: CharacterSpaceInputVector Vector

ViewTransformRecorderSnapshot
  0: PawnLocation Vector
  1: ControlRotation Rotator
  2: bDidTeleport BoolProperty
  3: NetTimestamp FloatProperty
```

This is a useful naming clue for the native movement system, but it is not yet a
decoded replay carrier. The current `0-900s` diagnostics do not expose a live
`RemoteClientMovementComponent_ClassNetCache` or these snapshot class names; the
active high-frequency movement leads remain unnamed BaseReplayController handles
such as `24` and `122`.

## Seeded property stream transform

`ValorantReplayParserPlayground` reverses the property replication payload
transform from `VALORANT-Win64-Shipping`. The transform is applied per
replicator payload before normal Unreal property parsing:

```text
payloadBits = remaining bits in the content-block payload
seed = payloadBits
if channel actor NetGUID is known:
  seed ^= actorNetGUID
decodedPayload = ValorantSeededPayloadTransform(rawPayload, payloadBits, seed)
parse normal RepLayout/ClassNetCache fields
```

Icarus now ports that transform in:

```text
tools/valorant_replay_probe/valorant_seeded_payload_transform.mjs
tools/valorant_replay_probe/verify_seeded_payload_transform.mjs
```

The verifier uses the playground's known 287-bit payload vector plus a
release-12.11 replay smoke sample (`rawPayloadHex=1172`, `payloadBits=15`,
`seed=13`, expected transformed payload `4000`). It should pass with:

```powershell
npm --prefix tools\valorant_replay_probe run verify-seeded-transform
```

Important boundary from re-reading the playground source: its Valorant-specific
reader applies the seeded transform, creates a transformed `NetBitReader`, and
delegates back to the normal Unreal reader. There is no Valorant-specific global
leading-bit skip after transform. The normal Unreal property checksum bit is
still consumed by `ReceiveProperties` for RepLayout and RPC property streams.
The refreshed playground source now also includes a tentative native
`ComponentDataStream` model: movement magic `0x52`, cyclic 3-bit move markers,
fixed rotation input, a VLQ timestamp, quantized position at scale `100`,
packed yaw/pitch, and an optional velocity vector. That model is useful as a
verifier, but it still has to be reached through correctly framed RPC/property
payloads.

This solves the obfuscated property stream layer and gives a concrete native
movement-section hypothesis to test. The release branch matters: the current
sample is `++Ares-Core+release-12.11`, and using the older transform leaves the
target RPC looking like opaque custom records. With the release-12.11 transform,
the normal Unreal `ReceiveProperties` path reaches the target RPC and the
source-derived native `ComponentDataStream` parser decodes movement samples.

Current native movement baseline from the release-12.11 raw `0-900s` pass:

```powershell
node tools\valorant_replay_probe\extract_track.mjs "C:\Users\shawn\AppData\Local\VALORANT\Saved\Demos\ff96dfb2-e766-40db-affb-a3af36a07b83.vrf" --out ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.track.json" --diagnostics ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.diagnostics.json" --raw-packet-limit 350000 --raw-time-from-ms 0 --raw-time-to-ms 900000 --diagnostics-only --skip-compact-diagnostics
npm --prefix tools\valorant_replay_probe run analyze-component-data-stream-native -- --diagnostics ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.component_data_stream_native.report.json" --samples-out ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.component_data_stream_native.samples.json" --track-out ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.native_component.track.json"
```

That run scans `1595` raw packets, hits the named ReplayController target RPC
`260` times, and has `0` packet parse errors. The native verifier then reports:

```text
targetPayloads=260
strictRpc=260
componentOk=2599
directComponentScan.hitCount=3084
movementSampleCount=2610
```

The proof sample file contains `{timeMs, netGuid, position, viewRotation}` rows
for 10 player actor NetGUIDs, plus 71 top-level/no-NetGUID rows that the viewer
track intentionally ignores. The app-facing artifact
`tmp/ff96dfb2.raw0_900.v4_12_11_transform.native_component.track.json` contains
10 player tracks with roughly `252..257` samples each. First samples line up
with actor-open spawn positions and decoded yaw, for example NetGUID `682`
starts at `{ x: 1382.22, y: -10417.9, z: 400.3, yaw: 33.624 }` and NetGUID
`778` starts at `{ x: 599.99, y: 1026.44, z: 439.47, yaw: 224.033 }`.

The older v3/h24/h100/handle-122 reports below are retained as historical
guardrails from before the release-12.11 transform was ported. Do not use them
as the current replay-track baseline unless they are regenerated against the
`v4_12_11_transform` diagnostics.

Follow-up probing in this checkout added bounded standard-packet diagnostics and
BaseReplayController payload seed probes to
`tools/valorant_replay_probe/extract_track.mjs`. The important result is that
the previous compact `compactMovementRpcHitCount = 1` was a zero-bit
end-of-stream false positive, not a decoded call to
`ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous`. The
extractor now guards that case, so the current sample reports
`compactMovementRpcHitCount = 0`.

The new diagnostics field
`frameSummary.compactReplayControllerPayloadSamples` captures full compact
BaseReplayController payloads and probes seed variants including raw,
`payloadBits`, `payloadBits ^ actorNetGuid`, `payloadBits ^ repObject`,
`actorNetGuid`, `repObject`, and `0`. In the current sample, 79 compact
BaseReplayController payloads were captured. None of the seed variants produced
the expected BaseReplayController rep-layout handle chain (`3`, `12`, `14`,
`18`) or a credible target RPC payload. This makes a wrong XOR seed unlikely as
the main blocker; the stronger suspect is that the compact channel-2 boundaries
being fed into `ReceivedReplicatorBunch` are not true replicator payload
boundaries for the replay-controller movement stream.

The standard/reference-style packet walker can now be run in bounded replay-time
windows without enabling an unbounded raw scan:

```powershell
node tools\valorant_replay_probe\extract_track.mjs "C:\Users\shawn\AppData\Local\VALORANT\Saved\Demos\ff96dfb2-e766-40db-affb-a3af36a07b83.vrf" --out ".\tmp\ff96dfb2.raw329.track.json" --diagnostics ".\tmp\ff96dfb2.raw329.diagnostics.json" --raw-packet-limit 1200 --raw-time-from-ms 328500 --raw-time-to-ms 330500
```

In the `329476ms` window it parsed clean standard actor traffic, but that traffic
was for ability/projectile channels rather than channel-2 BaseReplayController
updates. This supports keeping the raw walker as a focused verifier while the
remaining work investigates the replay-specific compact/local framing layer.

Later raw-channel follow-up changed the working target. When the raw walker is
allowed to keep channel state warm instead of jumping directly to a late window,
the real replay controller appears on raw channel `1`, not compact channel `2`:

```text
timeMs=8
chIndex=1
actorNetGuid=2
archetypePath=Default__BaseReplayController_C
location={ x: 2382.2, y: -10417.9, z: 400 }
yaw=142.0587
```

The first-second raw scan also opens the ten player character actors on channels
`76`, `77`, `78`, `79`, `82`, `83`, `84`, `85`, `86`, and `87`, with actor
NetGUIDs `586`, `682`, `778`, `874`, `998`, `1088`, `1190`, `1286`, `1382`,
and `1508`.

The bounded raw extraction that currently proves the target RPC is:

```powershell
node tools\valorant_replay_probe\extract_track.mjs "C:\Users\shawn\AppData\Local\VALORANT\Saved\Demos\ff96dfb2-e766-40db-affb-a3af36a07b83.vrf" --out ".\tmp\ff96dfb2.rawfocus0_320.records.track.json" --diagnostics ".\tmp\ff96dfb2.rawfocus0_320.records.diagnostics.json" --raw-packet-limit 130000 --raw-time-from-ms 0 --raw-time-to-ms 320000 --raw-focus-channel 1 --diagnostics-only --skip-compact-diagnostics
```

Current local result:

```text
rawPacketsScanned=100034
movementRpcHitCount=50
replayControllerTargetVectorLaneSummary.length=0
replayControllerTargetNativeRecordSamples.length=350
```

The strict packed-vector probe now checks the standard Unreal packed-vector
scale factors `1`, `10`, and `100`, and requires a finite packed
`componentBits` value. Under those stricter rules, the target RPC has no
standard packed-vector lanes. Earlier apparent hits were raw-float fallback
false positives.

The target function payload should be treated as a native/custom bitstream. The
payload sizes strongly suggest an 80-bit full-record stride:

```text
80 bits    -> 1 * 80 + 0, count 23, first 73184ms, last 319533ms
1498 bits  -> 18 * 80 + 58, count 10, first 223087ms, last 223157ms
1141 bits  -> 14 * 80 + 21, count 1, first 59699ms
3445 bits  -> 43 * 80 + 5, count 1, first 59707ms
3487 bits  -> 43 * 80 + 47, count 1, first 123596ms
3782 bits  -> 47 * 80 + 22, count 1, first 123041ms
```

The single-record `80`-bit calls form repeated lanes. Examples:

```text
8ef267 count 6, firstIntPacked 71, secondIntPacked 121
5ef667 count 7, firstIntPacked 47, secondIntPacked 123
4ef667 count 5, firstIntPacked 39, secondIntPacked 123
fef367 count 5, firstIntPacked 127, secondIntPacked 2005497
```

At about `75.15s`, those prefixes cycle every ~8ms:

```text
75142 4ef667...
75150 8ef267...
75158 5ef667...
75166 fef367...
75174 4ef667...
75181 8ef267...
75189 5ef667...
75197 fef367...
75205 4ef667...
75213 8ef267...
75220 5ef667...
75228 fef367...
```

No exact known player actor NetGUID was found in the target payload by
int-packed or `uint32` scans. The stable prefixes and first packed integers look
more like compact lane/component identity than raw actor NetGUID values.

`tools/valorant_replay_probe/analyze_native_records.mjs` turns the diagnostic
record samples into a compact report:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-native-records -- --diagnostics ".\tmp\ff96dfb2.rawfocus0_320.records.diagnostics.json" --out ".\tmp\ff96dfb2.rawfocus0_320.native_records.report.json"
```

Its current fixed-field layout scan did not produce a confirmed `{x,y}` decode.
The best non-prefix, single-80-bit candidates either behave like local small
component values or have high p90 within-lane speed, so they should stay
diagnostic leads rather than app-facing movement tracks.

A longer `0-900s` all-channel raw pass keeps the same conclusion for the named
target handle:

```powershell
node tools\valorant_replay_probe\extract_track.mjs "C:\Users\shawn\AppData\Local\VALORANT\Saved\Demos\ff96dfb2-e766-40db-affb-a3af36a07b83.vrf" --out ".\tmp\ff96dfb2.raw0_900.broad_candidate_fields.track.json" --diagnostics ".\tmp\ff96dfb2.raw0_900.broad_candidate_fields.diagnostics.json" --raw-packet-limit 350000 --raw-time-from-ms 0 --raw-time-to-ms 900000 --diagnostics-only --skip-compact-diagnostics
npm --prefix tools\valorant_replay_probe run analyze-native-records -- --diagnostics ".\tmp\ff96dfb2.raw0_900.broad_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.broad_candidate_fields.native_records.report.json"
```

Current local result:

```text
rawPacketsScanned=253546
movementRpcHitCount=250
replayControllerTargetNativeRecordSamples.length=457
candidateFieldSummary.sampleCount=111629
```

For the named
`ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous` ClassNetCache
handle, the 0-900s payload families are bursty rather than continuous:

```text
80 bits count 63
74 bits count 43
96 bits count 32
24 bits count 19
75 bits count 18
1498 bits count 10
```

The stronger known-GUID recurrence scan still finds no repeated `intPacked` or
`uint32` player actor NetGUID inside that target payload. This makes the target
handle a proven native replay/event update payload, but not yet a proven
continuous movement track by itself.

The latest native-record analyzer also focuses the strongest broad fixed-pair
lead from that target payload. It tests each 80-bit candidate record as:

```text
bits 0-4:    possible lane/component id (uint5)
bits 5-20:   signed16 / 10
bits 21-36:  signed16 / 10
bits 37-52:  signed16 / 10
bits 53-68:  signed16, optionally yaw = signed * 360 / 2^16
```

Run:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-native-records -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.native_records.report.json"
```

Current local `candidatePacked80Layout` result:

```text
status=no-strict-lane-candidates
recordCount=457
x/y in Ascent bounds=457/457
strict z range -500..900=134/457 (29.3%)
loose z range -1000..2000=270/457 (59.1%)
```

This is a useful negative. The first two signed16 values are attractive because
they always project into Ascent map bounds, but that alone is too weak: the
signed16 range divided by ten is naturally close to Valorant map scale. Grouping
by the 5-bit id fails due to poor z plausibility and same-timestamp
multi-position conflicts. Grouping by record index produces static repeated
fragments with one or more impossible short-dt jumps. Grouping by the first
three bytes mostly yields static fragments or bad z ranges. No grouping passes
the report's strict lane heuristic, so these records are still
`ComponentDataStream` structure leads, not `{timeMs, netGuid, position,
viewRotation}` samples.

The same report now scans this focused layout at every shifted 80-bit stride
offset (`0..79`) across the captured target payload samples. Current local
result:

```text
candidatePacked80Layout.strideOffsetScan.evaluatedOffsetCount=80
strict shifted-offset lane candidates=0
best aggregate strict-z offsets:
  offset 27: strictZRate 0.328, strict candidates 0
  offset 57: strictZRate 0.294, strict candidates 0
  offset 68: strictZRate 0.294, strict candidates 0
  offset 0:  strictZRate 0.293, strict candidates 0
```

Some shifted offsets produce small stable-looking fragments, but they are
short, static, or have impossible short-dt jumps. This makes "wrong 80-bit
starting offset" unlikely as the only missing piece for the current target
payload sample set.

The possible `w`/yaw interpretation is also unproven. Comparing `w` against the
handle-122 yaw candidates gives enough close hits to stay interesting, but not
enough to prove identity or layout:

```text
window 16ms:  97 records matched, 12 within 5 degrees, median delta 20.67
window 32ms:  189 records matched, 24 within 5 degrees, median delta 20.24
window 100ms: 313 records matched, 58 within 5 degrees, median delta 15.77
window 250ms: 391 records matched, 141 within 5 degrees, median delta 8.58
```

Because handle 122 has ten active yaw-like lanes and the cross-check tries
several yaw transforms, close yaw-only matches are expected by chance. Treat
this as a weak corroborating clue only.

The replay-controller stream report now includes
`targetRpc1498SlotSummary.identityScan`. It scans the 1498-bit burst hypothesis
(`8 + 10 * 149`) for stable same-offset identity fields using `uint10..uint32`
and Unreal `intPacked`, comparing against known player actor GUIDs,
owner-info actor GUIDs, open actor GUIDs, and NetGUID path references. Current
local result:

```text
sampleCount=10
playerActor reference GUIDs=10
ownerInfoActor reference GUIDs=20
status=no same-offset stable identity layout maps all ten 149-bit slots to
       known player actor or owner-info GUIDs
stableUnknownUint32Layouts=[]
```

There are isolated exact hits such as `682`, `998`, `1088`, and `1286`, but they
occur at different offsets/encodings and do not form a reusable slot layout.
The newer focused target-RPC slot-array verifier below strengthens this: it
finds exact same-slot narrow identity clues for slot `0` and slot `1`, but still
does not find an authoritative all-slot actor NetGUID layout. Keep the
`8 + 10 * 149` split as an internal structure clue only; do not treat those
slots as ten labeled player updates.

The same pass added
`frameSummary.replayControllerCandidateFieldSamples` and
`candidateFieldSummary` to capture selected BaseReplayController ClassNetCache
payloads deeply, plus all other small ReplayController payloads. The most useful
new evidence is unknown BaseReplayController ClassNetCache handle `122`:

```text
fieldHandle=122
count=7510
92-bit payload count=7292
deduped 92-bit time+payload count=4048
top 92-bit prefixes:
  69cf0ef9 count 1023 raw / 623 deduped
  69cf0ef4 count 997 raw / 646 deduped
  69cf8efa count 812 raw / 359 deduped
  69cf4efb count 708 raw / 457 deduped
  69cffefb count 690 raw / 324 deduped
  69cffefa count 672 raw / 423 deduped
  69cf8efb count 668 raw / 407 deduped
  69cfcefa count 629 raw / 301 deduped
  69cf4efa count 604 raw / 288 deduped
  69cfcefb count 488 raw / 220 deduped
```

For each normal 92-bit prefix group, bits `0-49` and `68-91` are stable while
only bits `50-67` vary. The focused replay-controller analyzer now treats this
as the best view-yaw candidate:

```text
fieldHandle=122
payloadBits=92
laneCount=10
value=bits 50-67 as signed 18-bit
degrees = signed * 360 / 2^18
lane p90 angular speed ~= 496-648 degrees/sec
```

The older "coordinate" interpretation is probably wrong. If the same signed
18-bit value is interpreted as `units / 10`, the lane ranges look Valorant-sized
but adjacent samples imply tens of thousands of units per second. That rejects
it as a world coordinate while leaving it plausible as view yaw. It still cannot
be the full `{position, viewRotation}` sample alone: after deduping repeated
payloads, each lane contains only one 18-bit variable value and no proven actor
identity join.

The handle-122 lead can now be emitted as a view-rotation-only diagnostic:

```powershell
npm --prefix tools\valorant_replay_probe run emit-handle122-yaw -- ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.handle122_yaw.samples.json"
```

Current local output is 10 lanes / 4048 yaw samples. Each sample is shaped like
`{ timeMs, netGuid, position: null, viewRotation, source }`, where `netGuid` is
only the best open-yaw candidate match for that prefix. Several prefixes still
map to the same NetGUID under first-sample open-yaw matching, so this is a
confirmed continuous view-yaw lead but not a confirmed player identity or
movement track.

The broader small-payload capture found many other high-frequency unknown
BaseReplayController handles. Most are constants, flags, or small control
scalars. A few have lane-like prefixes, but none currently forms an obvious
ten-player `{x,y,z,yaw}` component set:

```text
field 90, 97 bits: 17 prefixes, 14 variable bits in the larger lanes
field 96, 95 bits: 8 prefixes, two dominant constant payloads
field 107, 115 bits: 7 prefixes, 10 variable bits in the largest lane
field 94, 91 bits: 14 prefixes, 32 variable bits in several lanes
field 45, 97 bits: 16 prefixes, several four-prefix clusters
```

The broader pass also found exact repeated player actor NetGUID recurrences in
some small unknown handles:

```text
field 99, 70 bits: intPacked actor NetGUID 778 at bit offset 45, count 283
field 126, 125 bits: intPacked actor NetGUID 1088 at bit offset 87, count 43
field 133, 95 bits: intPacked actor NetGUID 998 at bit offset 41, count 38
field 39, 86 bits: intPacked actor NetGUID 998 at bit offset 6, count 26
field 94, 82 bits: intPacked actor NetGUID 1190 at bit offset 44, count 25
```

Those are identity/control anchors, not position streams. They should be useful
for later lane-to-actor correlation, but they do not yet connect the ten
handle-122 scalar lanes to the ten opened player actor NetGUIDs.

The later large-payload capture raised the selected per-handle cap enough to
retain full payloads up to 8192 bits, then
`tools/valorant_replay_probe/analyze_replay_controller_streams.mjs` joined known
player NetGUID anchors to recurring packed-vector candidates in the same
payload. The cleanest current structure lead is unknown handle `24`:

```text
fieldHandle=24
payloadBits=3286
prefix=d55af0b3

NetGUID 586 at bit 683  -> packed vector at bit 1200, relative +517
NetGUID 778 at bit 1056 -> packed vector at bit 1575, relative +519
stable joined samples=51
```

That repeated `GUID + ~518 bits` relationship is unlikely to be accidental and
looks like a real sub-record layout clue. The follow-up h24 anchor-confidence
scan now makes the caveat sharper: only `778@1056/16` currently looks like a
strong intermittent identity lead, while most other known-NetGUID-looking values
are sparse or collision-prone. It is not yet a player position decoder: the
joined vectors are mostly component/local-scale values in the hundreds of units,
while confirmed actor-open world positions for the same replay are in the
thousands to ten-thousands of Unreal units. Treat this as a record-framing lead
for `ComponentDataStream`, not as app-ready coordinates.

The focused h24 neighborhood scan is now part of
`analyze_replay_controller_streams.mjs`. In the `0-900s` diagnostic it finds
eight recurring known-player NetGUID anchors inside the
`fieldHandle=24 / payloadBits=3286 / prefix=d55af0b3` payload family:

```text
778 @ bit 1056 count 62
586 @ bit 683  count 33
874 @ bit 3064 count 16
682 @ bit 1280 count 9
586 @ bit 2079 count 8
1286 @ bit 2982 count 8
1286 @ bit 2091 count 6
1190 @ bit 2420 count 5
```

The same h24 scan now scores whether each anchor is likely identity or numeric
collision. Current `0-900s` anchor-confidence highlights:

```text
778 @ bit 1056 exact 62/297, rate 0.209, confidence=strong-intermittent-identity-lead
586 @ bit 683  exact 33/297, rate 0.111, confidence=numeric-neighbor-collision-risk
874 @ bit 3064 exact 16/297, rate 0.054, confidence=intermittent-identity-lead
682 @ bit 1280 exact 9/297,  rate 0.030, confidence=sparse-collision-risk
1286 @ bit 2091 exact 6/297, rate 0.020, confidence=numeric-neighbor-collision-risk
```

For example, the `586@683` anchor has many nearby non-exact readings at the same
offset (`584/16` and `585/16`) plus `92/8` dominating the offset overall, so it
is now treated as a collision-risk anchor rather than trusted player identity.

The report separates all structural vector-shaped fields from a filtered
`candidateMovementLikeClusters` set. The best filtered cluster is still the
`~+518` relative-offset lead:

```text
centerRelativeOffset=515.8
relativeOffsets=513,516,517,519
movementLikeHitCount=3
uniqueNetGuidCount=2
netGuids=586,778
maxCoverage=0.848
```

That same report now emits a bounded
`h24SubrecordNeighborhoods.candidateMovementLikeSamples` diagnostic block with
rows shaped as `{ timeMs, netGuid, position, viewRotation: null, source }`.
The current `0-900s` report has 206 such rows from the top ranked h24 clusters,
but they are explicitly `candidate-h24-guid-adjacent-vector` rows. They are not
continuous, not yaw-linked, and not yet safe to feed the app as confirmed player
tracks.

Those h24 rows can now be packaged into a replay-viewer artifact without
claiming they are solved player tracks:

```powershell
npm --prefix tools\valorant_replay_probe run emit-h24-candidate-track -- ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_streams.report.json" --out ".\tmp\ff96dfb2.h24_candidates.track.json"
```

Current local output is 16 diagnostic tracks / 206 samples. Tracks are grouped
by NetGUID plus h24 source offsets (`guidOffset`, `vectorOffset`, and ranked
cluster) and use derived neighbor yaw only so the Icarus viewer can load them.
The track emitter preserves `anchorIdentityConfidence`; the current output has
2 tracks from `strong-intermittent-identity-lead` anchors, 6 tracks from
`numeric-neighbor-collision-risk` anchors, and 8 tracks from
`sparse-collision-risk` anchors. They should be used for visual triage or
Henrik-snapshot comparison, not as the final replay pipeline output.

The h24 transform-hypothesis pass tests whether those GUID-adjacent vectors are
raw world coordinates, actor-open-spawn-relative offsets, swapped-axis offsets,
or actor-open-yaw-rotated local offsets:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-h24-transform-hypotheses -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --stream-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_streams.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.h24_transform_hypotheses.report.json"
```

Current result:

```text
h24CandidateSampleCount=206
h24GroupCount=17
anchorSequenceDiagnostics.persistentIdentityLikeAnchorCount=0
passingGroups=0
status=no h24 transform hypothesis passed the strict continuous world-track gate
```

The same report now checks whether the known-NetGUID-looking h24 anchors behave
like persistent identity slots across all 297 captured h24 payloads. They do
not. The strongest `778@1056/16` anchor has 62 exact hits, but only in four
short bursts: `112360-112539ms`, `116157-117055ms`, `123346-123440ms`, and
`675493-675588ms`. Other anchors are even lower-rate or collision-prone, such
as `586@683/16`, where the most common value at the same offset is `92/8`, not
`586/16`.

The best strong identity anchor, `778@1056 -> vector@1572`, becomes only three
unique positions with about `122` game units of XY span after the best
open-yaw transform. The wider `778@1056 -> vector@1575` hypothesis has only 23
samples over `898ms` and a large adjacent jump. This rejects the simple
raw/spawn-relative/local-offset explanations for the current h24 vectors and
demotes the known-GUID hits to burst-local structure clues; h24 remains native
record-structure evidence, not a solved world-position track.

The broader large-payload transform verifier checks recurring packed-vector
candidates from all large ReplayController payload families under raw,
spawn-relative, swapped-axis, and open-yaw-local transforms:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-large-payload-transform-hypotheses -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --stream-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_streams.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.large_payload_transform_hypotheses.report.json"
```

Current result:

```text
rawPacketsScanned=253546
movementRpcHitCount=250
candidateFieldSampleCount=114442
specCount=181
identityAttributedSpecCount=2
position-gate passingGroups=2
promotableGroups=0
status=position-like large payload transforms found, but none pass NetGUID/view-yaw promotion gate
```

The two position-gate passers are unlabeled vector lanes, not replay tracks:
`16|1871|40b505d7|1755|100|17|1` and
`35|3137|be55aa19|468|100|19|1`. Both have `sourceNetGuid=null`, many unrelated
player-open transforms can make them map-bounded, and their temporal overlap
with handle-122 yaw is weak (`within33Rate` about `0.22` and `0.304`).

The same verifier now preserves and anchor-filters GUID-attributed joins even
when they duplicate unlabeled large-vector candidates. The two current
identity-attributed handle-24 joins remain structural only:

```text
586@683 -> vector@1200: 28 anchor-backed samples, 7 unique positions, xySpan 116.75, weak yaw overlap
778@1056 -> vector@1575: 23 anchor-backed samples over 898ms, 7 unique positions, xySpan 722.81, max adjacent speed 30117, one large jump
```

This is useful evidence for the native record layout, but it is still below the
threshold for `{timeMs, netGuid, position, viewRotation}` emission.

The same report also summarizes the named target RPC payload shapes. The target
RPC still has no repeated known player NetGUID anchor and no standard packed
world-position lane. Its 80-bit payloads form four stable first-byte lanes
(`8e`, `5e`, `4e`, `fe`) with variable bit ranges around `26-59` and `61-78`.
The 1498-bit burst can be split as `8 + 10 * 149`, but several slots are
constant or low-variation across the burst, so that split is only a hypothesis,
not a decoded ten-player update array.

`native80RecordSummary` now annotates the first int-packed token with Unreal's
hardcoded name table when it matches. The top 80-bit family
`prefix3=8ef267` starts with value `71`, which is the hardcoded name
`Transform`; another 1498-derived family has `102` (`Actor`) at record index
`4`. These are useful semantic hints, but surrounding tokens do not form a
clean property-tag stream and the identity scan still rejects player labels, so
they remain clues rather than decoded `ComponentDataStream` records.

The target-RPC signed-triplet guardrail is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-target-rpc-vector-layouts -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.target_rpc_vector_layouts.report.json"
```

It scans the proven target RPC as native 80-bit records and tests fixed signed
`x/y/z` triplets at each bit offset, grouped by token prefix and record index.
Current headline:

```text
native80RecordCount=457
exploratoryCandidateCount=25809
prefixScopedExploratoryCandidateCount=9292
mixedRecordIndexExploratoryCandidateCount=16517
strictPositionLaneCandidateCount=0
promotableCandidateCount=0
status=only exploratory target-RPC vector-like layouts found; no strict/promotable movement lane passed
```

The report deliberately separates mixed record-index guesses from prefix-scoped
clues. The strongest prefix-scoped rows are still not player movement: `cccd95`
starts with `Actor` and has only 12 samples, while the preserved `8ef267`
`Transform` clue has 17 samples, `realMagnitudeRate=0`, `xySpan=56.26`, only 7
adjacent continuity steps, and no authoritative NetGUID hit in the group. Treat
these as semantic tokens inside the native stream, not `{timeMs, netGuid,
position, viewRotation}` samples.

`analyze_replay_controller_streams.mjs` now includes two additional rejection
checks for this target:

```text
scalarPairCandidates.examinedPairCount=288
scalarPairCandidates.retainedCandidateCount=262
scalarPairCandidates.strictCandidates.length=0
scalarPairCandidates.rejectedHighJumpCandidates.length=26
```

The scalar-pair scan tries ordered variable-range pairs in small
ReplayController lanes as possible `{x,y}` fields and requires adjacent-frame
continuity. The best map-shaped false positives still fail on adjacent jumps:
examples include field `106` at `85` bits with p90 adjacent speed around
`1,228,800` units/sec and field `45` at `97` bits with p90 adjacent speed above
`11,000` units/sec. This rejects the current small-lane coordinate hypothesis
more strongly than the older p90-over-long-gaps check.

The focused target RPC framing analyzer is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-target-rpc-framing -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.target_rpc_framing.report.json"
```

It scans only the proven
`ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous` payloads,
summarizes native 80-bit records, tests offsets `0-15` as ordinary property
streams, and classifies identity-like hits separately from authoritative actor
NetGUID evidence. Current headline:

```text
target payload samples=250
status=only channel-index-shaped/collision-level layouts found; no authoritative actor NetGUID layout found in target payloads
authoritativeActorNetGuidLayoutCount=0
authoritativeActorNetGuidRecurringHitCount=0
exactActorNetGuidRecurringHitCount=2
exactChannelIndexMultiLayoutCount=15
transformedOrNeighborMultiLayoutCount=65
```

The current target payload families are:

```text
80 bits   count 63, first 73184ms, last 807133ms
74 bits   count 43, first 246187ms, last 844852ms
96 bits   count 32, first 333339ms, last 845141ms
24 bits   count 19, first 383320ms, last 613920ms
75 bits   count 18, first 84855ms,  last 844860ms
77 bits   count 17, first 90699ms,  last 845165ms
1498 bits count 10, first 223087ms, last 223157ms
```

The strongest 80-bit native-record families are stable, but their first packed
values are not player identities:

```text
8ef267 -> first int-packed 71/8,  count 17
5ef667 -> first int-packed 47/8,  count 16
4ef667 -> first int-packed 39/8,  count 15, collides with chIndex>>1 for NetGUID 778
fef367 -> first int-packed 127/8, count 15
```

The only recurring exact actor NetGUID hits are two `uint10` fragments for
NetGUID `682`, and neither appears in a >=16-bit or `uint32` shape. Treat them,
and the many 8-bit channel-index/neighbor/low-bit layouts, as collision-level
evidence unless a future layout split validates them externally.

The same report explicitly tests bit offsets `0-15` as normal target-function
RepLayout property streams. Current result:

```text
target payload samples=250
target export handles=0..3
best offset 1: plausibleCount=11, all terminator-only; top layouts are bad numBits / invalid handles
best offset 3: plausibleCount=8, all terminator-only; top layouts are invalid handle/numBits shapes
best non-empty candidate remains a one-off collision-level parse, not a recurring field layout
```

The one non-empty alignment occurs at `845141ms`, bit offset `13`, and parses as
`handle 1 / 67 bits` without recurrence. Its payload has packed-vector-shaped
readings, but only as a single collision-level lead; it is not enough to treat
the target RPC as a normal property stream.

The `8 + 10 * 149` target-burst hypothesis is now repeatable in
`targetRpc1498SlotSummary`. In the current sample it covers 10 payloads from
`223087ms` to `223157ms`. The important negative result is that it does not yet
look like the continuous ten-player position array:

```text
slot 4: 149/149 stable bits
slot 6: 149/149 stable bits
slot 1: 143/149 stable bits
slot 5: 141/149 stable bits
only exact known-player NetGUID hit: one-off intPacked 1088 at slot 7 bit 125
```

Some slots contain numeric-looking variable ranges, but they are either tiny
control values or jump across their full range over the 70ms burst. Treat this
as native target-RPC structure evidence, not a movement decoder.

The focused target-RPC slot-array verifier is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-target-rpc-array-slots -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.target_rpc_array_slots.report.json"
```

Current output keeps the ten-slot hypothesis alive but not solved:

```text
targetSampleCount=250
largeTargetSampleCount=15
slotPayloadCount=15
allLargePayloadsFitSlotModel=true
authoritativeActorNetGuidHitCount=0
exactSameSlotIdentityHitCount=5
strictPositionCandidateCount=0
status=large target-RPC payloads fit ten-slot RemoteCharacterUpdates framing with partial same-slot identity clues, but content is still unresolved
```

This proves every large named-target payload in the current capture can be split
as `headerBits = bitCount % 10` plus ten fixed-size records, but the report also
compares competing split counts for the 1498-bit burst. Prefix stability alone
does not uniquely prove ten records; the stronger reason to prefer ten is still
the native `RemoteCharacterUpdates` array shape and the known ten live player
actors. The identity scan now surfaces exact same-slot narrow identity clues in
the 1498-bit burst: slot `0` has `intPacked chIndex=76` at relative offset
`137` in all 10 samples, and slot `1` has `uint10 netGuid=682` at relative
offset `43` plus `intPacked chIndex=77` at relative offset `49` in all 10
samples. These are strong layout clues for the first two slot records, but they
are still narrow encodings and not the final authoritative
`ShooterCharacterNetGuidValue` layout for all ten slots.

`analyze_native_records.mjs` now also emits
`strictMovementPairCandidates` for fixed-width coordinate-pair hypotheses inside
the target RPC's native 80-bit record candidates. Strict candidates require both
axes to vary, plausible map bounds, real magnitude, no likely identity-prefix
overlap, and `p90Speed <= 1500` units/sec. Current result:

```text
strictMovementPairCandidates.allRecords.length=0
strictMovementPairCandidates.singleRecord80.length=0
strictMovementPairCandidates.bulkRecords.length=0
strictMovementPairCandidates.singleRecord80ByPrefix.length=0
strictMovementPairCandidates.bulkRecordsByPrefix.length=0
```

This rejects the tempting fixed-pair false positives: many layouts land inside
Ascent bounds by chance, but either one axis is static for a prefix lane or
adjacent-frame speeds jump into tens of thousands of units/sec.

Treat handle `122` as the best continuous player-lane yaw anchor, not as a
finished view/rotation lane. The analyzer now compares each 92-bit handle-122
prefix lane's first decoded angle against the ten player actor-open yaw values
under simple transforms. In the current sample all ten high-volume lanes have a
nearby open-yaw match under at least one transform, with best deltas ranging
from `0.581` to `5.786` degrees, but several lanes map to the same open player
under different transforms. This proves handle `122` is a strong continuous yaw
lane candidate, not a solved player identity mapping.

Treat handle `24` as the best current record-framing lead for a
player/component vector subfield. The next useful step is to decode the
handle-24 sub-record around the `GUID + ~518` vector relationship, then determine
whether that vector is a local position, velocity, delta, or component transform
that can be combined into world-space movement.

The focused ReplayController timeline analyzer ranks every captured
BaseReplayController ClassNetCache family by cadence, lane count, GUID
recurrence, and handle-122 yaw overlap:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-replay-controller-timeline -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_timeline.report.json"
```

Current `0-900s` result:

```text
target field 3 count=250, first=59699ms, last=845165ms
target median unique dt=8ms, p90 unique dt=10063ms, long gaps >1s=53
field 122 / 92 bits: 7292 samples, 10 high-volume lanes, yaw-only
field 24 / 3286 bits: 297 samples, 1 payload family, recurring GUID clues
field 46 / 4200 bits and field 100 / 1950 bits: GUID-bearing structure leads
fields 90/94/107/45: compact multi-lane scalar/control leads, not positions
```

The fixed-scalar position-hypothesis pass is now reproducible:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-position-hypotheses -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.position_hypotheses.report.json"
```

It starts from the ten decoded actor-open player spawns, scans fixed-width
signed scalar x/y pairs in ReplayController candidate payload families, and
then rejects anything that does not keep producing distinct map-plausible
positions with bounded short-step speed. Current `0-900s` result:

```text
candidateFieldSampleCount=111478
knownPlayerOpenSampleCount=10
spawnMatchedCandidateCount=12000
passingCandidateCount=0
status=no fixed-width signed scalar position hypothesis passed
       spawn-plus-continuity checks
```

The best rejected family is handle `122` / 92 bits, which can produce
spawn-near numbers if arbitrary bit slices are interpreted as coordinates, but
the analyzer now rejects that family as the known yaw lane and because one axis
is static. The most tempting static spawn family is handle `134` / 115 bits /
prefix `ac4d1f2e`: it repeatedly decodes within about one unit of early spawn
positions, but across hundreds of samples it has one or two unique positions
and zero real x/y span. Treat handle `134` as spawn/control state, not movement.

A follow-up split-axis check made handle `45` look coordinate-like in isolation,
but direct paired-lane checks rejected those slices as overlapping fragments:
the better pairs either stayed in a tiny repeated corridor or jumped at
impossible short-step speeds. A byte-aligned float scan also found no actor-open
spawn vector hits. The current negative boundary is therefore useful: simple
fixed-width signed scalar x/y pairs in the captured ReplayController lanes do
not yet explain continuous player movement. The remaining target is still the
native `ComponentDataStream` record framing, especially the large GUID-bearing
handle families.

The deinterleaved-position pass checks whether those false-positive scalar pairs
only failed because multiple entities were collapsed into one timeline:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-deinterleaved-position-lanes -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --stream-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_streams.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.deinterleaved_position_lanes.report.json"
npm --prefix tools\valorant_replay_probe run analyze-deinterleaved-position-lanes -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --stream-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_streams.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.deinterleaved_position_lanes.min20.report.json" --min-lane-samples 20
```

Current result:

```text
default: analyzedCandidateCount=80, exploratoryCandidateCount=16, strictCandidateCount=0
min20:   analyzedCandidateCount=67, exploratoryCandidateCount=10, strictCandidateCount=0
status=only exploratory deinterleaved scalar position hypotheses found; no strict continuous lane passed
```

The top exploratory lanes are handle `45` modulo partitions. They look plausible
only after being split into tiny, segmented bursts, often with one short segment
near `1-3s` and another near `470-471s`. None survives the stricter continuous
segment requirement. Treat this as a rejection of the current "collapsed
interleaved scalar lane" explanation; it does not produce confirmed
`{timeMs, netGuid, position, viewRotation}` samples.

The yaw-partitioned position pass tests the stronger version of that idea: use
the continuous handle `122` yaw prefixes as the partition key for nearby
non-yaw ReplayController lanes, then scan signed scalar `x/y` pairs inside each
partition:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-yaw-partitioned-positions -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.yaw_partitioned_positions.report.json"
```

Current result:

```text
yawLaneCount=10
candidateGroupCount=252
analyzedGroupCount=250
analyzedPartitionCount=129
retainedCandidateCount=14237
strictCandidateCount=0
status=no yaw-partitioned scalar position candidate passed strict continuity and map gates
```

The best rejected rows partition field `137` by yaw prefix `69cf8efa`, which
currently maps by open-yaw comparison to NetGUID `586`, but the scalar layouts
still fail on map bounds or short-step speed (`p90AdjacentSpeed` above
`5000` units/sec and one large adjacent jump). This rejects the current
"position is a small scalar lane that only needs handle-122 partitioning"
hypothesis. It does not rule out native packed-vector or custom
`ComponentDataStream` subrecords in the larger GUID-bearing handles.

The companion large-vector deinterleaving pass checks whether the recurring
packed-vector candidates are collapsed multi-entity streams that become coherent
after greedy continuity splitting:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-deinterleaved-large-vectors -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --stream-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_streams.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.deinterleaved_large_vectors.report.json"
```

Current result:

```text
candidateFieldSampleCount=114442
movementRpcHitCount=250
playerOpenSampleCount=10
specCount=62
analyzedSpecCount=62
identityAttributedCandidateCount=2
passingCandidateCount=0
status=no deinterleaved large-vector transform produced a strict position-like lane
```

The two identity-attributed candidates are the h24 GUID/vector joins. They are
still useful native record-shape clues, but not movement tracks:

```text
586@683 -> vector@1200: 28 anchor-backed samples; best split has 13 samples over 416ms, 3 unique positions, xySpan 74.55
778@1056 -> vector@1575: 23 anchor-backed samples; best split has 16 samples over 516ms, 6 unique positions, xySpan 0
```

This rejects the broad "large packed vectors are simply interleaved player
position lanes" hypothesis under raw, spawn-relative, swapped-axis, and
open-yaw-local transforms. The remaining target is a native
`ComponentDataStream` bit layout that probably contains snapshot-shaped fields
more compactly than the reflected `RemoteClientMovementSnapShot` /
`ShooterSnapshotMove` names expose.

The large slot-array position verifier is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-large-slot-array-positions -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --large-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.large_payload_transform_hypotheses.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.large_slot_array_positions.report.json"
```

It reinterprets the two large position-like offsets from
`large_payload_transform_hypotheses` as offsets inside ten fixed records, then
uses the known player actor channel order only as a temporary slot identity
guess:

```text
fieldHandle=16 bitCount=1871 absoluteOffset=1755 -> headerBits=1, recordBits=187, slotIndex=9, relativeOffset=71, slotNetGuid=1508
fieldHandle=35 bitCount=3137 absoluteOffset=468  -> headerBits=7, recordBits=313, slotIndex=1, relativeOffset=148, slotNetGuid=682
passingSlotTransformCount=10
fusedCandidateSampleCount=24
status=position-like large payload offsets align with slot records and produce slot-inferred position/yaw candidate samples
```

This is the strongest structural hint after the seeded transform: the unlabeled
large-vector offsets are not arbitrary absolute offsets; they land inside the
same ten-slot record model. The emitted `candidateSamples` are still
position-only, and `fusedCandidateSamples` are capped diagnostic
`{timeMs, netGuid, position, viewRotation}` rows from same-slot handle-122 yaw
joins. In the current capture, only the handle-35/slot-1 candidate for
NetGUID `682` has same-inferred-NetGUID yaw matches, and only six rows per
position transform variant. Handle `16`/slot `9` has nearby yaw generally but no
same-inferred-NetGUID handle-122 lane for NetGUID `1508`. Because multiple
position transforms still pass and slot identity is inferred from channel order
rather than an encoded `ShooterCharacterNetGuidValue`, these rows are not
app-facing replay tracks yet.

The broader slot-aware `ComponentDataStream` scanner is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-slot-component-stream-candidates -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.report.json"
```

Unlike `analyze-large-slot-array-positions`, it does not start from the two
previously surfaced vector offsets. It scans repeated large ReplayController
payload families as `headerBits + 10 * recordBits`, tries every slot-relative
packed-vector start, applies the temporary slot-player identity, scores
map/continuity, and then checks same-slot handle-122 yaw. Current default output:

```text
scannedGroupCount=10
candidateCount=7872
sameIdentityYawCandidateCount=969
movementShapeCandidateCount=41
strictMovementCandidateCount=18
fusedCandidateSampleCount=120
status=slot-aware scan found strict movement-shaped position/yaw candidates
```

A wider low-frequency pass does not add new strict identities:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-slot-component-stream-candidates -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --min-group-samples 20 --max-groups 40 --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.report.json"
```

```text
scannedGroupCount=23
movementShapeCandidateCount=59
strictMovementCandidateCount=18
all strict candidates are slotIndex=1 / slotNetGuid=682
```

The strict set currently collapses to two non-ambiguous slot-1 families for
NetGUID `682`, but still with transform/scale ambiguity:

```text
handle 35, 3137 bits, prefix be55aa19:
  headerBits=7, recordBits=313, relativeOffset=148, absoluteOffset=468
  packed vector componentBits=19, extraInfo=1
  102 rows, 38-41 unique positions, xySpan 213..2135 depending scale/transform
  same-slot yaw: 6 rows via handle-122 prefix 69cffefa

handle 54, 2035 bits, prefix 77f4fe23:
  headerBits=5, recordBits=203, relativeOffset=137, absoluteOffset=345
  packed vector componentBits=15, extraInfo=1, scaleFactor=100
  149 rows, 85-87 unique positions, xySpan 232..241 depending transform
  same-slot yaw: 6 rows via handle-122 prefix 69cffefa
```

This is the first scanner that produces strict, non-ambiguous
position/yaw-shaped rows rather than only position-like rows, but it still does
not complete the replay-track decoder. The strict candidates cover only one
slot-inferred player (`682`), the correct world transform is not unique, and
the identity remains inferred from slot/channel order instead of decoded from
`ShooterCharacterNetGuidValue`. Ambiguous-yaw movement-shaped candidates exist
for other slots, especially slot `6`/NetGUID `1190` and slot `0`/NetGUID `586`,
but they stay out of strict promotion until yaw identity and record identity are
proved.

The same scanner can now emit selected candidate sample rows directly:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-slot-component-stream-candidates -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --min-group-samples 20 --max-groups 40 --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.report.json" --samples-out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.samples.json" --track-out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.track.json" --sample-candidate-scope movement --sample-dedupe family --max-sample-candidates 12
```

Current local output selects `10` deduped movement families, writes `963`
diagnostic rows shaped as
`{timeMs, netGuid, position, viewRotation, source, confidence}`, and has `103`
rows with same-slot handle-122 yaw filled in. The viewer-ready track output has
`10` candidate tracks and `963` samples. Because the Flutter replay model
requires numeric `yawDegrees`, that track file uses movement-direction yaw as a
viewer fallback whenever decoded handle-122 yaw is absent; the proof
`*.samples.json` file keeps absent decoded yaw as `null`.

The scanner now records full-3D plausibility separately from the older 2D
movement/yaw gate. The strict slot-1 NetGUID `682` families remain good
identity/yaw structure leads, but both fail full xyz plausibility because their
third component produces impossible short-dt movement (`p90Adjacent3dSpeed`
`26720..75535` units/sec, with large z steps). The most plausible 3D-shaped
candidate rows in the selected output are instead slot `6` / NetGUID `1190`
families such as handle `24` relative offset `93` and handle `100` relative
offset `24`; these have smoother z and 3D speeds but still have ambiguous
handle-122 yaw identity. Treat the strict `682` rows as record/identity/yaw
evidence, not as final world-position samples.

The scanner now accepts `--sample-candidate-scope position3d` and
`--sample-candidate-scope position3d-movement` so proof artifacts can be biased
toward the full xyz gate instead of the older strict-yaw gate:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-slot-component-stream-candidates -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --min-group-samples 20 --max-groups 40 --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.report.json" --samples-out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.position3d_movement.samples.json" --track-out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.position3d_movement.track.json" --sample-candidate-scope position3d-movement --sample-dedupe family --max-sample-candidates 12
```

Current `position3d-movement` output selects `3` deduped slot `6` / NetGUID
`1190` families, writes `247` proof rows, and has `26` proof rows with decoded
handle-122 yaw. The selected families are handle `24` / `3286` /
`d55af0b3` at relative offset `93`, plus handle `100` / `1950` at relative
offset `24` for prefixes `d85fa616` and `f85fa616`. The viewer track has `3`
unique candidate ids after including `prefixHex` in the track id. All three
still carry `ambiguous-yaw-identity`, so this is the cleanest current
3D-movement proof surface, not a promoted replay decoder.

The broader `position3d` artifact is useful for structure review:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-slot-component-stream-candidates -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --min-group-samples 20 --max-groups 40 --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.report.json" --samples-out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.position3d.samples.json" --track-out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.position3d.track.json" --sample-candidate-scope position3d --sample-dedupe family --max-sample-candidates 12
```

Current `position3d` output selects `12` families, writes `2703` proof rows,
and has `452` rows with decoded handle-122 yaw. Its shape-only rows should not
be mistaken for movement; they are mostly useful for inspecting record anatomy
around plausible xyz fields.

The slot-neighborhood verifier is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-slot-candidate-neighborhoods -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --slot-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_candidate_neighborhoods.report.json"
npm --prefix tools\valorant_replay_probe run analyze-slot-candidate-neighborhoods -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --slot-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.report.json" --candidate-scope movement --max-families 40 --identity-window-bits 180 --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_candidate_neighborhoods.movement.report.json"
npm --prefix tools\valorant_replay_probe run analyze-slot-candidate-neighborhoods -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --slot-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.report.json" --candidate-scope position3d --max-families 40 --identity-window-bits 180 --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_candidate_neighborhoods.position3d.report.json"
```

For the strict NetGUID `682` families, the target slot contains identity-shaped
fields near the candidate vector: handle `35` has same-slot `chIndex=77`
`intPacked` hits at relative offsets `93` and `141` plus a `uint10` NetGUID
`682` hit at relative offset `135`; handle `54` has same-slot `chIndex=77`
hits around offsets `120..132` and a `uint10` `netGuid+1=683` hit at relative
offset `18`. The movement-scope run shows the other movement-shaped families
are not random slot collisions: slot `6` / NetGUID `1190` candidates have
same-slot `chIndex=84` hits, and slot `0` / NetGUID `586` candidates have
same-slot `chIndex=76` hits. That is enough to treat them as identity-backed
`ComponentDataStream` structure leads, but not enough to mark their yaw lanes
non-ambiguous.

The `position3d` neighborhood report analyzed `28` families. For the tight
3D-movement leads, handle `24` / slot `6` / relative offset `93` has same-slot
`chIndex=84` clues at relative offsets `7`, `8`, and `240`; the vector encoding
is present in `131/297` group samples. The two handle `100` / slot `6` /
relative offset `24` prefixes have the expected vector encoding in `58/58`
samples each and same-slot `chIndex=84` clues around relative offsets `16`,
`17`, `109..110`, and `120`. These make slot `6` / NetGUID `1190` the strongest
current 3D movement-structure lead, but the identity is still channel-order
inferred until the native `ShooterCharacterNetGuidValue` field is decoded.

The focused decoder-lead report starts from the selected
`position3d-movement` proof families and inspects only their native slot records:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-slot-component-decoder-leads -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --samples ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.position3d_movement.samples.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json"
```

Current output analyzes `3` selected families and one handle-100 prefix pair:

```text
h24 / 3286 / d55af0b3:
  ten-slot shape: 6 header bits + 10 * 328 record bits
  selected vector: slot 6, rel 93, bitsAndInfo 75, componentBits=11, extraInfo=1
  selected vector presence: 131/297 rows in slot 6, 13 total hits in all other slots
  strongest same-slot identity clue: intPacked chIndex=84 at rel 7 in 216/297 rows
  presence/absence separator: rel bit 33 is 1.000 when the vector is present vs 0.054 when absent

h100 / 1950 / d85fa616 and f85fa616:
  ten-slot shape: 10 * 195 record bits
  selected vector: slot 6, rel 24, bitsAndInfo 78, componentBits=14, extraInfo=1
  selected vector presence: 58/58 rows in slot 6 for each prefix, 2 total hits in all other slots
  strongest same-slot identity clue: uint8 chIndex=84 at rel 17 in 23/58 and 21/58 rows
  prefix pairing: d85fa616 and f85fa616 are nearest-time partners within 16ms for 57/58 samples
```

That is stronger evidence for a slot-local `ComponentDataStream` record than the
older broad vector scans, but it also sharpens the remaining blocker: the
selected vectors are low-magnitude local/component values (`h24` roughly
`-100..100` after scale `10`, `h100` roughly `-80..81` after scale `100`), not
decoded Valorant world positions. The next decoder step is to find the native
field or transform that turns these slot-local values into world movement, and
to replace channel-order identity with the actual `ShooterCharacterNetGuidValue`
parse.

The selected-slot world-position guardrail checks that this is not merely a
missed nearby packed-vector offset or one of the already-tested raw/open-relative
transforms:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-selected-slot-world-position-leads -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --decoder-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.selected_slot_world_position_leads.report.json"
```

Current result:

```text
status: selected h24/h100 slot records have no simple packed-vector world-position transform
families analyzed: 3
worldPositionLeadCount: 0
replayTrackPromotableCount: 0
```

The best rejected rows are the selected vectors themselves. They are stable and
map-bounded under slot-open transforms, but fail the world-position gate because
their spans are too small for continuous movement over long replay time:

```text
h24 selected rel 93: 131 rows, xySpan ~273, p90 3D speed 3700, rejected for low-world-xy-span
h100 d85fa616 rel 24: 58 rows, xySpan ~204, p90 3D speed 2307, rejected for low-world-xy-span
h100 f85fa616 rel 24: 58 rows, xySpan ~216, p90 3D speed 2549, rejected for low-world-xy-span
```

Other packed-vector-looking offsets inside the same slot records either have too
few samples, implausible speed/z jumps, map/z-bound failures, or static
fragments. This makes the h24/h100 leads useful for native record anatomy and
component state, but not app-facing world-position emission.

The selected-slot integration sweep tests the next hypothesis: maybe those
local/component vectors are not absolute positions, but per-sample deltas or
velocities that need to be accumulated from the slot actor-open transform:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-selected-slot-integration-hypotheses -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --decoder-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json" --yaw-samples ".\tmp\ff96dfb2.handle122_yaw.samples.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.selected_slot_integration_hypotheses.report.json"
```

Current result:

```text
status: selected slot vectors have strict full-xyz integration-shaped hypotheses, but none are replay-track promotable
series analyzed: 4
strictFullPositionPassCount: 127
strictHorizontalOnlyPassCount: 147
broadFullPositionPassCount: 159
broadHorizontalOnlyPassCount: 173
```

The strongest strict leads are velocity-style integrations from the slot open
location, usually using actor-open yaw rather than handle-122 yaw:

```text
h24 d55af0b3: velocity-capped-dt, swapxy, open-yaw, scale 10 -> xySpan 3402, p90 3D speed 1142, p90 z step 6.7
h100 d85fa616: velocity-actual-dt with long-gap reset, xyz, open-yaw, scale 10 -> xySpan 960, p90 3D speed 1007, p90 z step 23.6
h100 f85fa616: velocity-capped-dt, xyz, open-yaw, scale 10 -> xySpan 970, p90 3D speed 955, p90 z step 23.1
h100 merged prefixes: velocity-capped-dt, xyz, open-yaw, scale 10 -> xySpan 1026, p90 3D speed 1005, p90 z step 14.8
```

The strongest h100 integration leads can be emitted as a viewer/proof artifact:

```powershell
npm --prefix tools\valorant_replay_probe run emit-selected-slot-integration-candidate-track -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --decoder-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json" --integration-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.selected_slot_integration_hypotheses.report.json" --handle122-prefix 69cf8efb --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.selected_slot_h100_integration_candidate.track.json" --samples-out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.selected_slot_h100_integration_candidate.samples.json"
```

Current local output writes `3` h100 slot-6 review tracks (`merged`, `d85fa616`,
and `f85fa616`) with `232` integrated movement samples. The proof file uses the
decoder-facing shape `{timeMs, netGuid, position, viewRotation, source,
confidence}`. The merged track has `116` samples, `xySpan=1026.08`, p90 3D
speed `1005.1`, p90 z step `14.79`, and stays in Ascent bounds. Handle-122
prefix `69cf8efb` contributes decoded yaw to only `25/116` merged samples
(`50/232` across all three tracks); the viewer track uses movement-direction
yaw as a fallback where decoded yaw is absent.

The broad h100 slot/offset integration verifier checks whether this is a
slot-6-only curiosity or a repeatable full-array decode:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-h100-slot-integration-candidates -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.h100_slot_integration_candidates.min25.report.json" --min-group-samples 25 --min-vector-samples 25
```

Current v3 output has `4206` strict full-xyz shape passers across all `10`
slots once the four short h100 prefix lanes are allowed through
`--min-group-samples 25`; `640` also pass the source-vector stability guardrail.
This is still a guardrail rather than a promotion signal. The only handle-122
lane in the v3 captured surface is far away in time (`0` rows within `64ms`),
multiple axis/scale variants pass, and identity still comes from slot order
rather than a decoded `ShooterCharacterNetGuidValue`.

The same h100 report now includes a source-vector stability guardrail before
integration. This checks that the packed vector at the candidate bit offset is
present often enough, has enough distinct values, and does not jump wildly in
raw/scaled component space before any open-yaw velocity integration is applied.
Current v3 output:

```text
strictFullPositionPassCount=4206
sourceStableStrictFullPositionPassCount=640
best source-stable examples include prefix 785ea616, slot 4, rel41 / 11+0,
but no source-stable h100 candidate has same-slot view-yaw coverage
```

This is useful because it proves the surviving h100 `1950` lanes still contain
movement-shaped local values under corrected framing. It is not enough to emit a
track: the report remains sensitive to axis/scale choices and lacks native
identity plus same-time view yaw.

The native `ComponentDataStream` verifier ports the refreshed playground model
and applies it to captured target-RPC payloads:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-component-data-stream-native -- --diagnostics ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.component_data_stream_native.report.json" --samples-out ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.component_data_stream_native.samples.json" --track-out ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.native_component.track.json"
```

Current release-12.11 output is the first confirmed native movement decode:

```text
targetPayloads=260
strictRpc=260
componentOk=2599
movementSampleCount=2610
direct target-payload movement scan: hitCount=3084
```

The older seeded-transform and v3 diagnostics were strong negative results:
they had `targetPayloads=0` or `strictRpc=0`, and direct scans found no valid
native `0x52` movement section. Those failures were caused by using the wrong
transform/framing for the current replay branch, not by the playground native
movement model being wrong. Keep the old h100 work in the "record anatomy"
bucket; the current source of truth is the strict release-12.11
`RemoteCharacterUpdates -> ComponentDataStream` parse.

The reflected-RPC property alignment check is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-replay-controller-rpc-property-alignment -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.rpc_property_alignment.report.json"
```

It analyzes `1482` named BaseReplayController RPC payloads across `6` fields.
The important result is that ordinary named ReplayController RPCs also do not
look like normal Unreal `ReceiveProperties` streams. Small calls such as
`ClientGamePhaseBegin` frequently carry only a few bits, and larger calls fail
with out-of-range handles/field bit counts rather than clean property handles.
That makes the target function body likely custom/direct native RPC parameter
data, not a misframed reflected property stream.

The focused direct target-RPC layout check is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-target-rpc-direct-layouts -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.target_rpc_direct_layouts.report.json"
```

Current output:

```text
target samples=250
repeated compact families=6
status=target RPC is custom/direct: compact families expose narrow exact actor identities, but no strict absolute movement lane
strictMotionCandidates=0
best canonical intPacked count models: plausibleRate <= 0.404, integerRecordRate <= 0.22, guidBoundaryHitCount=0
```

The strongest compact-family identity clues are now explicit:

```text
108 bits / prefix 3f422366: uint10 netGuid=586 at bit 45 in 71/71 rows
84 bits / prefix 5c311049: uint11..13 netGuid=1088 at bit 14 in 54/54 rows
116 bits / prefix 01ed9ffc: uint10..11 netGuid=874 at bit 55 in 22/22 rows
116 bits / prefix 85755749: uint10..12 netGuid=586 at bit 21 in 4/4 rows
```

These are better than random scalar collisions because they are exact actor
values covering entire compact families. They are still not sufficient for
track emission: the widths are narrow/custom rather than `uint32` or
`intPacked`, and the best post-identity signed-triplet scans are tiny local
values, static axes, or otherwise non-absolute movement clues. The next decoder
step should treat these compact records as identity-tagged native
`ComponentDataStream` fragments and solve the local delta/velocity encoding,
not retry the reflected-property parser.

The combined RemoteCharacterUpdate identity-layout verifier is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-remote-character-update-identity-layouts -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --decoder-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.remote_character_update_identity_layouts.report.json"
```

This scans the large named target-RPC slot payloads, the four h100 `1950`-bit
prefix families, and the selected h24 decoder family for a repeated
slot-relative identity layout. It distinguishes isolated same-slot hits from a
true shared layout where the same encoding and relative offset identify
multiple correct slots. Current output:

```text
identity families scanned=6
authoritative actor-NetGUID layout candidates=0
majority exact identity-like layouts=0
low-coverage multi-slot exact layouts=2
status=only low-coverage identity-like layouts found; no shared ShooterCharacterNetGuidValue layout proved
best shared layout=target RPC 1498 bits, rel137 intPacked chIndex, 2/10 slots
```

Important per-family clues from that report:

```text
target RPC 1498 bits: exact same-slot clues in 8/10 slots, but at isolated offsets.
  Best actor-shaped clue is slot 5 uint11 netGuid=1088 at rel122 in 10/10 rows.
  Shared exact clue is only intPacked chIndex at rel137 covering slots 0 and 2.
h100 1950-bit prefixes: no shared identity layout.
  Repeated isolated actor-shaped clues include slot 7 uint11 netGuid=1286 at rel5
  and slot 2 uint11 netGuid=778 at rel44/rel80, each only about 0.236..0.259
  of rows depending on prefix.
h24 d55af0b3: strongest clue remains slot 6 intPacked chIndex=84 at rel7
  in 216/297 rows, with no shared majority identity layout.
```

This sharpens the current boundary: h100/h24 records expose real slot-local
identity-looking fields, but not a single `ShooterCharacterNetGuidValue` layout
that can label movement samples. The selected h100 integration artifact is
therefore still a decoder proof sample, not an app-facing player track.

This is a better lead than the absolute-position interpretation, but it is not
a decoded replay track. Same-NetGUID handle-122 yaw coverage within `64ms` is
only about `0.198..0.224` for those strongest leads, and the handle-122 identity
mapping is still open-yaw inferred and ambiguous. The integration report
therefore keeps every candidate non-promotable with
`insufficient-same-netguid-handle122-view-yaw-coverage`,
`selected-slot-vector-is-still-diagnostic-not-native-world-position`, and
`view-yaw-identity-is-unconfirmed-or-ambiguous`. Use these as focused
ComponentDataStream velocity/delta leads, not app-facing `{position,
viewRotation}` samples.

The selected-slot yaw/identity scalar sweep checks whether the same h24/h100
target slot records already contain a simple yaw field that can be joined to the
position-shaped integrations:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-selected-slot-yaw-identity-leads -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --decoder-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json" --yaw-samples ".\tmp\ff96dfb2.handle122_yaw.samples.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.selected_slot_yaw_identity_leads.report.json"
```

The scanner tries unsigned/signed yaw scalars at widths `8,10,12,13,14,15,16,
18,20,24`, all five handle-122 yaw transforms, and every bit offset inside the
selected target slot record. A candidate must avoid overlapping the selected
packed vector, be temporally smooth enough, and have enough same-NetGUID
handle-122 coverage/agreement. Current output:

```text
status: selected slot records have no scalar yaw field passing same-NetGUID handle122 agreement gates
families analyzed: 3
yawLeadCount: 0
replayTrackPromotableCount: 0
```

Best rejected rows show why this is a dead end for now:

```text
h24 d55af0b3: best rejected rel 183 width 10, same-NetGUID handle122 compared 27/297 rows (0.091 rate), within15 0.667, rejected for low temporal coverage
h100 d85fa616: best rejected rel 124 width 24, same-NetGUID compared 13/58 rows (0.224 rate), within15 0.692, rejected for low temporal coverage plus high p90 angular speed
h100 f85fa616: best rejected rel 160 width 24, same-NetGUID compared 12/58 rows (0.207 rate), within15 0.667, rejected for low temporal coverage
```

The loose version of this scan produced thousands of coincidence-shaped scalar
matches, including fields that overlapped the selected packed vector. The
stricter report is the useful artifact: it rejects simple scalar yaw inside the
selected slot records. The next yaw/identity step should target the handle-122
lane identity itself or a native field outside these selected h24/h100
ComponentDataStream subrecords, not another scalar sweep of the same bit ranges.

The focused handle-122 lane identity report is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-handle122-lane-identity -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --decoder-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.handle122_lane_identity.report.json"
```

Current output keeps only recurring handle-122 lanes (`minLaneSamples=20`) and
finds exactly `10` full-payload prefix lanes. Across those lanes, the first
`32` payload bits vary only in prefix bits `20..27`; the report exposes this as
an 8-bit lane key (`offset20Width8`, `highNibble20`, `lowNibble24`, and
`bits20To27`). This is the best current candidate for a handle-122 lane key,
but it does not directly match slot index, channel index, or NetGUID.

The report also confirms why first-open-yaw identity is weak:

```text
status: handle122 lane identity remains ambiguous; co-occurrence gives prefix leads only
handle122LaneCount: 10
prefix variable range: bits 20..27
best-open-yaw NetGUID collisions: 6/10 lanes
```

Selected slot-6 co-occurrence is now explicit:

```text
h24 d55af0b3 slot 6: best handle122 overlap is 69cf4efb, within64MsRate 0.092
h100 d85fa616 slot 6: best handle122 overlap is 69cf8efb, within64MsRate 0.224
h100 f85fa616 slot 6: best handle122 overlap is 69cf8efb, within64MsRate 0.207
```

For the h100 position-shaped leads, prefix `69cf8efb` is therefore the strongest
current handle-122 yaw partner for slot `6` / NetGUID `1190`. Its prefix lane key
is `offset20Width8=184` (`bits20To27=00011101`) and its best open-yaw match is
also slot `6`, but that open-yaw identity is still ambiguous because several
handle-122 prefixes initially match NetGUID `1190`. Treat `69cf8efb` as the next
focused lane-identity lead, not as an authoritative view-yaw assignment.

This makes the current boundary sharper: the named target RPC proves the native
`RemoteCharacterUpdates` call site but is sparse/bursty in this sample, so it is
not by itself the continuous 10-player movement track. The continuous signal is
likely split across the target RPC plus adjacent opaque ReplayController handles.
Handle `122` is the best view-yaw stream, while the large GUID-bearing handles
are the best remaining record-framing leads for `ComponentDataStream`.

The referenced Valorant playground source was re-checked. Its Valorant-specific
reader copies the remaining replicator payload, seeds the transform with
`payloadBits ^ actorGuid`, applies the Valorant seeded transform, and then
delegates back to the normal Unreal `ReceivedReplicatorBunch`/`ReceivedRPC`
path. Its current `BaseReplayController` model defines the target RPC, and its
native `ComponentDataStream` model is now ported into
`analyze_component_data_stream_native.mjs`. Treat the playground as
confirmation of the transform/framing layer and as a source-derived native
movement verifier, but not as proof that the current captured h3 payloads are
already clean RPC payloads.

The ReplayController ClassNetCache streams remain the best target for player
position/look-direction progression. The named target RPC gives the native
`RemoteCharacterUpdates` boundary, while unknown high-frequency handles such as
`122` may carry split component lanes. The likely structure is:

- `ShooterCharacterNetGuidValue` identifies the remote character actor.
- `RemoteCharacterUpdates` and/or `ComponentDataStream` contain compact
  transform updates for that character over replay time.
- Frame time comes from the replay playback packet timestamp.
- Once `ShooterCharacterNetGuidValue` is decoded per update, attribution should
  be a join from runtime NetGUID to character/player-state replication, then to
  the header `subject`/PUUID and public content UUIDs.

Player-character class NetGUID path names surfaced for the sample:

```text
/Game/Characters/Clay/Clay_PC.Clay_PC_C
/Game/Characters/Grenadier/Grenadier_PC.Grenadier_PC_C
/Game/Characters/Hunter/Hunter_PC.Hunter_PC_C
/Game/Characters/Iris/Iris_PC.Iris_PC_C
/Game/Characters/Killjoy/Killjoy_PC.Killjoy_PC_C
/Game/Characters/Phoenix/Phoenix_PC.Phoenix_PC_C
/Game/Characters/Sequoia/Sequoia_PC.Sequoia_PC_C
/Game/Characters/Smonk/Smonk_PC.Smonk_PC_C
/Game/Characters/Smonk/Smonk_PostDeath_PC.Smonk_PostDeath_PC_C
/Game/Characters/Wushu/Wushu_PC.Wushu_PC_C
```

## Icarus coordinate conversion

The old `ai-chat-window` branch already has the Valorant-to-Icarus map math:

- `lib/const/valorant_match_mappings.dart`
- `lib/const/coordinate_system.dart`
- `assets/data/map_data.json`

The raw Valorant API mapping there is:

```text
u = (gameY * xMultiplier) + xScalarToAdd
v = (gameX * yMultiplier) + yScalarToAdd
```

Then Icarus applies map-specific import rotation and converts padded Valorant
percent coordinates into the displayed SVG/container space. For Ascent, the
old branch uses:

```text
xMultiplier = 0.00007
yMultiplier = -0.00007
xScalarToAdd = 0.813895
yScalarToAdd = 0.573242
import rotation = 1 clockwise quarter-turn
```

Once the replay RPC gives raw game-space position vectors, this branch should
reuse that conversion path instead of re-solving projection.

## Probe script

`tools/valorant_replay_probe/probe.mjs` parses the stable outer layers:

- Valorant wrapper id and local replay stream offset.
- Unreal local replay chunk table.
- Header strings and JSON snippets.
- Replay data compression envelope.
- Event chunk metadata and grouped counts.
- Optional first replay data Oodle decompression check.

Usage:

```powershell
node tools\valorant_replay_probe\probe.mjs
node tools\valorant_replay_probe\probe.mjs "C:\Users\shawn\AppData\Local\VALORANT\Saved\Demos\ff96dfb2-e766-40db-affb-a3af36a07b83.vrf"
npm --prefix tools\valorant_replay_probe install
node tools\valorant_replay_probe\probe.mjs --decompress-first
```

## Next steps

1. Move the confirmed native decoder from
   `analyze_component_data_stream_native.mjs` into the normal preprocessing
   path, or add a focused emitter command, so a single command can produce the
   app-facing replay track from a `.vrf`.
2. Join actor NetGUIDs to player state and header loadout data. The current
   track labels use actor-open class paths and NetGUIDs; duplicate agents such
   as the two Sova/Hunter players still need the PlayerState/subject identity
   join.
3. Validate the native track against Henrik sparse kill snapshots and the
   Flutter viewer. The first-frame samples match actor-open spawn transforms;
   the next useful confidence check is time-local distance to labeled match
   snapshots after the established Henrik `-10016ms` offset.
4. Harden raw packet scanning for full-replay extraction. The bounded raw
   walker is fast enough for the current `0-900s` target pass, but raw scanning
   should stay opt-in until misframed packet paths cannot spin for too long.
5. Expand branch coverage. `verify_seeded_payload_transform.mjs` now covers the
   playground backcompat payload and a release-12.11 replay smoke sample; future
   replay branches should add explicit transform versions and replay fixtures.
6. Keep the older h24/h100/handle-122 candidate analyzers as regression
   guardrails only. The current source of truth for player movement is strict
   target-RPC parsing plus native `ComponentDataStream` movement samples with
   decoded NetGUIDs.

## App viewer status

The Flutter app now has a first usable replay-viewing mode that consumes replay
track JSON, renders player markers over the Icarus map, draws yaw-based view
cones, and supports play, pause, scrubbing, speed changes, and per-player
visibility.

The viewer can load the current `.vrf`-derived native ComponentDataStream track:
`tmp/ff96dfb2.raw0_900.v4_12_11_transform.native_component.track.json`. This is
the first confirmed continuous ten-player movement extraction from the replay
file. The included `assets/replays/ascent_demo_track.json` fixture remains a
hand-authored UI smoke fixture, but it is no longer the only reliable way to
exercise the coordinate path.

## Preprocessing direction

The right runtime shape is offline preprocessing:

```text
.vrf -> replay_track.json -> Flutter replay viewer
```

`tools/valorant_replay_probe/extract_track.mjs` now performs the first half of
that pipeline and writes diagnostics that the native ComponentDataStream
analyzer can turn into proof samples and a viewer-ready track:

- Parses the Valorant wrapper and Unreal local replay chunks.
- Extracts header metadata, map path, branch, events, and player loadout agents.
- Oodle-decompresses all replay data chunks.
- Splits decompressed replay data into timestamped frame envelopes.
- Splits frame envelopes into packet blobs and writes diagnostics.
- Parses compact actor channel bunches and confirms normal actor-open transform
  decoding. In the current sample the replay controller opens at `8ms` with
  location `{ x: 2382.2, y: -10417.9, z: 400 }` and yaw `142.0587`.
- Applies the branch-aware Valorant seeded property payload transform before
  attempting RepLayout and ClassNetCache/RPC parsing. Raw packet scanning is
  bounded and still off by default for normal extraction, but focused raw
  channel-1 scans now prove the real BaseReplayController target RPC
  boundaries.
- Captures transformed target-RPC payloads that
  `tools/valorant_replay_probe/analyze_component_data_stream_native.mjs` parses
  as `RemoteCharacterUpdates -> ComponentDataStream`, producing
  `{timeMs, netGuid, position, viewRotation}` proof rows and a replay-track JSON
  artifact.

`tools/valorant_replay_probe/parse_usmap.mjs` reads uncompressed, Brotli, and
Zstandard `.usmap` mappings. `tools/valorant_replay_probe/analyze_component_stream.mjs`
combines parsed mapping evidence, diagnostics assemblies, confirmed actor-open
transforms, and Ascent map bounds into
`tmp/ff96dfb2.component_stream_report.json`.
`tools/valorant_replay_probe/analyze_native_records.mjs` analyzes older
pre-12.11-transform target-RPC record samples and remains useful as a
regression guardrail, but the current movement extractor is
`analyze_component_data_stream_native.mjs`.

## Candidate entity review pass

`tools/valorant_replay_probe/extract_track.mjs` now also emits an
entity-review track when plausible vector lanes are found. The generated local
artifact is:

```powershell
node tools\valorant_replay_probe\extract_track.mjs "C:\Users\shawn\AppData\Local\VALORANT\Saved\Demos\ff96dfb2-e766-40db-affb-a3af36a07b83.vrf" --out ".\tmp\ff96dfb2.entity_candidates.track.json" --diagnostics ".\tmp\ff96dfb2.entity_candidates.diagnostics.json"
```

Current sample result:

- 3 confirmed actor-open transform anchors decoded by normal Unreal actor
  bunch parsing:
  - replay controller NetGUID `2` at `8ms`, `{ x: 2382.2, y: -10417.9, z: 400 }`.
  - Jett ability actor NetGUID `702` at `640891ms`,
    `Default__Ability_Wushu_Q_CycloneBoost_C`,
    `{ x: 1382.2, y: -10417.9, z: 400.3 }`.
  - pistol actor NetGUID `1774` at `1417027ms`, `Default__BasePistol_C`,
    `{ x: -145, y: 1069.8, z: 439.5 }`.
- 120 candidate lanes grouped as `candidate-guid-entity` when a handle-2
  field decodes near a packed-vector field, otherwise by stable stream
  signature.
- The local run takes about 37 seconds, so offline preprocessing remains the
  right architecture.

Validation against Henrik sparse `player_locations` is still weak. The best
candidate lane found one sample near replay time `1726541ms` at
`{ x: 3953, y: -3056 }`, about `1062` game units from Generic Garrett's Sova
snapshot after the `-10016ms` Henrik offset. Most other candidate lanes remain
several thousand units from the nearest labeled player snapshot. This strongly
suggests many current vector hits are local component values, ability/object
state, or false-positive packed-vector interpretations, not a simple alternate
coordinate basis for player positions.

The validation is now reproducible:

```powershell
npm --prefix tools\valorant_replay_probe run compare-track-to-henrik -- ".\tmp\ff96dfb2.entity_candidates.track.json" ".\tmp\ff96dfb2.henrik_snapshots.track.json" --window-ms 1500 --out ".\tmp\ff96dfb2.entity_candidates_vs_henrik.json"
```

The Icarus viewer still supports this historical candidate workflow directly:
load `tmp/ff96dfb2.entity_candidates.track.json`, use the one-minute graph and
map trails to classify lanes, and toggle visibility down to any suspicious
entity. Confirmed player movement now comes from the native
`ComponentDataStream` decoder; the remaining identity work is the
`actor NetGUID -> PlayerState -> SubjectUniqueId` join.

The decompressed sample has a stable post-schema frame pattern beginning around
`0.525s`: an 8-byte zero prefix, a little-endian float timestamp, packet metadata,
one large network packet blob, then small external packet blobs. The repeated
small external blobs are not enough to confidently identify positions; the large
network packet blob is still the likely carrier for the replay-controller RPC.
