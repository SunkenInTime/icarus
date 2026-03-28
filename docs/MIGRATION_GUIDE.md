# Migration Guide

## Hive schema changes

When changing Hive-backed models, do not remove old persisted fields just because the app has a newer shape.

Preferred pattern:
- keep the old field on the model
- mark it `@Deprecated(...)` so the linter warns on new usage
- add the new field alongside it
- normalize between the old and new shapes in the constructor or `copyWith`

Reference example:
- [lib/providers/strategy_provider.dart](E:/Projects/icarus/lib/providers/strategy_provider.dart)

`StrategyData` already follows this pattern for old page-level fields like `agentData`, `abilityData`, and `strategySettings`.

## Important codegen note

For Hive CE in this repo, codegen will only preserve old field indexes if the field still exists in the schema history.

That means:
- removing a field from the model can cause old Hive data to stop deserializing
- simply re-adding the field later may not restore its original field index automatically

If a legacy field must keep its historical Hive index, preserve that history in:
- [lib/hive/hive_adapters.g.yaml](E:/Projects/icarus/lib/hive/hive_adapters.g.yaml)

## Concrete lesson

`StrategyPage.lineUps` must remain as a deprecated persisted field for Hive compatibility, even though `lineUpGroups` is the preferred runtime shape.

If this field is removed, old Hive saves with lineup data at the legacy field index will load without that data.
