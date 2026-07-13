# Replay Track JSON

Icarus replay viewing consumes a small app-facing JSON track. This is the seam
between the `.vrf` reverse-engineering work and the Flutter UI.

Native tracks emitted by the release-13.00 decoder use
`abilitySchemaVersion: 3`. Schema v3 is additive: every schema-v2 lane and
field remains lossless, and schema-v2 fixtures continue to parse. The
canonical gameplay seam is still
`abilityActions[]`: each action has a stable `canonicalAbilityId`, replay or
static identity provenance, owner provenance, and an ordered list of phases.
Every phase says whether it is `observed`, `derived`, or `absent`; the native
emitter never writes a fallback timer into this lane.

```json
{
  "abilitySchemaVersion": 3,
  "decoder": {
    "abilityCapabilities": {
      "characterAbilityCastInfo": true,
      "actorChannelOpenClose": true,
      "typedInputCapture": true,
      "inputAbilitySlot": true,
      "inputEquippableIdentity": true,
      "equippableStateTransitions": true,
      "abilityLifecycleRpcEvents": true,
      "directActorOwner": false,
      "semanticTerminationCause": false,
      "canonicalAbilityActions": true
    }
  },
  "abilityActions": [
    {
      "id": "action-cast-0",
      "canonicalAbilityId": "valorant.gekko.ability2",
      "agent": "Gekko",
      "abilitySlot": "Ability2",
      "sourceCastId": "cast-0",
      "terminationStatus": "derived",
      "phases": [
        { "type": "cast", "timeMs": 1000, "evidence": "observed" },
        { "type": "reclaimable-object", "timeMs": 1050, "evidence": "observed" },
        { "type": "round-teardown", "timeMs": 5000, "evidence": "derived", "terminal": true }
      ]
    }
  ]
}
```

## Ability schema v3

Schema v3 adds classified lifecycle outcomes and multi-actor phase chains. It
does not replace raw actor timing or promote a named RPC by itself. The static
rules are stored in
`tools/valorant_replay_probe/static_decoder_indexes/close_signature_rules.json`.
Each rule records its stable ID, maximum evidence tier, support counts, and the
corpus or human-label provenance that established it. The corpus classifier
and native track emitter load the same file through
`tools/valorant_replay_probe/lib/close_signature_classifier.mjs`.

Each `utilityActors[]` row may add:

- `outcome`: `{type, confidence, evidence, ruleId, signatureIds[]}`, where
  `type` is `recalled`, `destroyed`, `picked-up`, `expired`,
  `phase-transition`, `round-ended`, `owner-death`, or `unknown`.
- `chainGroupId`, `chainStageIndex`, `predecessorActorId`, and
  `successorActorId` for a verified class-to-class handoff.
- `triggerTimeMs`, `rawCloseMs`, and `closeLagMs` to separate the true
  gameplay marker from the later actor-channel close.

Fields are nullable when no rule applies. Filtered implementation children
retain `ignoredAsAbility: true`; a classified diagnostic outcome is not a
reason to promote such a child into map playback.

Each `abilityActions[]` row may add the same `outcome` object and a
`lifecycleChain[]`. Chain links have `{utilityActorId, className, phaseType,
startMs, endMs, handoffGapMs}`. A chain handoff or lag-corrected trigger also
appears in `phases[]` with its rule evidence. Intermediate handoffs are not
terminal. The final classified outcome phase is terminal.

Outcome evidence is deliberately narrower than signal evidence. `observed`
is permitted only for signatures backed by the human-verified cases merged
into `verified_ability_lifecycle_registry.json`. Fixed timers, statistical
extensions, owner-death joins, and other rule-derived interpretations are
`derived`. An RPC name remains only an observed serialized RPC unless one of
those verified registry rules explicitly authorizes the stronger gameplay
claim.

`rawCloseMs` preserves the replay channel close. `triggerTimeMs` is the
gameplay moment selected by the rule, and `closeLagMs = rawCloseMs -
triggerTimeMs`. For example, a Nanoswarm detonation RPC precedes the projectile
close by about 1.803 seconds, while a Deadlock fissure actor opens at the true
trigger and closes after its approximately 5.504-second linger. Consumers
should use `triggerTimeMs` for the classified phase marker and must not rewrite
the raw lifecycle fields.

`abilityCasts[]` and `utilityActors[]` remain the lossless source-event lanes
used by map playback. The longer example below also documents fields accepted
from schema-v1/legacy fixtures; fallback fields are parsed for compatibility
but are not emitted as app-facing ends by the current native extractor.

`decoder.positionValidation.mode` is `strict-map-bounds` for importable tracks.
An explicitly requested off-map research decode is labeled
`disabled-diagnostic-only`; the native import quality gate rejects it.

`abilityStateEvents[]` is the replay-native equippable state lane. A replicated
`CurrentState` payload contains a state-object NetGUID; resolving that GUID
through the replay export map yields semantic names such as
`MapTargetingState`, `RespondToEventState_Throw`, `State_Dashing`,
`CorpseTargetingStateComponent`, and `InactiveState`. Non-initial transitions
are grouped into canonical state episodes, and an observed return to
`InactiveState` is their terminal phase. Ownership is attached only when the
same equippable NetGUID was observed in an exact player input event.

`abilityRpcEvents[]` preserves named class-net RPC observations on exact
static-identified ability actors. Projectile stop, continuous-effect
start/update/stop, one-shot effect, state-machine reset, and item movement to
persistent data retain their actor NetGUID, canonical ability ID, payload bit
count, and a bounded payload prefix. An exact utility-actor NetGUID join also
adds the RPC as an observed action phase. RPC names are not promoted into
stronger gameplay claims; stopping a visual effect does not prove that a device
was destroyed.

```json
{
  "sourceLabel": "Example replay",
  "coordinateSpace": "game",
  "mapId": "/Game/Maps/Ascent/Ascent",
  "abilityCasts": [
    {
      "id": "cast-0",
      "timeMs": 45359,
      "replicationTimeMs": 45359,
      "playerNetGuid": 1508,
      "playerSubject": "d31c53a8-ebe6-5baf-a393-1ce09fb97ba0",
      "agent": "Iso",
      "icarusAgentType": "iso",
      "abilitySlot": "Ability2",
      "abilityIndex": 2,
      "abilityName": "Double Tap",
      "slotEnum": "EAresItemSlot",
      "slotEnumValue": 5,
      "castTimeSeconds": 0.307,
      "castLocation": null,
      "effectLocations": [],
      "placementLocations": [],
      "destroyedCount": null,
      "displayLifetimeMs": null,
      "endTimeMs": null,
      "effects": [],
      "linkedUtilityActorIds": [],
      "confidence": "partial-native-ability-castinfo-player-slot-time",
      "evidenceRoles": [
        "rep-layout",
        "AbilityCastsThisRound",
        "CharacterAbilityCastInfo-partial"
      ]
    }
  ],
  "utilityActors": [
    {
      "id": "actor-1234",
      "timeMs": 640891,
      "closedAtMs": null,
      "lifetimeMs": 15000,
      "observedStartMs": 640891,
      "observedEndMs": null,
      "fallbackLifetimeMs": 15000,
      "fallbackEndMs": 655891,
      "effectiveEndMs": 655891,
      "lifecycleEvidence": "fallback",
      "endReason": null,
      "endReasonEvidence": null,
      "closeReason": null,
      "dormant": null,
      "actorNetGuid": 1234,
      "chIndex": 77,
      "archetypePath": "Default__GameObject_Iris_E_Smoke_C",
      "className": "GameObject_Iris_E_Smoke",
      "agent": "Miks",
      "icarusAgentType": "miks",
      "abilitySlot": "Ability2",
      "abilityIndex": 2,
      "abilityName": "Harmonize",
      "utilityKind": "smoke",
      "contentKind": "game-object-class",
      "phase": "placed-object",
      "sourceAbilityClass": "/Game/Characters/Iris/S0/Ability_E/Ability_Iris_E_MT_Smoke_Production",
      "sourceAbilitySlot": "Ability2",
      "sourceAbilityName": "Harmonize",
      "sourceCastId": null,
      "phaseGroupId": "/Game/Characters/Iris/S0/Ability_E/Ability_Iris_E_MT_Smoke_Production:640891",
      "evidenceRoles": ["actor-channel-open", "static-catalog"],
      "confidence": "agent-token+slot-key+kind-keyword",
      "position": { "x": 1382.2, "y": -10417.9, "z": 400.3 },
      "samples": [
        {
          "timeMs": 641000,
          "position": { "x": 1387.2, "y": -10400.1, "z": 400.3 },
          "yawDegrees": 48.5
        }
      ],
      "rotation": { "pitchDegrees": 0, "yawDegrees": 0, "rollDegrees": 0 }
    }
  ],
  "deathEvents": [
    {
      "id": "death-17",
      "timeMs": 68083,
      "endMs": 68083,
      "killerNetGuid": 874,
      "victimNetGuid": 682,
      "payloadVersion": 8,
      "eventGroupLabel": "EReplayEventGroup::CharacterDeath",
      "eventSeconds": 68.083397,
      "source": "vrf-timeline-characterDeath-payload",
      "confidence": "proven-event-payload"
    }
  ],
  "roundStartEvents": [
    {
      "id": "round-0",
      "timeMs": 63,
      "endMs": 63,
      "roundIndex": 0,
      "source": "vrf-timeline-roundStarted",
      "confidence": "event-chunk"
    }
  ],
  "players": [
    {
      "id": "player-1",
      "displayName": "A-Jett",
      "agent": "Jett",
      "teamColor": "#3A7E5D",
      "kind": "player",
      "sourceTag": "decoder-name",
      "confidence": "confirmed",
      "samples": [
        {
          "timeMs": 0,
          "x": 60,
          "y": 50,
          "z": 190,
          "yawDegrees": -70,
          "pitchDegrees": 0
        }
      ],
      "stateSamples": [
        {
          "timeMs": 63,
          "roundIndex": 0,
          "state": "alive",
          "source": "vrf-timeline-roundStarted-reset",
          "confidence": "inferred-round-reset"
        },
        {
          "timeMs": 68083,
          "roundIndex": 0,
          "state": "dead",
          "killerNetGuid": 874,
          "victimNetGuid": 682,
          "deathEventId": "death-17",
          "source": "vrf-timeline-characterDeath-payload",
          "confidence": "proven-event-payload"
        }
      ],
      "lifeSegments": [
        {
          "startMs": 63,
          "endMs": 68083,
          "roundIndex": 0,
          "state": "alive",
          "source": "vrf-timeline-roundStarted+characterDeath",
          "confidence": "round-reset-inferred-death-proven"
        },
        {
          "startMs": 68083,
          "endMs": 91446,
          "roundIndex": 0,
          "state": "dead",
          "deathEventId": "death-17",
          "killerNetGuid": 874,
          "source": "vrf-timeline-characterDeath+next-roundStarted",
          "confidence": "death-proven-round-reset-inferred"
        }
      ],
      "deathEvents": [
        {
          "id": "death-17",
          "timeMs": 68083,
          "killerNetGuid": 874,
          "victimNetGuid": 682,
          "source": "vrf-timeline-characterDeath-payload",
          "confidence": "proven-event-payload",
          "roundIndex": 0
        }
      ],
      "respawnEvents": [
        {
          "id": "respawn-682-0",
          "timeMs": 63,
          "roundIndex": 0,
          "state": "alive",
          "source": "vrf-timeline-roundStarted-reset",
          "confidence": "inferred-round-reset"
        }
      ]
    }
  ]
}
```

`coordinateSpace` can be:

- `game`: `x` and `y` are Valorant game-space coordinates. The viewer converts
  them using the Valorant API map transform and Icarus map rotation offsets.
- `percent`: `x` and `y` are minimap `u` and `v` percentages in `0..1`.
- `icarus`: `x` and `y` are already Icarus normalized world coordinates.

Current implementation status:

- Real app viewer: implemented.
- Real `.vrf` outer parsing and Oodle decompression probe: implemented in
  `tools/valorant_replay_probe/probe.mjs`.
- Offline `.vrf` preprocessing scaffold: implemented in
  `tools/valorant_replay_probe/extract_track.mjs`. It parses metadata,
  decompresses replay data, isolates timestamped frame packet blobs, keeps raw
  channel state warm, applies the branch-aware Valorant seeded payload
  transform, and captures the BaseReplayController target RPC.
- Real `.vrf` positional output: confirmed across the current
  `++Ares-Core+release-13.00` corpus. The native
  `RemoteCharacterUpdates -> ComponentDataStream` verifier decodes
  `{timeMs, netGuid, position, viewRotation}` proof samples and can emit the
  app-facing replay track JSON.
- Real `.vrf` utility actor diagnostics: implemented as a top-level
  `utilityActors[]` export. These are actor channel-open transforms, not
  canonical cast/use rows. `agent`, `abilitySlot`, and `abilityName` must come
  from an exact or unambiguous exported-content identity. Hand-maintained class
  overrides and E/Q/C/X leaf tokens remain diagnostic hints and cannot promote
  a row into the app-facing lane. `position`, `actorNetGuid`,
  `chIndex`, `timeMs`, and actor-open `velocity` are decoded replay artifacts.
  The static identity index is built from character primary assets, UIData,
  explicit spawn references, source-ability properties, unique ability
  directories, and specific inheritance. Ambiguous aliases fail closed.
  `contentKind` and `phase` separate static content scope from the display
  semantic, so `Projectile_*`, `GameObject_*`, `Patch_*`, `Pawn_*`/`AIPawn_*`,
  generated children, and pickup/drop projectiles no longer all masquerade as
  ability casts. `sourceAbilityClass`, `sourceAbilitySlot`, static agent ids,
  `sourceAbilityName`, and `phaseGroupId` are catalog/spawn-graph joins from
  the local FModel 12.11 indexes when a match exists.
  `closedAtMs` is populated when a matching channel-close bunch is observed.
  The native emitter does not assign wiki, ability-kind, or generic display
  durations. Unknown ends remain hidden/open; known round boundaries and
  recording censorship are retained as explicitly derived ends.
  `observedLifetimeMs` and `durationSource` preserve provenance. Full in-flight
  projectile paths are not exported yet; projectile actors currently expose
  their spawn transform, initial velocity, and close time, while landed effects
  often appear as separate `GameObject_*`/`Patch_*` utility actors.
- Real `.vrf` ability cast diagnostics: implemented as a top-level
  `abilityCasts[]` export for the first decoded pieces of
  `Comp_AbilityStatisticsReplicator.AbilityCastsThisRound`. The extractor keeps
  `AbilityCastsThisRound` in a dedicated `frameSummary.abilityCastSignalSamples`
  lane so the mixed `abilitySignalSamples` cap cannot hide later casts. The
  current native
  decoder proves `CharacterAbilityCastInfo.Player` as a UUID-like string,
  `Slot` as a raw `EAresItemSlot` byte mapped conservatively to
  `3=Grenade`, `4=Ability1`, `5=Ability2`, and `9=Ultimate`
  (`6=Passive` is not promoted as an ability use), the matching Icarus-local
  `abilityIndex` (`0..3`) and catalog-backed `abilityName`, replay round,
  `EAresGamePhase`, and `CastTime`,
  `CastLocation` as a 192-bit double vector field, `EffectLocations` as a
  one-or-more element double-vector array when the array headers match, and
  `DestroyedCount` as a 32-bit integer field. The nested
  `CharacterAbilityEffectInfo[]` is decoded into statistic enum/name, localized
  key/table, value, time, and affected-player NetGUID/value rows. Rows
  with the location/count decode use
  `confidence: "partial-native-ability-castinfo-player-slot-time-location-effectlocations-destroyedcount"`
  to keep this boundary visible. `castLocation` and `effectLocations[]` are not
  rendered as ability placement by default; for many abilities they describe the
  caster/throw origin or another cast-info vector, not the final smoke, dart,
  nade, or bot position. `placementLocations[]` is emitted only when the
  decoder has mechanically proven map placement for the visual effect. The
  current proven placement lane is
  `MapTargetingStateComponent.MulticastRespondToValidSingleMapClick`: its first
  RPC parameter is a 192-bit double vector, and the native analyzer correlates
  that click to the nearest same-agent/same-slot cast. This lets the Flutter
  viewer render proven map-targeted placement points at the clicked map location
  rather than at the caster.
  `displayLifetimeMs` or `endTimeMs` may then be emitted when that placement has
  a better display window; otherwise the cast remains a navigation/report row
  only.
- `utilityActors[]` is intentionally a raw evidence feed. The Flutter replay
  cast controls now read `ReplayTrack.abilityCasts`; utility actors stay on the
  map only when they are visible spatial phases. Initial replication actor opens,
  `Ability_*` cast identity rows, effect-only rows, generated children, and
  known noise such as `EquippablePickupProjectile` remain in diagnostics but are
  not counted as visible ability uses. Spatial phases are `placed-object`,
  `area-patch`, `projectile-flight`, `submunition`, and `deployable-pawn`, or
  class names shaped like `GameObject_*`, `Projectile_*`, `Patch_*`, `Pawn_*`,
  or `AIPawn_*` when phase metadata is missing. `ignoredAsAbility: true`,
  `contentKind: "pickup-drop"`, and `phase: "pickup-drop"` mark pickup/drop
  records that should not be promoted into the ability UI. Moving actors can
  provide `samples[]`; the viewer uses `ReplayUtilityActor.positionAt(timeMs)`
  to interpolate those positions over replay time. Non-player
  ComponentDataStream tracks based on nearest-cast/time/distance joins are now
  emitted only as `candidateUtilityActors[]`; they cannot become app-facing
  `utilityActors[]` until a replay-native actor identity join is decoded.
  Lifecycle timing never collapses observation and prediction into one fact:
  `observedStartMs`/`observedEndMs` preserve actor-channel evidence,
  `fallbackLifetimeMs`/`fallbackEndMs` preserve an approved estimate, and
  `effectiveEndMs` selects observed evidence first. `lifecycleEvidence`
  identifies the selected tier as `observed`, `derived`, `fallback`, or
  `absent`. Close metadata is preserved in `closeReason` and `dormant`;
  `endReason` and `endReasonEvidence` distinguish the raw close from derived
  interpretations such as `round-teardown` or `recording-censored`. Verified
  `observed-actor` registry rules never receive a generic duration fallback.
- Ability/input evidence is preserved in diagnostics as
  `frameSummary.abilitySignalSamples` and
  `frameSummary.inputEventCaptureSamples`. A separate deduplicated
  `nonMovementInputEventSamples` lane decodes replay player ID, nested bit
  count, `EInputEventType`, raw serialized event bytes, and processing result.
  The native track emits these as typed `inputEvents[]` and validates the
  `0x100 + header loadout index` player join. `EquippableChange` also carries
  an Unreal-packed equippable NetGUID. An exact join to a replay-opened,
  static-identified ability equippable for the same player/agent emits the
  canonical ability ID and an observed `equip-selected` action phase. Other
  input kinds remain unassigned until their payload is proven; no proximity
  join is used.
- `utilityActors[].abilitySlot` is the safer UI/API handoff field. The
  exported `abilityIndex` follows Icarus' existing local ability-list order
  `C/Grenade=0`, `Q/Ability1=1`, `E/Ability2=2`, `X/Ultimate=3`; external
  API ability arrays may use a different order while still exposing the same
  slot strings.
- Real `.vrf` death/life diagnostics: implemented as top-level
  `deathEvents[]` and per-player `stateSamples[]`/`lifeSegments[]` in the
  native ComponentDataStream track emitter. Death states are decoded from
  `characterDeath` timeline event payloads containing killer/victim player
  actor NetGUIDs and the label `EReplayEventGroup::CharacterDeath`; these are
  proven replay artifacts. Alive/respawn samples are inferred from
  `roundStarted` timeline events and should be treated as round reset state,
  not as a decoded health or PlayerState alive bit.
- Confirmed `.vrf` transforms: actor channel-open transforms are decoded with
  normal Unreal quantized vector/rotation parsing. In the current sample this
  confirms the replay controller spawn transform at `8ms` and the ten player
  actor NetGUID/channel-open spawn transforms used to label native movement
  lanes.
- Demo fixture: `assets/replays/ascent_demo_track.json`, generated by
  `node tools/valorant_replay_probe/emit_demo_track.mjs`.

The current native decoder path parses
`/Script/ShooterGame.ReplayPlayerController:ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous`
and emits this JSON shape.

Current decoder baseline, regenerated after porting the release-12.11 seeded
payload transform:

```powershell
node tools\valorant_replay_probe\extract_native_track.mjs "C:\Users\shawn\AppData\Local\VALORANT\Saved\Demos\ad64888d-b10c-402a-aca2-87cf33b0f9fb.vrf" --out ".\tmp\ad64888d_ascent_current.native_component.track.json" --diagnostics ".\tmp\ad64888d_ascent_current.diagnostics.json" --report-out ".\tmp\ad64888d_ascent_current.native_report.json"
```

For ability lifecycle debugging, keep the generic ability/component capture
large enough to span the full round. Short diagnostics can cut off later
component-only events such as recalls. Use the native extractor default capture
or override the high-capture limits explicitly:

```powershell
node tools\valorant_replay_probe\extract_track.mjs "C:\Users\shawn\AppData\Local\VALORANT\Saved\Demos\ad64888d-b10c-402a-aca2-87cf33b0f9fb.vrf" --out ".\tmp\ad64888d_ascent_high_capture.track.json" --diagnostics ".\tmp\ad64888d_ascent_high_capture.diagnostics.json" --raw-packet-limit 1000000 --raw-time-from-ms 0 --raw-time-to-ms 2100000 --ability-signal-sample-limit 500000 --ability-cast-signal-sample-limit 50000 --non-movement-input-event-sample-limit 100000 --diagnostics-only --skip-compact-diagnostics
```

The native wrapper uses a 500,000-row generic ability/property limit and emits
the retained count, limit, and overflow count as
`decoder.abilitySignalCapture`. Import validation and the corpus audit fail if
this lane overflows; an absence conclusion is not allowed from truncated
evidence.

The current app-imported Ascent track lives under
`%TEMP%\icarus_replay_imports\ad64888d-b10c-402a-aca2-87cf33b0f9fb-*` and is
the live UI evidence to prefer over stale checked-in `tmp` artifacts. A recent
validation reported `targetPayloads=36506`, `strictRpc=36542`,
`componentOk=342317`, `samples=342882`, and `337935` app-track samples after
the 50ms export cadence. The emitted viewer track has 10 players, and the side
join uses exact `AbilityCastsThisRound` `playerSubject -> playerNetGuid`
evidence before falling back to header loadout order. In this replay, that
proves `Yoru g1440` and `Killjoy g952` are attacker/enemy, while
`Omen g1344` is defender/ally. Older h24/h100/handle-122 review artifacts below
were produced before the release-12.11 transform was ported; treat them as
historical anatomy leads, not current replay-track outputs.

For reverse-engineering, `players[]` can also represent candidate entities
rather than confirmed players. Candidate tracks should set:

- `kind`: for example `confirmed-actor-open-transform`,
  `candidate-guid-entity`, or `candidate-stream-entity`.
- `sourceTag`: the replay stream/channel/framing source.
- `confidence`: a short classification such as
  `confirmed-unreal-actor-open`, `guid-adjacent`, or `stream-signature`.

The Flutter viewer labels these as entities, shows the metadata in the side
panel, and renders a one-minute timeline graph plus optional one-minute map
trails for visual classification.

Run the current preprocessing scaffold with:

```powershell
npm --prefix tools\valorant_replay_probe install
npm --prefix tools\valorant_replay_probe run extract-track -- "C:\Users\shawn\AppData\Local\VALORANT\Saved\Demos\ff96dfb2-e766-40db-affb-a3af36a07b83.vrf" --out ".\tmp\ff96dfb2.track.json"
```

When component-vector samples are found, the command writes
`.\tmp\ff96dfb2.track.json` and exits with code `0`. It also writes
`.\tmp\ff96dfb2.track.diagnostics.json` with decoder counts and sample
provenance. If no samples are found, it writes diagnostics and exits with code
`2`.

The current extractor now emits an entity-review version by default when
candidate lanes are found. For the local sample:

```powershell
node tools\valorant_replay_probe\extract_track.mjs "C:\Users\shawn\AppData\Local\VALORANT\Saved\Demos\ff96dfb2-e766-40db-affb-a3af36a07b83.vrf" --out ".\tmp\ff96dfb2.entity_candidates.track.json" --diagnostics ".\tmp\ff96dfb2.entity_candidates.diagnostics.json"
```

Current sample output:

- 3 confirmed actor-open transform anchors:
  - replay controller at `8ms`, `{ x: 2382.2, y: -10417.9, z: 400 }`.
  - Jett ability actor
    `Default__Ability_Wushu_Q_CycloneBoost_C` at `640891ms`,
    `{ x: 1382.2, y: -10417.9, z: 400.3 }`.
  - `Default__BasePistol_C` at `1417027ms`,
    `{ x: -145, y: 1069.8, z: 439.5 }`.
- 120 candidate entity lanes grouped by GUID-adjacent fields or stable
  stream signatures.
- Offline extraction time on this machine is about 37 seconds for the sample.

This is intentionally a review artifact, not a solved player decoder. A
nearest-snapshot validation against the Henrik sparse track found one candidate
sample around `1726541ms` within about `1062` game units of a labeled Sova
snapshot, but most candidate lanes are still thousands of units away. That
means the current candidates are useful for human triage and bit-layout
debugging, but the player-position stream is not proven yet.

The focused h24 ReplayController analyzer can also emit a smaller candidate
track from `fieldHandle=24 / payloadBits=3286 / prefix=d55af0b3` GUID-adjacent
vectors:

```powershell
npm --prefix tools\valorant_replay_probe run emit-h24-candidate-track -- ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_streams.report.json" --out ".\tmp\ff96dfb2.h24_candidates.track.json"
```

This writes diagnostic tracks grouped by NetGUID plus h24 source offsets. They
are viewer-loadable candidate vectors, not confirmed continuous player tracks.
The h24 emitter preserves each track's `anchorIdentityConfidence`; in the
current report only the `778@1056/16` h24 anchor is a
`strong-intermittent-identity-lead`, while anchors such as `586@683/16` are
flagged as numeric-neighbor collision risks. The companion replay-controller
report also records why current small-lane coordinate interpretations are
rejected: the scalar-pair scan finds zero strict continuous `{x,y}` lanes in
the `0-900s` diagnostic, and the named target RPC has only collision-level
identity-like layouts.

The companion h24 transform gate is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-h24-transform-hypotheses -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --stream-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_streams.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.h24_transform_hypotheses.report.json"
```

Current output for the sample has `h24CandidateSampleCount=206`,
`h24GroupCount=17`, `persistentIdentityLikeAnchorCount=0`, `passingGroups=0`,
and status
`no h24 transform hypothesis passed the strict continuous world-track gate`.
The strongest identity anchor is too static/small-span, while the wider-span
candidate is too sparse and jumpy. The strongest known-GUID-looking anchor,
`778@1056/16`, is also burst-local rather than persistent: 62 exact hits split
across four short runs in 297 h24 payloads. Do not promote h24 candidate vectors
to confirmed player tracks until this gate passes.

The larger packed-vector transform verifier is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-large-payload-transform-hypotheses -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --stream-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_streams.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.large_payload_transform_hypotheses.report.json"
```

Current output has `specCount=181`, `identityAttributedSpecCount=2`,
`passingGroups=2`, `promotableGroups=0`, and status
`position-like large payload transforms found, but none pass NetGUID/view-yaw
promotion gate`. The two position-like passers are unlabeled lanes
(`fieldHandle=16` and `fieldHandle=35`) that can be made map-bounded under many
unrelated player-open transforms. The two NetGUID-attributed handle-24 joins are
now filtered to frames where the int-packed anchor is present, leaving only
`586@683 -> vector@1200` with 28 samples and `778@1056 -> vector@1575` with
23 samples. They are still too sparse/static/jumpy and have weak handle-122 yaw
overlap, so do not emit them as confirmed track samples.

The slot-array reinterpretation verifier is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-large-slot-array-positions -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --large-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.large_payload_transform_hypotheses.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.large_slot_array_positions.report.json"
```

It shows the two large position-like offsets align with ten fixed records:
handle `16` / `1871` bits maps offset `1755` to slot `9`, relative offset `71`,
and handle `35` / `3137` bits maps offset `468` to slot `1`, relative offset
`148`. The report now emits capped `fusedCandidateSamples` with
`{timeMs, netGuid, position, viewRotation}` when a same-slot handle-122 yaw lane
is nearby. These rows are still diagnostic only: slot identity comes from player
channel order rather than a decoded `ShooterCharacterNetGuidValue`, multiple
world-position transforms pass, and the current fused yaw match is only a small
handle-35/slot-1 subset for NetGUID `682`.

The broader slot-aware scanner is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-slot-component-stream-candidates -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.report.json"
```

Current default output scans 10 repeated large payload groups and reports
`candidateCount=7872`, `sameIdentityYawCandidateCount=969`,
`movementShapeCandidateCount=41`, and `strictMovementCandidateCount=18`. The
strict set is still diagnostic only: all strict candidates are for slot-inferred
NetGUID `682`, and they collapse to handle `35` / `3137` / `be55aa19` at
relative offset `148` plus handle `54` / `2035` / `77f4fe23` at relative offset
`137`. A wider `--min-group-samples 20 --max-groups 40` scan still finds only
those strict NetGUID `682` candidates. Do not treat `fusedCandidateSamples` from
this report as app-facing tracks until record identity and the single correct
position transform are decoded.

For candidate-track review, the same scanner can also write explicit proof
samples and a viewer-ready track:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-slot-component-stream-candidates -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --min-group-samples 20 --max-groups 40 --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.report.json" --samples-out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.samples.json" --track-out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.track.json" --sample-candidate-scope movement --sample-dedupe family --max-sample-candidates 12
```

Current local output writes `10` deduped candidate tracks and `963` viewer
samples. The proof file keeps the decoder-facing shape
`{timeMs, netGuid, position, viewRotation, source, confidence}` and leaves
`viewRotation.yawDegrees` as `null` unless a same-slot handle-122 yaw sample is
nearby; `103/963` proof rows currently have decoded yaw. The viewer track uses
movement-direction yaw as a numeric fallback because `ReplaySample.yawDegrees`
is required by the Flutter model. Treat this as a review artifact, not the final
native replay-track decoder.

The same report now separates 2D movement/yaw candidates from full-3D
plausibility. The strict NetGUID `682` slot-1 families are still valuable
identity/yaw structure leads, but their third component currently fails xyz
continuity checks with impossible short-dt z/3D speeds. Some slot `6` /
NetGUID `1190` families look more plausible in 3D, but their handle-122 yaw
identity remains ambiguous.

For the most useful current 3D proof artifact, select only candidates that pass
both the full xyz gate and the movement-shape gate:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-slot-component-stream-candidates -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --min-group-samples 20 --max-groups 40 --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.report.json" --samples-out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.position3d_movement.samples.json" --track-out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.position3d_movement.track.json" --sample-candidate-scope position3d-movement --sample-dedupe family --max-sample-candidates 12
```

Current local output selects `3` slot `6` / NetGUID `1190` families, writes
`247` proof rows, and has `26` rows with decoded handle-122 yaw. The matching
viewer track has `3` unique candidate ids and `247` samples. A broader
`--sample-candidate-scope position3d` artifact selects `12` families, `2703`
proof rows, and `452` decoded-yaw rows, but includes shape-only candidates that
are for record review rather than movement promotion.

To inspect identity clues around the full-3D candidates:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-slot-candidate-neighborhoods -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --slot-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.report.json" --candidate-scope position3d --max-families 40 --identity-window-bits 180 --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_candidate_neighborhoods.position3d.report.json"
```

The strongest current 3D-movement leads are handle `24` / `3286` /
`d55af0b3` at slot-relative offset `93`, and handle `100` / `1950` at relative
offset `24` for prefixes `d85fa616` and `f85fa616`. Their target slot has
same-slot `chIndex=84` clues, but attribution still relies on slot/channel
order rather than a native `ShooterCharacterNetGuidValue` decode.

The matching decoder-lead report is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-slot-component-decoder-leads -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --samples ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_stream_candidates.min20.position3d_movement.samples.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json"
```

Current output confirms that the selected h24 vector appears in slot `6`
`131/297` times with a same-slot `intPacked chIndex=84` clue at relative bit
`7`, while the two h100 prefixes decode the selected slot-6 vector in `58/58`
rows each and are paired about `8ms` apart. This proves a useful slot-local
record surface, but the vectors are still small local/component values rather
than confirmed Valorant world positions.

The selected-slot world-position guardrail is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-selected-slot-world-position-leads -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --decoder-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.selected_slot_world_position_leads.report.json"
```

Current output has `worldPositionLeadCount=0` and
`replayTrackPromotableCount=0`. The selected vectors are the best rejected
rows: they are map-bounded after slot-open transforms, but their xy spans are
only about `204..274` units over long replay time. Keep them out of app-facing
player tracks until a native world-position transform or another carrier is
decoded.

The follow-up integration sweep is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-selected-slot-integration-hypotheses -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --decoder-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json" --yaw-samples ".\tmp\ff96dfb2.handle122_yaw.samples.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.selected_slot_integration_hypotheses.report.json"
```

Current output has strict full-xyz integration-shaped leads
(`strictFullPositionPassCount=127`), with the strongest h24/h100 variants
looking like open-yaw velocity integrations from the slot-open location.
However, same-NetGUID handle-122 yaw coverage for the strongest leads is only
about `0.198..0.224` within `64ms`, and the yaw identity itself remains
ambiguous. These are useful decoder leads for `ComponentDataStream`
velocity/delta semantics, but still must not be promoted to replay-track
samples.

The current h100 slot-6 integration proof emitter is:

```powershell
npm --prefix tools\valorant_replay_probe run emit-selected-slot-integration-candidate-track -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --decoder-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json" --integration-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.selected_slot_integration_hypotheses.report.json" --handle122-prefix 69cf8efb --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.selected_slot_h100_integration_candidate.track.json" --samples-out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.selected_slot_h100_integration_candidate.samples.json"
```

Current local output writes `3` viewer-loadable review tracks and `232`
decoder-proof samples. The merged h100 track has `116` samples, `xySpan=1026.08`,
p90 3D speed `1005.1`, p90 z step `14.79`, and `25/116` decoded handle-122 yaw
overlays from prefix `69cf8efb`. It remains diagnostic only; the viewer yaw
falls back to movement direction when decoded yaw is absent.

The broad h100 slot/offset integration guardrail is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-h100-slot-integration-candidates -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.h100_slot_integration_candidates.min25.report.json" --min-group-samples 25 --min-vector-samples 25
```

Current v3 output finds movement-shaped h100 integrations across all slots
(`4206` strict passers, `640` source-stable strict passers) once the four short
prefix lanes are allowed through the lower sample threshold. They still are not
replay-track samples: every candidate's only handle-122 lane is far away in time
(`0` rows within `64ms`), multiple axis/scale variants pass, and identity still
comes from slot order rather than a decoded `ShooterCharacterNetGuidValue`.

The native `ComponentDataStream` verifier is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-component-data-stream-native -- --diagnostics ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.component_data_stream_native.report.json" --samples-out ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.component_data_stream_native.samples.json" --track-out ".\tmp\ff96dfb2.raw0_900.v4_12_11_transform.native_component.track.json"
```

It ports the refreshed playground `ComponentDataStream` model (`0x52` movement
magic, move markers, VLQ timestamp, quantized position, packed yaw/pitch) and
only emits samples when a decoded NetGUID and plausible position are both
present. Current release-12.11 output emits `2610` proof samples:
`targetPayloads=260`, `strictRpc=260`, `componentOk=2599`, and
`directComponentScan.hitCount=3084`. Older seeded-transform and v3 diagnostics
that emitted `0` samples were generated before the release-12.11 transform was
ported; keep them only as historical negative fixtures.

The reflected-RPC alignment guardrail is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-replay-controller-rpc-property-alignment -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.rpc_property_alignment.report.json"
```

It scans `1482` named ReplayController RPC payload samples across `6` fields.
Those ordinary named RPCs also fail normal `ReceiveProperties` parsing, so the
target function should be treated as custom/direct native RPC parameter data
rather than a reflected property stream.

The direct target-RPC layout guardrail is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-target-rpc-direct-layouts -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.target_rpc_direct_layouts.report.json"
```

Current output has `250` target samples, `6` repeated compact families, and
status `target RPC is custom/direct: compact families expose narrow exact actor
identities, but no strict absolute movement lane`. The canonical `intPacked`
array-count hypothesis does not fit (`plausibleRate <= 0.404`,
`integerRecordRate <= 0.22`, `guidBoundaryHitCount=0`). Compact families do
carry exact narrow actor identity clues:

```text
108 bits / 3f422366: uint10 netGuid=586 at bit 45 in 71/71 rows
84 bits / 5c311049: uint11..13 netGuid=1088 at bit 14 in 54/54 rows
116 bits / 01ed9ffc: uint10..11 netGuid=874 at bit 55 in 22/22 rows
116 bits / 85755749: uint10..12 netGuid=586 at bit 21 in 4/4 rows
```

These are useful `ComponentDataStream` record-shape clues. They still must not
be emitted as replay-track labels until the narrow identity encoding is proved
and the post-identity local/delta movement values are converted into strict
absolute `{position, viewRotation}` samples.

The combined RemoteCharacterUpdate identity-layout guardrail is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-remote-character-update-identity-layouts -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --decoder-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.remote_character_update_identity_layouts.report.json"
```

Current output scans the named target-RPC large slot payloads, h100 prefixes,
and the selected h24 family. It finds `0` authoritative actor-NetGUID layouts,
`0` majority exact identity-like layouts, and only `2` low-coverage exact
layouts. The best shared layout is the target RPC `1498`-bit burst at
`rel137`, `intPacked chIndex`, covering only `2/10` slots. h100 exposes isolated
single-slot actor-shaped fragments such as `uint11 netGuid=1286` at `rel5`, but
no shared `ShooterCharacterNetGuidValue` layout. Keep the h100/h24 movement
samples diagnostic until this report finds a majority identity layout or another
non-ambiguous player identity signal.

The selected-slot yaw/identity scalar guardrail is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-selected-slot-yaw-identity-leads -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --decoder-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json" --yaw-samples ".\tmp\ff96dfb2.handle122_yaw.samples.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.selected_slot_yaw_identity_leads.report.json"
```

Current output has `yawLeadCount=0` and
`replayTrackPromotableCount=0`. The best rejected scalar fields either have too
little same-NetGUID handle-122 temporal coverage (`0.091..0.224` of selected
rows) or jumpy angular motion, and scalar candidates that overlap the selected
packed vector are rejected. This rules out a simple yaw scalar inside the
selected h24/h100 target slot records for now.

The handle-122 lane identity report is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-handle122-lane-identity -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --decoder-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.slot_component_decoder_leads.position3d_movement.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.handle122_lane_identity.report.json"
```

It finds `10` recurring full-payload handle-122 prefix lanes. Their prefix
variation is only bits `20..27`, which is a likely lane key, but `6/10` lanes
still collide under first-open-yaw NetGUID matching. For the h100 slot-6
position leads, prefix `69cf8efb` is the strongest handle-122 co-occurrence lead
(`within64MsRate=0.224` / `0.207` for the two h100 prefixes), but this is still
not enough identity/yaw coverage for replay-track promotion.

The focused target-RPC framing scan is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-target-rpc-framing -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.v3.target_rpc_framing.report.json"
```

Current v3 output for the sample target RPC: `250` captured payloads,
`authoritativeActorNetGuidLayoutCount=0`,
`authoritativeActorNetGuidRecurringHitCount=0`, and status `only
channel-index-shaped/collision-level layouts found`. The recurring exact
actor-value hits are narrow custom bitfields (`uint10`/`uint12`) in compact
families rather than a shared `uint32` or `intPacked`
`ShooterCharacterNetGuidValue` layout. Use
`analyze-target-rpc-direct-layouts` for those compact-family identity clues; do
not use the broad same-offset channel-index/neighbor/low-bit layouts as player
labels for replay-track emission.

The native-record report now also includes `candidatePacked80Layout`, a focused
test of the tempting `uint5 + signed16/10 + signed16/10 + signed16/10 +
signed16` interpretation inside the target
`RemoteCharacterUpdates`/`ComponentDataStream` payloads. It currently reports
`status=no-strict-lane-candidates`: all 457 decoded x/y pairs land in Ascent
bounds, but only 134/457 z values are in `-500..900`, candidate groupings have
static fragments or impossible short-dt jumps, and yaw proximity to handle 122
is not strong enough to prove the `w` field. Do not emit these values as replay
track samples until that status changes. The same report scans shifted 80-bit
stride offsets `0..79`; all shifted offsets currently have
`strictLaneCandidateCount=0`, so a nonzero record start offset does not explain
the missing movement track by itself.

The target framing report annotates native 80-bit families with Unreal
hardcoded names. The leading family `8ef267` starts with first packed value
`71`, which is `Transform`, but the surrounding tokens still do not form a
valid property chain or authoritative player identity. Treat that as a
`ComponentDataStream` semantic clue, not as a decoded replay-track row.

The target-RPC signed-triplet guardrail is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-target-rpc-vector-layouts -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.target_rpc_vector_layouts.report.json"
```

Current output scans 457 native 80-bit records and finds
`exploratoryCandidateCount=25809`, but `strictPositionLaneCandidateCount=0` and
`promotableCandidateCount=0`. The preserved `8ef267` / `Transform` clue is
sparse, small-magnitude, and has no authoritative NetGUID in the same layout
group, so it must stay out of replay-track emission.

The replay-controller stream report also includes
`targetRpc1498SlotSummary.identityScan` for the tempting `1498 = 8 + 10 * 149`
burst. The focused target slot verifier now reports partial same-slot identity
clues in that burst: slot `0` has `intPacked chIndex=76` at relative offset
`137`, and slot `1` has `uint10 netGuid=682` at relative offset `43` plus
`intPacked chIndex=77` at relative offset `49`, each across all 10 burst
samples. It still finds no authoritative all-slot actor NetGUID layout and no
strict position candidate, so these remain record-layout clues rather than
player labels for replay-track emission.

The ReplayController timeline/lane ranking pass is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-replay-controller-timeline -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_timeline.report.json"
```

For the current `0-900s` diagnostic, the named target RPC has 250 captures with
many short bursts but 53 gaps longer than one second. The top continuous lane is
still handle `122` as view-yaw-only data; handles `24`, `46`, and `100` remain
GUID-bearing structure leads, while compact lane families such as `90`, `94`,
`107`, and `45` fail current position-continuity checks. None of these outputs
should be promoted to confirmed `{timeMs, netGuid, position, viewRotation}`
tracks until identity and world position decode together.

The stricter fixed-scalar position scan is:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-position-hypotheses -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.position_hypotheses.report.json"
```

The current report scans 111478 ReplayController candidate-field samples
against the 10 decoded actor-open player spawns and hits the 12000
spawn-matched hypothesis cap, but `passingCandidateCount=0`. Handle `122`
spawn-like slices are rejected as the known yaw lane, handle `134` decodes
spawn-like but mostly static values, and handle `45` remains a coordinate-like
fragment family rather than a coherent movement lane. This report is a guardrail
against emitting attractive scalar coincidences as player tracks.

To check whether those rejected scalar pairs are merely collapsed multi-entity
lanes, run the deinterleaving guardrail:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-deinterleaved-position-lanes -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --stream-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_streams.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.deinterleaved_position_lanes.report.json"
```

The current output has `strictCandidateCount=0`. It finds only exploratory
handle `45` modulo/id-bit partitions with tiny, segmented bursts, so those rows
are not valid replay-track samples either.

The yaw-partitioned scalar guardrail uses handle `122` as the partition key for
nearby non-yaw ReplayController lanes:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-yaw-partitioned-positions -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.yaw_partitioned_positions.report.json"
```

Current output has `yawLaneCount=10`, `analyzedPartitionCount=129`, and
`strictCandidateCount=0`. The best rows still fail map bounds or short-step
speed, so do not emit nearby small scalar lanes as player positions merely
because they co-occur with a handle-122 yaw prefix.

To check the same "collapsed multi-entity lane" idea against recurring
packed-vector fields, run:

```powershell
npm --prefix tools\valorant_replay_probe run analyze-deinterleaved-large-vectors -- --diagnostics ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --stream-report ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.replay_controller_streams.report.json" --out ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.deinterleaved_large_vectors.report.json"
```

The current output has `passingCandidateCount=0` across `62` analyzed specs,
including the two h24 identity-attributed GUID/vector joins. Those anchored h24
fragments remain useful `ComponentDataStream` record-shape evidence, but they
are too short/static to emit as `{timeMs, netGuid, position, viewRotation}`
samples.

Handle `122` can also be exported as a view-rotation-only diagnostic:

```powershell
npm --prefix tools\valorant_replay_probe run emit-handle122-yaw -- ".\tmp\ff96dfb2.raw0_900.large_candidate_fields.diagnostics.json" --out ".\tmp\ff96dfb2.handle122_yaw.samples.json"
```

That output is not a replay track because it has no decoded position. It writes
10 candidate yaw lanes / 4048 samples shaped as
`{ timeMs, netGuid, position: null, viewRotation, source }`; `netGuid` is a
best-effort open-yaw match and may be ambiguous.

Run that validation with:

```powershell
npm --prefix tools\valorant_replay_probe run compare-track-to-henrik -- ".\tmp\ff96dfb2.entity_candidates.track.json" ".\tmp\ff96dfb2.henrik_snapshots.track.json" --window-ms 1500 --out ".\tmp\ff96dfb2.entity_candidates_vs_henrik.json"
```

For reverse-engineering `ComponentDataStream`, parse the local `.usmap` mapping
and rank candidate component-stream payloads. Use the newest local VALORANT
mapping file available in Downloads; this pass used
`C:\Users\shawn\Downloads\VALORANT_12.11_zs.usmap`.

```powershell
npm --prefix tools\valorant_replay_probe run parse-usmap -- "C:\Users\shawn\Downloads\VALORANT_12.11_zs.usmap" --query=RemoteCharacter,ComponentDataStream --out ".\tmp\valorant_12_11_remote_component_schema.json"
npm --prefix tools\valorant_replay_probe run analyze-component-stream -- --diagnostics ".\tmp\ff96dfb2.track.diagnostics.json" --assemblies ".\tmp\ff96dfb2.track.diagnostics_assemblies" --usmap-schema ".\tmp\valorant_12_11_remote_component_schema.json" --out ".\tmp\ff96dfb2.component_stream_report.json"
npm --prefix tools\valorant_replay_probe run catalog-valorant-content-assets -- --track ".\tmp\ff96dfb2.current_after.native_component.track.json" --out ".\tmp\valorant_12_11_content_ability_catalog.json"
```

Henrik match payloads can also be converted into sparse, player-labeled
snapshot tracks from kill-event `player_locations`:

```powershell
npm --prefix tools\valorant_replay_probe run emit-henrik-track -- ".\tmp\ff96dfb2.henrik_v4_match.json" --time-offset-ms -10016 --out ".\tmp\ff96dfb2.henrik_snapshots.track.json"
```

For the current sample this writes 10 players and 927 labeled position/view
samples. It is not continuous replay data, but it is useful ground truth for
validating `.vrf` NetGUID and `ComponentDataStream` decoding.
