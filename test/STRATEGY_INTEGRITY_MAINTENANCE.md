# Strategy Integrity Tests – Maintenance Guide

Scope: [test/strategy_integrity_test.dart](test/strategy_integrity_test.dart)

## Purpose

These tests protect import/export compatibility and migration correctness for `.ica` strategy data across schema versions.

## When to update these tests

Update in the same PR when any of the following changes:

- Persisted strategy/page fields in [lib/providers/strategy_provider.dart](lib/providers/strategy_provider.dart) or [lib/providers/strategy_page.dart](lib/providers/strategy_page.dart)
- Import/export payload structure in [lib/providers/strategy_provider.dart](lib/providers/strategy_provider.dart)
- Migration logic/version gates in [lib/providers/strategy_provider.dart](lib/providers/strategy_provider.dart) or [lib/migrations/ability_scale_migration.dart](lib/migrations/ability_scale_migration.dart)
- Derived-field recomputation behavior (clamping, defaults, reindexing)
- Deterministic failure behavior for malformed/missing fields

Do not update for UI-only refactors that do not affect serialization.

## Required test changes per behavior change

For each serialization/migration behavior change, add or adjust:

1. **Positive compatibility test** (expected import/migration path)
2. **Round-trip stability test** (`export -> import -> export`)
3. **Negative deterministic test** for malformed/missing data if error behavior changed

Prefer structural assertions; avoid brittle full-text snapshots.

## Fixture policy

- Keep fixtures under `test/fixtures/strategy_integrity/`.
- Keep [base-test.ica](fixtures/strategy_integrity/base-test.ica) as a stable baseline fixture.
- Keep [base-test-v43.ica](fixtures/strategy_integrity/base-test-v43.ica) as the previous-version custom-shape fixture.
- Add new fixtures for significant schema eras, not every release.
- Do not rewrite old fixtures unless corrupted; add new fixtures instead.
- Keep assertions focused on semantic fields (not formatting/order).

## PR checklist

Before merge, verify:

- Legacy fixture import still migrates to current `versionNumber`
- Cross-version consistency remains stable after re-export/re-import
- Derived fields still recompute as expected
- Invalid payload handling remains deterministic

## Local run

Run only the integrity suite:

- `flutter test test/strategy_integrity_test.dart`

## CI recommendation

Run this test file on all PRs that touch:

- `lib/providers/strategy_provider.dart`
- `lib/providers/strategy_page.dart`
- `lib/migrations/**`
- import/export code paths

Treat failures as merge-blocking for compatibility-sensitive changes.
