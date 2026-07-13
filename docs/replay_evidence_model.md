# Replay Evidence Model

Replay output must keep observation, interpretation, and fallback separate.
Gameplay research defines possible phases and which replay signals to seek. It
must not fabricate an event or silently replace evidence captured from the
replay.

Schema-v2 native tracks apply the same rule to
`abilityActions[].phases[]`. Each phase carries
`evidence: observed | derived | absent` and its source. Fallback timing remains
readable for legacy fixtures, but the current native emitter never writes it
into the canonical action lane or uses it to activate an app-facing marker.

An equippable state transition is `observed` only when the replay's
`CurrentState` property provides a NetGUID that resolves through the runtime
export map to a concrete state path. State-name timing is not inferred from
inputs or nearby casts. A return to `InactiveState` is an observed state-machine
endpoint, not automatically proof that every spawned gameplay effect ended.

Named ability-actor RPCs are observed evidence only for the RPC that was
serialized. The canonical phase keeps the exact RPC name and actor NetGUID.
Interpretations such as activation, hit, destruction, pickup, or recall remain
absent unless an additional replay field proves that meaning.

## Evidence classes

- `observed`: read directly from replay data, such as actor open, transform,
  actor close, or a decoded state event.
- `derived`: joined from observed records, such as mapping an internal class to
  an ability or classifying a clustered close as round teardown.
- `fallback`: a registry-approved estimate used only when the relevant replay
  evidence is absent.
- `absent`: no supporting replay evidence was observed. This is not proof that
  the gameplay event did not happen.

## Lifecycle timing

Utility actors retain separate timing facts:

- `observedStartMs` and `observedEndMs`
- `fallbackLifetimeMs` and `fallbackEndMs`
- `effectiveEndMs`
- `endReason`
- `lifecycleEvidence`

Observed actor timing wins over fallback timing. A fallback may never occupy or
overwrite an observed field. An actor with an `observed-actor` timing policy
and no observed end remains right-censored rather than receiving a fabricated
end time.

The legacy `timeMs`, `closedAtMs`, and `lifetimeMs` fields remain available for
older tracks. New consumers should use the explicit lifecycle fields.

## End reasons

The interpreter may emit:

- `actor-channel-close`
- `channel-dormancy`
- `round-teardown`
- `recording-censored`

Channel close is evidence that observation ended, but its gameplay meaning
depends on the decoded close reason and surrounding events. A round-teardown
classification is derived evidence and must retain the observations that led
to it.

## Verified registry

`tools/valorant_replay_probe/verified_ability_lifecycle_registry.json` is the
source-owned registry for ability-specific lifecycle rules. Rules match
internal actor class paths, never only a user-facing or wiki name.

An ability has two useful statuses:

- `observed`: a candidate rule exists, but no audited regression case proves
  it.
- `verified`: at least one visual audit is represented by a reproducible
  fixture with replay hash, stable actor identity, and expected timeline.

Verification applies to a lifecycle branch, not automatically to every branch
of the ability. Reports and capability matrices should be generated from the
registry and tests rather than maintained separately.

## Audit fixture flow

Clicking a rendered ability snapshots its raw target evidence into the audit
entry. The snapshot must include durable actor or cast identity, internal class
path, observed timing, decoded close evidence, and semantic identity available
at that moment. Exported audits are immutable evidence for review and can be
promoted into registry regression fixtures after confirmation.

## Current verified case

Vyse Arc Rose actor `5272` in replay
`d3c0e7a2-d6fc-4302-b34f-8726054de6b0` was observed from `127598` ms until
`152339` ms. The next round began at `152416` ms. No activation evidence was
observed. This verifies the placed, inactive, round-teardown branch only.
