# Replay ad64888d Ascent Thread Plan

This is the coordination note for the latest local Ascent replay investigation.
The goal is a comprehensive, evidence-strict ability lifecycle pass that uses
`docs/replay_ability_behavior_atlas.md` as a search hint, not as proof.

## Target

- Replay: `C:\Users\shawn\AppData\Local\VALORANT\Saved\Demos\ad64888d-b10c-402a-aca2-87cf33b0f9fb.vrf`
- Map: `/Game/Maps/Ascent/Ascent`
- Branch: `++Ares-Core+release-13.00`
- Network version: `19`
- Header loadout agents: Jett, Reyna, Killjoy, Omen, Neon, Omen, Chamber,
  Yoru, Killjoy, Sova

## Fresh Baseline Artifacts

- `tools\valorant_replay_probe\tmp\ad64888d_ascent_full_capture.diagnostics.json`
- `tools\valorant_replay_probe\tmp\ad64888d_ascent_full_capture.track.json`
- `tools\valorant_replay_probe\tmp\ad64888d_ascent_full_capture.native_report.json`
- `tools\valorant_replay_probe\tmp\ad64888d_ascent_full_capture.native.track.json`
- `tools\valorant_replay_probe\tmp\ad64888d_ascent_full_capture.native_samples.json`
- `tools\valorant_replay_probe\tmp\ad64888d_ascent_unknown_controller_fields.native_report.json`
- `tools\valorant_replay_probe\tmp\ad64888d_ascent_unknown_controller_fields.native.track.json`
- `tools\valorant_replay_probe\tmp\ad64888d_ascent_unknown_controller_fields.native_samples.json`
- `tools\valorant_replay_probe\tmp\ad64888d_ascent_comprehensive_ability_audit.report.md`
- `tools\valorant_replay_probe\tmp\ad64888d_ascent_comprehensive_ability_audit.report.json`

Current extraction status:

- The stale zero-field baseline came from full capture running compact-only
  because `extract_track.mjs` defaulted `rawPacketLimit=0`.
- Full-capture default is now raw-enabled with `rawPacketLimit=1000000`.
- `rawPacketsScanned = 592034`
- `rawPacketScanSkipped = false`
- `rawPacketScanLimitReached = false`
- `abilityCasts[] = 265`
- `abilityCastSignalSummary.count = 1023`
- `abilitySignalSummary.count = 50000` with `abilitySignalSampleLimit=50000`
- Compact ability signal count remains `4471` as a fallback/source hint, not
  the whole evidence surface.
- `inputEventCaptureSummary.count = 47218`
- Native movement is restored over the regenerated diagnostics:
  `targetPayloads = 36506`, `strictRpc = 36542`, `componentOk = 342317`,
  `samples = 342882`
- Emitted movement samples in the native track/report summary: `337935`
- `utilityActors[]` has one non-ignored row: Reyna Devour at `1622453ms`
- `phase: cast-identity`, `effect-only`, generated children, and pickup/drop
  rows are not map-visible utility; only spatial phases should render.
- The comprehensive audit now marks casts, input capture, and native movement
  as restored info rows; `utility-actor-partial-spatial-evidence` remains the
  major caution.

## Work Threads

| Scope | Agents/lanes | What to prove or fix |
| --- | --- | --- |
| Ability/input evidence recovery | All agents | Restore cast, ability signal, and input capture lanes for release-13.00 Ascent or produce an exact blocker/next probe. |
| Native movement recovery | All players and moving utility | Restore player movement and ComponentDataStream movement evidence for this replay or isolate the capture/framing failure. |
| Sentinel lifecycle | Killjoy x2, Chamber | Prove persistent setup lifecycles for Nanoswarm, Alarmbot, Turret, Lockdown, Trademark, Rendezvous, and conditional slow fields without fixed-timer guesses. |
| Sova/Yoru lifecycle | Sova, Yoru | Prove projectile, landed-object, possessed movement, tether, echo, teleport, and beam/state phases. |
| Jett/Neon velocity alignment | Jett, Neon | Separate player-motion abilities from projectile/wall abilities and harden utility velocity expectations. |
| Omen/Reyna state and placement | Omen x2, Reyna | Separate map-placement smokes, teleport/player state, Leer eye, and state-only Reyna abilities; classify the existing Devour row correctly. |
| Product/report integration | All agents in this game | Produce a comprehensive per-agent audit artifact and patch analyzer/app contracts only where replay proof exists. |

## Proof Rules

- `abilityCasts[]` remains the canonical cast/navigation lane.
- `utilityActors[]` remains spatial phase evidence.
- Restored `abilitySignalSamples` are component/effect breadcrumbs, not cast
  proof by themselves.
- Restored `abilityCasts[]`, input capture, and native movement are evidence
  lanes, not lifecycle conclusions by themselves.
- Individual ability lifecycles require joins between `abilityCasts[]`,
  `inputEventCaptureSamples`, spatial `utilityActors[]`, same-NetGUID movement,
  deaths, closes, and round-state endpoints.
- Wiki behavior is a hint for search, not a replay fact.
- Persistent setup objects must not be removed using active-effect duration.
- Actor-open velocity may describe travel, but it is not a landing or lifetime
  proof.
- Controlled/autonomous movement needs `samples[]` or another proven movement
  lane.
- Duplicate agents, especially Killjoy and Omen here, must preserve player
  identity and must not be collapsed by class path alone.
