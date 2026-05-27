# Cloud Online Release Gaps

This note captures the current backend/provider gaps found while auditing the online Icarus experience. The app has a real cloud foundation, but these items should be revisited before a broad public release.

## Current Recommendation

Ship as a private beta only until the release blockers below are fixed. These issues affect shared library access, backend confidence, conflict behavior, permission clarity, and media cleanup.

## Release Blockers

### Missing Shared-With-Me Backend Function

- Flutter calls `strategies:listSharedWithMe` from `lib/collab/convex_strategy_repository.dart`.
- The Convex backend currently appears to export `strategies:listForFolder`, but no `listSharedWithMe` function exists in `convex/strategies.ts`.
- Impact: the root "Shared with me" cloud library view may fail unless the deployed backend has an out-of-band function.

Suggested fix: add `listSharedWithMe` or change the client to use `strategies:listForFolder` with `scope: "shared"` for the root shared view.

### Convex TypeScript Check Fails

- `npx tsc --noEmit` reports errors in `convex/pages.ts`.
- Observed errors:
  - `current` is possibly `undefined` around page reorder patching.
  - `string | undefined` passed where `string` is required around ordered page ids.

Suggested fix: tighten the reorder loop null checks and ensure undefined page IDs are guarded before use.

### Targeted Sync Tests Are Not Green

- Command run:

```powershell
fvm flutter test test\strategy_op_queue_provider_test.dart test\strategy_page_session_provider_test.dart test\collab_sync_models_test.dart
```

- Failures included:
  - cloud agent addition did not queue an add op as expected
  - cloud map change did not queue a strategy patch op as expected
  - Hive boxes missing in two session-provider tests

Suggested fix: stabilize the test harness first, then verify the cloud queue behavior failures are either expected test drift or real regressions.

## Conflict Handling Gaps

### Backend Rejects Stale Writes, But UX Is Thin

- Backend rejects stale writes with `sequence_mismatch` and `revision_mismatch` in `convex/ops.ts`.
- Client receives rejected acks and pushes `ConflictResolution` objects through `strategyConflictProvider`.
- I did not find a user-facing conflict resolver UI.

Impact: users may not clearly understand when their edit was rebased, retried, dropped, or overwritten by remote state.

Suggested fix: add a small visible cloud sync/conflict surface that can show:

- edit kept and retried
- remote edit won
- local edit needs manual retry
- sync failed and is paused

### Conflict Provider Is Passive

- `lib/providers/collab/strategy_conflict_provider.dart` stores conflicts.
- The provider is not enough by itself; it needs a clear consumer in the UI or a documented automatic-resolution behavior.

Suggested fix: either wire conflicts to UI or remove/replace the provider with explicit automatic conflict policy and telemetry.

## Permission And Sharing Gaps

### Effective Folder Role May Be Misreported

- Backend supports inherited folder roles via `getEffectiveStrategyRoleForUser`.
- Strategy list role display in `convex/strategies.ts` appears to use direct strategy membership first and falls back to `viewer`.

Impact: a user who has editor access via a shared folder may appear as a viewer in the strategy list, causing UI controls to be hidden or disabled incorrectly.

Suggested fix: return the effective role from `getEffectiveStrategyRoleForUser` in strategy summaries.

### Link Revocation Does Not Remove Existing Access

- `shares:revoke` marks a share link as revoked.
- Existing `strategyCollaborators` / `folderCollaborators` rows created by that link remain.

Impact: this is okay if "revoke link" only means "stop future joins," but it is not enough for "remove access."

Suggested fix: make UI copy explicit, or add separate collaborator management with remove/downgrade access.

### Share Links Never Expire

- The share dialog says links never expire.
- `inviteTokens` support expiry/revocation, but the visible Flutter share flow uses `shareLinks`, not `invites`.

Impact: public users may expect expiring links or member management for team content.

Suggested fix: either add expiration options to share links or reserve public launch for a simpler "private beta link sharing" framing.

### Invite Token Flow Appears Unused

- Backend has `convex/invites.ts` with expiry and redemption.
- I did not find a Flutter UX for creating/redeeming those invite tokens.

Suggested fix: remove/defer this API if not needed, or wire it into the sharing UI.

## Media Upload And Recovery Gaps

### Upload Retry Exists

- `cloud_media_upload_queue_provider.dart` persists jobs in Hive.
- Failed uploads retry with backoff.
- Save state tracks media sync errors.

This part is a solid foundation.

### Orphan Storage Risk

- If the blob upload succeeds but `images:completeUpload` fails, the Convex storage object can be orphaned.

Suggested fix: add a cleanup path for unattached storage IDs, or store an upload intent before posting the blob so old pending uploads can be swept.

### Stale Asset Cleanup Is Not Implemented

- `images:listPotentiallyStale` currently returns an empty list.
- `images:deleteAssetRef` only deletes assets still referenced by the strategy.

Impact: once an image is removed from a strategy, the current delete path may no longer be able to clean up the asset row/storage object.

Suggested fix: track asset ownership/strategy association directly on `imageAssets`, or keep a reference table so stale assets can be listed and deleted safely.

## Follow-Up Checklist

- [ ] Add or replace `strategies:listSharedWithMe`.
- [ ] Fix `convex/pages.ts` TypeScript errors.
- [ ] Re-run targeted sync tests and fix real failures.
- [ ] Return effective strategy role in cloud strategy summaries.
- [ ] Add visible conflict/sync status UI.
- [ ] Clarify "revoke link" versus "remove collaborator access."
- [ ] Decide whether share links need expiry before public launch.
- [ ] Implement stale/orphan media cleanup.
- [ ] Add backend tests for share redemption, revocation, role inheritance, and stale op rejection.
- [ ] Add client tests for conflict ack handling and media upload failure recovery.
