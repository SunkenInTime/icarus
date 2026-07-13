# Valorant Replay Ability Corpus Audit

Audit date: 2026-07-10

This is the source-of-truth status for the six newest downloaded Valorant
replays. It separates data observed in a replay from static identity, derived
joins, diagnostic candidates, and still-missing semantics. The generated JSON
and full 29-agent matrix are in
`tmp/ability_corpus_20260710/current/corpus_audit.json` and
`tmp/ability_corpus_20260710/current/corpus_audit.md`.

## Result

The six-track corpus audit passes with zero errors. Five tracks pass strict map
and movement validation. The Summit replay is useful for ability decoding but
is diagnostic-only until Icarus has a verified Summit transform and map asset.

Current schema-v2 imports no longer use wiki durations, ability-kind timers,
nearest-cast ownership, or inferred component movement as app-facing ability
facts. Unproven movement stays in `candidateUtilityActors`; a timing-only cast
association stays `candidateSourceCastId`; and a missing actor end remains
right-censored or explicitly derived from round teardown. It is never filled
with a display timer.

This does **not** mean every gameplay branch is decoded. No ability yet has
replay proof for every possible activation, hit, pickup, recall, destruction,
suppression, owner-death, and natural-expiry path. The decoder now preserves
substantially more native evidence and refuses to invent the rest.

## Corpus

| Replay | Internal map | Rounds | Position status |
| --- | --- | ---: | --- |
| `2dd2de86-756b-4304-8f00-cb3696c52627` | Lotus | 20 | strict |
| `c8989335-cde6-47e1-8c20-80e376ed7411` | Split | 30 | strict |
| `c8313344-0dad-4fb6-8487-070116cdc241` | Sunset | 5 | strict |
| `b63bb117-af42-4283-895a-98bb0a981bc9` | Split | 14 | strict |
| `1fb53a2c-bf7b-4276-80cf-54e1f01017ba` | Plummet / Summit | 30 | diagnostic-only |
| `dc078274-2d68-495b-8321-5e58b2a3eeba` | Sunset | 5 | strict |

All six are release-13.00 replay/network format. The generic ability-property
capture limit is 500,000 rows and the typed non-movement input limit is 100,000
rows per replay. Every track completed with zero overflow in both lanes.
Across the corpus, 3,057,219 raw packets and 846,071 ability/property signals
were scanned. The five strict tracks cover 99.82-99.98% of their replay
timelines with all ten players resolved.

## Coverage

The static catalog contains 29 agents and 116 primary network ability slots.
The six matches roster 22 agents.

| Replay-native lane | Slots | Events/rows | Meaning |
| --- | ---: | ---: | --- |
| `AbilityCastsThisRound` | 74/116 | 1,363 | Cast identity, player, round/phase clock, locations, and statistics when serialized. |
| Exact utility actor identity | 85/116 | 4,097 | Actor open, spatial phase, and close/dormancy evidence. |
| Exact equippable change | 81/116 | part of 217,250 inputs | Player-selected equippable NetGUID joined to an exact static ability identity. |
| Non-initial active `CurrentState` | 85/116 | 21,264 total state rows | Exact state-object NetGUID and exported state path, including targeting, charge, throw, dash, recall, possession, and return-to-inactive states. |
| Named ability RPC | 88/116 | 16,645 | Exact RPC name and actor NetGUID for projectile stop, continuous/one-shot effects, persistent-data moves, and state-machine reset. |
| Canonical actions | n/a | 9,350 | Observed/derived phases assembled without fallback timing. |

The union is 88/116 primary slots: every slot belonging to the 22 rostered
agents has at least one native lane. Named RPC coverage includes inventory and
reset traffic, so it proves lane visibility, not necessarily that the player
cast that ability. Jett's passive actor lane is recorded separately and is not
counted in the 116-slot denominator.

Additional decoded totals are 43 `CharacterAbilityEffectInfo` statistics, 196
explicit placement locations, 148 native ultimate-use rows, 4,595 state-backed
actions, 3,169 exact equippable NetGUID-to-ability changes, and 85 quarantined
movement candidates. The explicit placements are 81 Clove Ruse targets, 67
Brimstone Sky Smoke targets, 46 Miks Waveform targets, and 2 Brimstone Orbital
Strike targets.

Every cast now has replay round, round phase, clock provenance, and static
identity. Eighty-one `RoundStarting` casts moved to their native round-start +
`CastTime` timestamp instead of using the later actor-open observation; the
median correction is 14.2 seconds. The 43 effect records comprise 24
`TimeSprinting`, 12 `HealingDone`, and 7 `DamageDone` statistics with affected
target NetGUIDs where serialized.

Lifecycle status across app-facing utility actors is:

- 3,902 actors with an observed closure: 3,072 ordinary channel
  close/dormancy endpoints and 830 closes classified as round teardown from
  surrounding replay events.
- 13 recording-censored derived endpoints.
- 182 open/unknown endpoints.
- 0 fallback endpoints.

All four cast slots were present for Fade, Tejo, Raze, Chamber, Skye, Sova,
Killjoy, Phoenix, Yoru, Sage, Reyna, and Omen. The cast lane omitted one or
more slots for ten other rostered agents, but actor, exact equip, state, and RPC
lanes recover evidence that the cast array alone misses.

The seven agents absent from these matches are Astra, Gekko, Harbor, Veto,
Viper, Vyse, and Waylay.

The existing control replay adds runtime evidence for Gekko and Vyse. Across
the new corpus plus that control, Astra, Harbor, Veto, Viper, and Waylay remain
without runtime replay proof.

## Identity and False-Positive Audit

Every one of the 4,097 accepted utility actors now has high-confidence static
identity. Six per-track identity audits report zero findings. Compared with the
pre-pass output, 901 retained rows changed identity: 702 slot corrections, 18
agent corrections, and 191 name-only corrections. The corrected families
include Sage Barrier/Slow, Raze Paint Shell secondaries, Deadlock
Barrier/GravNet, Clove Ruse/Meddle, Cypher Spycam darts, Fade Haunt, and Tejo
sonar.

The pass also removed 1,569 false ability actors, including 1,459 weapon pickup
projectiles, 56 Clove post-death unarmed actors, theater lights, and finisher
effects. The old 1,381 timing-heuristic cast links are no longer asserted:
there are 509 replay-causal `FocusProjectiles` links and 1,110 timing-only links
kept explicitly as candidates.

## Replay-Native Lifecycle Lanes

The decoder now preserves these independent observations instead of collapsing
an ability into one guessed interval:

1. `CharacterAbilityCastInfo`: player, slot, replay round/phase time, cast and
   effect locations, destroyed count, statistics, values, times, and affected
   target NetGUIDs.
2. Typed input capture: serialized input type/result plus exact
   `EquippableChange` NetGUID identity. Activation input remains unassigned
   unless another exact lane identifies its ability.
3. Equippable state machines: `CurrentState` NetGUID resolved through the
   runtime export map to the exact state path. A return to `InactiveState` is
   an observed state-machine endpoint; an unclosed sequence is right-censored.
4. Named class-net RPCs: exact RPC name, actor NetGUID, payload size/prefix,
   identity, and time. The name is retained without promoting it to a stronger
   gameplay claim.
5. Actor lifecycle: observed channel open, transform, close, and dormancy.
   Round teardown is derived and labeled; unknown termination cause remains
   unknown.
6. `characterUltimateUsed`: native player and clock, independently retained
   from the cast lane.

Examples now visible in real corpus data include `MapTargetingState`,
`PlacementTargetingState`, `RespondToEventState_ThrowProjectile`,
`RespondToEventState_StartCast`, `State_Dashing`, recall/teleport states,
possession states, and Clove post-death states. The RPC lane contains all seven
currently recognized exact names, including `MulticastStopProjectile`, the
continuous-effect start/stop/update family, and one-shot effects.

## Static Pattern for Agents Missing From Replays

The bundled static decoder index covers all 29 agents. It is generated from the
authoritative character `abilities[]` records and primary equippable assets,
then follows explicit spawn edges and specific asset relationships.

The reusable identity order is:

1. Character UUID plus `EAresItemSlot` for authoritative agent/slot/name.
2. Exact ability asset path or class identity.
3. Explicit ability-to-actor/projectile/deployable spawn edge.
4. Explicit actor back-reference, such as a Gekko reclaim equippable.
5. Unique ability-directory propagation when only one identity is possible.
6. Specific parent/template inheritance.
7. Fail closed when a class alias is ambiguous.

The current index contains 13,526 actor records, 12,480 exact asset identities,
12,812 class aliases, 281 explicit spawn edges, and 189 ambiguous aliases that
are deliberately not guessed. This lets a future replay identify actors for an
agent absent from this corpus. Static data cannot prove that agent's runtime
state transitions, lifecycle branches, or timing until a replay contains them.

## Remaining Evidence Gaps

- Direct spatial-actor owner/instigator NetGUID is not decoded. Exact
  equippable owner is available through input identity; weak time proximity is
  candidate evidence only.
- Actor close does not yet distinguish natural expiry from hit, trigger,
  pickup, recall, destruction, suppression, or owner death without another
  exact state/RPC/property signal.
- Many damage, heal, buff, reveal, detain, suppression, teleport, possession,
  resurrection, and projectile-bounce payloads still need semantic decoding.
- Raw evidence already exposes useful next targets, including Chamber recall
  and anchor-destruction rows, Sage dissipates, Deadlock deployments, Nanoswarm
  throws, Phoenix wall points, and flash paths; those payloads are not yet
  promoted to semantics.
- Tactical-map points, line endpoints, beam geometry, and multi-target payloads
  are only partially decoded.
- Only Vyse Arc Rose's inactive placement-to-round-teardown branch has a
  visually audited registry fixture. Branch verification must not be expanded
  to an entire ability without replay-backed cases.
- The replays are release 13.00 while the available static content export is
  12.11. Every track reports this mismatch as a warning. The exact/fail-closed
  policy limits risk, but a 13.00 static export is still required to remove it.
- `/Game/Maps/Plummet/Plummet` is Summit, not Abyss. It remains diagnostic-only
  until a verified Summit map transform and UI asset are added.

These gaps are explicit capabilities in the track (`directActorOwner: false`
and `semanticTerminationCause: false`) rather than silently inferred values.
