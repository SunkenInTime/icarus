# Handoff: make Convex sync page-scoped

Status: ready for implementation

Verified base: `277fc14` on 2026-08-25

PR target: `icarus-cloud`

## The assignment

Deliver one reviewable PR that makes the normal editor sync one strategy shell
and one active page. Keep the full strategy snapshot as a one-shot read for
export, import verification, and recovery. Persist the operation outbox so an
unacknowledged edit survives a page switch, app restart, expired auth, and
network loss.

The PR is at its midpoint when it opens. Finish by running the visible desktop
proof and babysitting the current PR head until CI and automated review have no
actionable findings. Leave the PR unmerged for Dara.

Read these before editing:

1. [`AGENTS.md`](../../AGENTS.md) for the data and product rules.
2. [`CONTEXT.md`](../../CONTEXT.md) for Icarus vocabulary.
3. [`server_side_sync_boundaries_blueprint.html`](server_side_sync_boundaries_blueprint.html) for the architectural reasoning and diagrams.
4. [`DESIGN.md`](../../DESIGN.md) before changing any visible state.
5. [`auth_flow_reference.md`](../auth_flow_reference.md) if the verification path reaches sign-in or token recovery.

## Fixed decisions

Treat these as the contract, not design prompts.

- Convex remains the durable cloud library and collaboration authority.
- An open editor has two live queries: `strategy:getShell` and
  `page:getSnapshot` for the active page.
- `strategy:getFullSnapshot` is a one-shot query. No provider subscribes to it.
- A new `pageContents` row owns mutable page settings. The `pages` row remains
  the descriptor used by the page list.
- An element, lineup, or page-content edit writes its own row and its operation
  event. It does not patch the parent strategy.
- Conflict checks use the revision of the record being edited. There is no
  global content sequence and no page-level sequence.
- `strategies.revision` covers strategy metadata and page collection structure.
  It does not advance when canvas content changes.
- The library `updatedAt` does not change on every drag. Add a separate library
  activity record later only if a measured product need justifies it.
- The outbox keeps a failed op. After the retry budget it becomes paused and
  visible. It never discards the op.
- Local mode, `.ica` files, and library backups keep their current shape and
  behavior.

The normal edit path should have one sentence worth remembering:

> The cost and conflict range of an edit match the record the user edited.

## Starting evidence

The current implementation has four useful pieces and three liabilities.

Useful pieces:

- `active_page_live_sync_provider.dart` already projects queued and in-flight
  local intent over a remote base.
- `strategy_op_queue_provider.dart` already coalesces intent by page and entity.
- Elements and lineups already have `by_pageId` indexes and per-row revisions.
- Operation events already deduplicate `strategyId + clientId + opId`.

Liabilities:

- `snapshot:get` reads the strategy, every page, every element, every lineup,
  and every referenced asset as one reactive read set.
- `ops:applyBatch` advances `strategies.sequence` and `updatedAt` for ordinary
  content edits.
- The outbox is memory-only, regenerates `clientId`, and removes an op after
  eight failed attempts.

The nearest named branches do not contain the proposed boundary. At the
verified base, both are already ancestors of this branch:

- `origin/cursor/convex-image-asset-storage-3cc3` introduced the broader
  strategy-level query refactor.
- `origin/cursor/cloud-page-sync-overlay-6677` introduced the active-page
  overlay.

Before implementation, refresh refs and search named branches for
`pageContents`, `getShell`, and `getFullSnapshot`. Reuse newer work if it exists.
Do not cherry-pick either branch listed above into this base.

Baseline proof at the verified base:

```text
npx tsc --noEmit
PASS

fvm flutter test \
  test/strategy_page_session_provider_test.dart \
  test/strategy_op_queue_provider_test.dart \
  test/collab_sync_models_test.dart \
  test/cloud_ui_parity_helpers_test.dart \
  test/strategy_integrity_test.dart
PASS, 55 tests
```

Refresh this baseline before changing code. Record drift in the PR body.

## Target server model

| Record | Owns | Revision changes when |
| --- | --- | --- |
| `strategies` | identity, owner, folder, name, map, theme, page collection revision | strategy metadata changes, or a page is added, deleted, or reordered |
| `pages` | `publicId`, strategy membership, name, order, side | that page descriptor changes |
| `pageContents` | one page's settings | those settings change |
| `elements` | one placed canvas entity | that entity changes |
| `lineups` | one lineup group | that lineup changes |
| `imageAssets` | upload and delivery state | that asset changes |
| `operationEvents` | idempotency result for one op | once, when the server accepts or rejects the op |

`pageContents` is one-to-one with a page:

```text
pageId       Id<"pages">, indexed by_pageId
settings     strategySettingsValidator, optional
revision     number
createdAt    number
updatedAt    number
```

Create the page descriptor and page content row in the same mutation. Delete
the page content row when deleting its page. Keep the existing orphan cleanup
for elements and lineups.

## Target read contract

| Query | Lifetime | Reads | Must not read |
| --- | --- | --- | --- |
| `strategy:getShell` | subscribed while the editor is open | authorized role, strategy metadata, ordered page descriptors | page settings, elements, lineups, image assets |
| `page:getSnapshot` | subscribed for one active page | page descriptor, its `pageContents`, its elements, its lineups, referenced assets | records belonging only to another page |
| `strategy:getFullSnapshot` | one-shot | every record required to reconstruct and export the strategy | nothing required for a lossless round-trip may be omitted |

The page query takes both `strategyPublicId` and `pagePublicId`. It verifies
membership and viewer access before returning data. It uses `by_pageId` for
elements and lineups. It resolves image assets only from IDs referenced by the
active page's element and lineup payloads.

Use separate client types for the separate jobs:

- `RemoteStrategyShell`
- `RemotePageSnapshot`
- `RemoteStrategySnapshot` or `RemoteFullStrategySnapshot` for the full
  one-shot result

Do not make one large type whose fields become nullable depending on which
query produced it. Export must accept only the full snapshot type.

## Target write contract

Use `expectedRevision` consistently. Its authority is the target record:

| Operation | Checks | Writes | Legitimate reactive update |
| --- | --- | --- | --- |
| strategy metadata patch | `strategies.revision` | strategy row and operation event | shell and library |
| page add, delete, reorder | `strategies.revision` | affected page rows, strategy revision, page content row when applicable, operation event | shell and library |
| page descriptor patch | `pages.revision` | one page row and operation event | shell, plus active page if it is open |
| page content patch | `pageContents.revision` | one page content row and operation event | that active page |
| element add, patch, move, delete | element revision when the row exists | one element row and operation event | that active page |
| lineup add, patch, move, delete | lineup revision when the row exists | one lineup row and operation event | that active page |

Add `pageContent` as an operation entity type. Keep page descriptor and page
content intent in separate entity keys so coalescing cannot merge two revision
domains. The active-page controller may produce both intents when one local
action changes side and settings.

Remove `expectedSequence` and `appliedSequence` from the protocol, server
validator, event schema, acknowledgement model, client models, and tests. A
strategy-level operation uses `expectedRevision` against
`strategies.revision`.

### Replay safety

Operation events are currently retained for 30 days. A durable outbox can live
longer, so every operation must remain safe after its event has expired.

- Replayed add with identical existing content returns an acknowledged no-op.
- Replayed add with different existing content rejects. It does not become an
  upsert over newer work.
- Replayed patch whose desired content already matches returns an acknowledged
  no-op before revision rejection.
- Replayed patch against different newer content rejects on revision.
- Replayed delete against a missing row returns an acknowledged no-op.
- Replayed reorder that already matches returns an acknowledged no-op.

Prove each case in server tests. Operation-event lookup remains the fast path.

## Execution path

### 1. Lock the proof before the refactor

Refresh the base branch and named branches. Run the baseline commands. Add
focused tests for the new contract before changing production behavior.

The server tests must cover:

- the shell excludes page content and canvas records;
- one page snapshot excludes other pages and their assets;
- the full snapshot reconstructs every page and referenced asset;
- a content op leaves the strategy row unchanged;
- different entities and different pages can update from the same starting
  strategy revision;
- two edits to the same entity from one revision produce one visible reject;
- page membership and reorder use the strategy revision;
- every replay case above is safe after the event row is absent.

The repository has no Convex test harness at the verified base. Add the
smallest repository-local harness that executes the real Convex functions and
schema. Keep pure helper tests only for logic that cannot run through the real
functions.

Done when the new tests fail for the current broad-query, parent-write, and
memory-only behavior while the refreshed baseline still passes.

### 2. Reshape the empty development deployment

Update source schema and validators. Add `pageContents`, replace the strategy
content sequence with `strategies.revision`, and update operation events.
Update all page creation and cloud migration paths in the same cut.

The development deployment contains team data only and may be wiped under the
rules in `AGENTS.md`. Verify that assumption before the destructive action.
Regenerate Convex output with `npx convex dev`. Edit no file under
`convex/_generated/` by hand.

Done when a clean development deployment accepts the schema, page creation
always creates exactly one page content row, and `npx tsc --noEmit` passes.

### 3. Add the narrow reads

Implement the three target queries. Keep authorization in each public query.
Keep sorting deterministic. Use the existing canonical payload and asset
reference helpers instead of introducing a second serializer.

Delete or deprecate `snapshot:get` only after all client and export callers
have moved. No subscribed provider may retain it as a recovery fallback. A
failure recovery may issue a one-shot full snapshot, then return to shell and
active-page subscriptions.

Done when server tests prove the read sets by result and index path, and a
repository search shows the editor no longer subscribes to `snapshot:get`.

### 4. Narrow the writes

Refactor `ops:applyBatch` around the target write table. Split page descriptor
and page content intent. Apply replay checks before stale-revision rejection
where an identical desired state is a safe no-op.

Keep one mutation batch atomic. Keep operation events as the acknowledgement
source. A rejected op returns the latest target revision and payload needed by
the current client conflict flow.

Done when tests prove that content edits do not change the strategy row or an
inactive page, while metadata and page structure edits still update the shell.

### 5. Split the Flutter read model

Add repository methods for the shell, active page, and full snapshot. Replace
`remoteStrategySnapshotProvider` with a shell provider and one active-page
provider, or leave a thin compatibility name only if its type and lifetime are
unambiguous.

On a page switch:

1. Project and persist the current page intent.
2. Attempt a flush without making navigation wait indefinitely.
3. Change the active page ID.
4. Cancel the old page subscription.
5. Subscribe to the new page and hydrate its remote base.
6. Reapply any persisted local intent for that page.

Replace `_RemotePageHydrationKey` sequence gating with active-page revision and
content fingerprints. A page snapshot update should rehydrate its page without
waiting for a strategy header update. Preserve undo history and the local
overlay rules already covered by provider tests.

Export, recovery, and cloud-to-local copy paths must call the one-shot full
snapshot. Their types must prevent an active-page result from reaching export.

Done when one editor owns exactly two live subscriptions regardless of page
count, inactive-page updates do not rehydrate the canvas, and every existing
page-switch, overlay, conflict, media, and round-trip test passes.

### 6. Make the outbox durable

Use a dedicated Hive box containing versioned, JSON-safe records. Keep it out
of `StrategyData` so local library migrations and `.ica` serialization remain
unchanged. Each record contains at least:

```text
outboxVersion
accountId
strategyPublicId
entityKey
clientId
opId
serialized op
attempts
createdAt
updatedAt
lastAttemptAt
lastError
state
```

The account ID prevents one signed-in user from submitting another user's
pending work on a shared computer. Persist `clientId` and `opId` across app
restarts so a crash after server acceptance reuses the operation-event key.

Use this ordering:

1. Persist new or coalesced desired intent.
2. Reflect it in provider state and render `Syncing`.
3. Send it while the durable record remains present.
4. On acknowledgement, remove the durable record.
5. On rejection, persist a replacement intent before removing the rejected
   record, or keep the rejected record in `Attention` for user action.

Load and validate the box before the sync chip may say `Synced`. A corrupt
record produces `Attention` with recovery detail. Sign-out, strategy switch,
provider disposal, and retry exhaustion retain unacknowledged records.

Replace the eight-attempt discard with a paused state. Manual retry resumes the
same durable intent. The exit guard reads durable state, including pending work
for a page that is no longer active.

Tests must cover these crash windows:

- restart after enqueue and before send;
- restart while an op is in flight;
- restart after server acceptance and before local removal;
- strategy switch with another page's pending op;
- auth expiry and recovery;
- retry exhaustion followed by manual retry;
- corrupt persisted record;
- sign-out and sign-in as the same account;
- sign-in as a different account.

Done when no unacknowledged intent exists only in memory and retry exhaustion
cannot discard it.

### 7. Run the automated gate

Run focused tests while iterating, then run the full gate from the repository
root:

```bash
npx tsc --noEmit
fvm flutter test \
  test/strategy_page_session_provider_test.dart \
  test/strategy_op_queue_provider_test.dart \
  test/collab_sync_models_test.dart \
  test/cloud_ui_parity_helpers_test.dart \
  test/strategy_integrity_test.dart
fvm flutter test
fvm flutter analyze --no-fatal-infos
git diff --check
```

If the Convex harness has a separate command, add it before the Flutter tests
and to CI. Record every command and result in the PR body. Existing warnings
may remain only when the refreshed base has the same warning.

Done when the full gate passes and the diff contains no hand-edited generated
file, accidental lockfile churn, or unrelated worktree changes.

### 8. Finish visible proof and PR delivery

After the automated gate passes, read
[`server_side_sync_boundaries_delivery.md`](server_side_sync_boundaries_delivery.md).
It contains the required Computer Use scenarios, Convex resource measurement,
PR contents, and current-head review loop. Opening the PR before completing its
visible proof is premature.

Done when every completion criterion in the delivery runbook passes. Leave the
PR unmerged for Dara.

## Stop and escalate

Stop implementation and ask Dara when any of these becomes true:

- the linked Convex deployment contains public user data;
- the proposed server model would change local `.ica` or backup shape;
- another branch now implements the same boundary with incompatible choices;
- a generated-file change cannot be reproduced by its generator;
- preserving pending intent requires silently choosing between two users'
  conflicting edits;
- the PR target has moved away from `icarus-cloud`;
- unrelated dirty work overlaps a file this refactor must rewrite.

## File map

Start here rather than scanning the whole app:

```text
convex/schema.ts
convex/snapshot.ts
convex/ops.ts
convex/pages.ts
convex/strategies.ts
convex/lib/opTypes.ts
convex/lib/payloadValidators.ts
convex/maintenance.ts

lib/collab/collab_models.dart
lib/collab/convex_strategy_repository.dart
lib/providers/collab/remote_strategy_snapshot_provider.dart
lib/providers/collab/active_page_live_sync_models.dart
lib/providers/collab/active_page_live_sync_provider.dart
lib/providers/collab/strategy_op_queue_provider.dart
lib/providers/collab/strategy_conflict_provider.dart
lib/providers/strategy_page_session_provider.dart
lib/strategy/strategy_page_source.dart
lib/strategy/strategy_import_export.dart
lib/widgets/cloud_sync_status_chip.dart
lib/services/unsaved_strategy_guard.dart

test/strategy_page_session_provider_test.dart
test/strategy_op_queue_provider_test.dart
test/collab_sync_models_test.dart
test/strategy_integrity_test.dart
```

The blueprint explains why this boundary is the right one. This handoff defines
what must be true before the work is finished.
