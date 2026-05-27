# Convex Cloud Sync Refactor Plan

## Summary

Intent: refactor Icarus Cloud's Convex sync/query/subscription plumbing so it uses Convex more efficiently while preserving the current UI and all existing product behavior. No visual changes, no feature removals, and no intentional workflow changes. Any currently synced editor state must continue to sync; if inspection finds a currently local-only field that should be cloud-backed, add it to the cloud sync path with tests.

## Scope

In scope: Convex queries/mutations, Flutter repository/provider data plumbing, typed model helpers, sync coverage audit, backend/client tests, and performance-oriented query shape changes.

Out of scope: UI redesign, new conflict UI, product behavior changes, changing the sequence/conflict model, and digest-table migrations unless explicitly approved later.

## Current Problems To Address

1. `remote_strategy_snapshot_provider.dart` subscribes to granular Convex data but mostly treats updates as dirty flags, then refetches the whole strategy snapshot.
2. Open strategies use per-page `elements:listForPage` and `lineups:listForPage` subscriptions, creating `3 + 2 * pageCount` active subscriptions.
3. Cloud library queries scan broad tables and filter in TypeScript, especially `strategies.ts` and `folders.ts`.
4. Cloud library summaries are computed from source tables each time; a digest table may help later, but should not be the first change.
5. Deferred follow-up: parent `strategy.sequence` / `updatedAt` is a hot invalidation point, but it is also the current remote change clock, so do not change it in this refactor.

## Public API And Type Changes

Add Convex public queries:

- `elements:listForStrategy({ strategyPublicId })`
- `lineups:listForStrategy({ strategyPublicId })`
- `strategies:listSharedWithMe({})` if still missing in the current backend

Keep existing queries for compatibility:

- `elements:listForPage`
- `lineups:listForPage`
- `strategies:listForFolder`
- `pages:listForStrategy`
- `images:listForStrategy`
- `strategies:getHeader`

Add Flutter repository methods:

- `listElementsForStrategy(strategyPublicId)`
- `listLineupsForStrategy(strategyPublicId)`
- `watchStrategyHeader(strategyPublicId)` already exists; keep it.
- `watchPagesForStrategy(strategyPublicId)`
- `watchImageAssetsForStrategy(strategyPublicId)`
- `watchElementsForStrategy(strategyPublicId)`
- `watchLineupsForStrategy(strategyPublicId)`

Add model helpers:

- `RemoteStrategySnapshot.copyWith(...)`
- helper methods that replace header, pages, assets, elements, or lineups without mutating unrelated snapshot sections
- grouping helpers that convert strategy-level element/lineup lists into `elementsByPage` and `lineupsByPage`

## Implementation Checklist

### 1. Create The Workflow Doc

- [x] Create `docs/cloud_sync_refactor/convex_sync_refactor_plan.md` and save this plan there.
- [x] Use this file as the canonical implementation checklist for the workflow.

### 2. Add Strategy-Level Element And Lineup Queries

- [x] In `convex/elements.ts`, add `listForStrategy`.
- [x] Use `getStrategyByPublicId`, `assertStrategyRole(ctx, strategy, "viewer")`, query `elements` with `by_strategyId`, and query `pages` with `by_strategyId` to map internal `pageId` values back to page `publicId`.
- [x] Return the same client shape as `listForPage`, including `publicId`, `strategyPublicId`, `pagePublicId`, `elementType`, `payload`, `sortIndex`, `revision`, `deleted`, `createdAt`, and `updatedAt`.
- [x] In `convex/lineups.ts`, add `listForStrategy` with the same authorization and page lookup pattern.
- [x] Do not remove the page-level queries.

### 3. Refactor Snapshot Fetching

- [x] Update `ConvexStrategyRepository.fetchSnapshot` so it calls `strategies:getHeader`, `pages:listForStrategy`, `images:listForStrategy`, `elements:listForStrategy`, and `lineups:listForStrategy`.
- [x] Remove the loop that calls `elements:listForPage` and `lineups:listForPage` for every page.
- [x] Group returned elements and lineups by `pagePublicId`.
- [x] Preserve the same `RemoteStrategySnapshot` shape, page ordering, and deleted-row handling downstream.

### 4. Use Subscription Payloads Directly

- [x] Update `RemoteStrategySnapshotNotifier` so subscription callbacks decode their payloads and update only the relevant snapshot section.
- [x] Header update replaces only `snapshot.header`.
- [x] Pages update replaces `snapshot.pages`, updates available page IDs, and prunes maps only for pages that no longer exist.
- [x] Assets update replaces only `snapshot.assetsById`.
- [x] Elements update replaces only `snapshot.elementsByPage`.
- [x] Lineups update replaces only `snapshot.lineupsByPage`.
- [x] Initial open still performs a full `fetchSnapshot`.
- [x] Manual `refresh()` still performs a full `fetchSnapshot`.
- [x] Subscription errors still fall back to the existing refresh/error path.
- [x] Auth incident behavior remains unchanged.

### 5. Collapse Per-Page Subscriptions

- [x] Replace the per-page element and lineup subscription maps in `RemoteStrategySnapshotNotifier` with one strategy-level element subscription and one strategy-level lineup subscription.
- [x] Active strategy subscription set becomes `strategies:getHeader`, `pages:listForStrategy`, `images:listForStrategy`, `elements:listForStrategy`, and `lineups:listForStrategy`.
- [x] Remove `_syncPageSubscriptions` / `_syncPageWatchersFromIds` after strategy-level subscriptions are working.
- [x] Keep cleanup behavior in `_disposeSubscriptions`.

### 6. Preserve Current Editor Behavior

- [ ] Do not change `StrategyPageSessionNotifier` behavior except where needed to consume the updated snapshot shape.
- [ ] Preserve `header.sequence` as the signal that triggers remote page rehydration.
- [ ] Preserve pending local overlays over remote data.
- [ ] Preserve ack reconciliation refresh behavior when needed.
- [ ] Preserve conflict rejects through `strategyConflictProvider`.
- [ ] Preserve page switch flushes before changing active pages.
- [ ] Preserve media asset URL hydration.

### 7. Fix Cloud Library Query Shapes

- [ ] Refactor `convex/strategies.ts` to avoid global table scans for normal user-scoped views.
- [ ] Refactor concrete folder strategy listing to resolve the folder and query `strategies` with `by_folderId`.
- [ ] Refactor owned root strategies to query `strategies` with `by_ownerId` and keep only `folderId === undefined`.
- [ ] Refactor direct shared root strategies to query `strategyCollaborators` with `by_userId`, fetch those strategies, and keep non-owned root strategies.
- [ ] Preserve effective role checks through `getEffectiveStrategyRoleForUser`.
- [ ] Preserve returned `CloudStrategySummary` fields and sorting.
- [ ] Refactor `convex/folders.ts` to use `by_ownerId`, `by_parentFolderId`, and `folderCollaborators.by_userId` instead of scanning all folders.
- [ ] Preserve current visible hierarchy semantics unless a test proves existing behavior is broken.
- [ ] Keep inherited folder role behavior by traversing descendants from directly shared folders through `by_parentFolderId`.
- [ ] Add or fix `strategies:listSharedWithMe` so the Flutter repository call has a real backend function.

### 8. Sync Coverage Audit

Must remain synced:

- [ ] strategy metadata: name, map, theme profile, theme override
- [ ] page data: name, order, attack/defense side, settings
- [ ] elements: agents, abilities, drawings, text, images, utilities
- [ ] lineups and lineup image references
- [ ] image asset metadata and URLs
- [ ] deletes, moves, reorder, payload patches
- [ ] role/capability behavior for owner/editor/viewer

If a currently user-visible strategy/page field is local-only but should be cloud-backed, add serialization, Convex op handling, hydration, and tests in the same refactor.

### 9. Digest Table Decision

Do not implement digest tables in the first pass.

Follow-up design:

- Candidate table: `strategyDigests`
- Candidate fields: strategy id/public id, owner id, folder id, name, map data, role-facing summary fields, attack label, created/updated timestamps
- Maintenance points: strategy create/update/move/delete, page add/patch/delete/reorder, share/collaborator changes
- Trigger condition: implement only if optimized indexed library queries still show high read bytes or subscription churn

### 10. Step Five Follow-Up Hint

`strategy.sequence` and `updatedAt` are currently patched after accepted ops and act as the remote change clock. Splitting high-churn sync metadata away from stable strategy metadata could reduce header/library invalidations, but it must be planned separately because `StrategyPageSessionNotifier` depends on `header.sequence` for rehydration. Do not change this in the current refactor.

## Tests And Verification

Add or update Dart unit tests for snapshot replacement helpers:

- [ ] header update preserves pages/assets/elements/lineups
- [ ] pages update preserves unchanged page maps and prunes removed pages
- [ ] strategy-level elements are grouped by page
- [ ] strategy-level lineups are grouped by page
- [ ] deleted elements/lineups remain present in remote data but are ignored during hydration as today

Add or update provider tests:

- [ ] opening a cloud strategy does one full fetch then uses subscription payloads
- [ ] a header update triggers the same rehydration behavior as before
- [ ] an element update on the active page updates remote snapshot without full refetch
- [ ] a lineup update on the active page updates remote snapshot without full refetch
- [ ] page deletion/reorder keeps active page resolution behavior unchanged
- [ ] ack rejection still records a conflict and refreshes/rebases as before

Add Convex tests if the test harness is introduced for this work:

- [ ] `elements:listForStrategy` enforces viewer access
- [ ] `lineups:listForStrategy` enforces viewer access
- [ ] strategy-level queries return page public IDs correctly
- [ ] `strategies:listForFolder` does not expose unauthorized strategies
- [ ] `strategies:listSharedWithMe` returns direct shared strategies
- [ ] folder-shared access still works through inherited folder roles

Run verification commands:

```powershell
npx tsc --noEmit
fvm flutter test test\strategy_page_session_provider_test.dart test\strategy_op_queue_provider_test.dart test\collab_sync_models_test.dart test\cloud_ui_parity_helpers_test.dart
fvm flutter analyze
```

Expected `fvm flutter analyze` result: no errors; pre-existing warnings/infos may remain.

## Acceptance Criteria

- [ ] No visible UI changes.
- [ ] No feature removal.
- [ ] Opening, editing, page switching, collaboration updates, media hydration, conflict handling, and library browsing behave the same as before.
- [ ] Active strategy subscriptions no longer scale with page count.
- [ ] Subscription payloads update local snapshot state directly instead of forcing full snapshot refreshes.
- [ ] Full snapshot refresh remains available for initial load, manual refresh, auth recovery, and error recovery.
- [ ] Cloud library queries no longer scan all strategies or all folders for normal user-scoped views.
- [ ] The saved plan contains a clear deferred note for the sequence/update hot-write concern.

## Assumptions And Defaults

- Scope is data plumbing only.
- Target documentation location is `docs/cloud_sync_refactor/convex_sync_refactor_plan.md`.
- Keep current UI exactly as-is.
- Keep `strategy.sequence` as the remote change clock for this refactor.
- Do not implement digest tables until after indexed query cleanup is measured.
- Preserve current backend function names where possible; only add new functions for better Convex query shapes.
