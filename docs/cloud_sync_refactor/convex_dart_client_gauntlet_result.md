# Convex Dart client gauntlet result

Status: first gate recorded; runtime decision reopened on 2026-08-26

Base: `origin/icarus-cloud` at
`e59402eedee9035cf14693fbd26fe8b097d6abfa` on 2026-08-26

Candidate versions: `dartvex` 0.2.0 and `dartvex_codegen` 0.2.0

Decision: no client winner yet

## Fairness correction

The first gate found a real fail-open strictness gap in Dartvex 0.2.0, but its
result-field leg regenerated the baseline fixture instead of exercising a
renamed result fixture. Because that baseline declares `returns: null`, it
could not test whether a typed generated caller catches result drift.

A diagnostic control with an explicit object return passed baseline analysis
and then failed analysis with exit 3 after `publicId` was renamed to
`folderPublicId`. The runtime comparison still has not run. The corrected,
authoritative next-step plan is
[convex_dart_client_fair_rerun_handoff.html](convex_dart_client_fair_rerun_handoff.html).

## Result

The original run stopped at the compile-time contract gate and therefore did
not run the runtime chaos or profile stages. Treat that stop as a recorded
strictness finding, not as a final package verdict.

The stable `folders:listForParent` function declares argument validators but
no `returns:` validator. Convex represents that result as `returns: null` in a
function spec. Dartvex 0.2.0 deliberately maps the absent result contract to
`Future<dynamic>`. A caller that reads `result.first.publicId` still passes Dart
analysis. The committed runner did not actually rename a result field, so this
observation does not establish whether a complete generated return type catches
that change.

Dartvex also treats an unknown validator as a warning and generates the
affected field as `dynamic`. Generation exits zero instead of stopping at the
function and field path.

These are declared losing conditions in the comparison plan. They are not
performance observations and cannot be averaged away.

| Contract check | Required | Observed | Result |
| --- | --- | --- | --- |
| Function rename | Old method fails analysis | Analysis exits 3 | Pass |
| Argument rename | Old named argument fails analysis | Analysis exits 3 | Pass |
| Result-field rename | Old field access fails analysis | No result rename was exercised; baseline return is `dynamic`; analysis exits 0 | **Invalid leg** |
| Unsupported validator | Generation exits nonzero with a path | Warning with path; generation exits 0 and emits `dynamic` | **Fail** |
| Second generation | No repository diff | No generated-file change | Pass |

## Reproduce

The evaluation lives in an isolated Dart package so the rejected candidate is
not added to the Icarus application or its lockfile.

```bash
cd tool/convex_client_gauntlet
fvm dart pub get
fvm dart run bin/run.dart
fvm dart test
fvm dart analyze
```

The committed machine-readable result is
[`tool/convex_client_gauntlet/results/contract_gate.json`](../../tool/convex_client_gauntlet/results/contract_gate.json).
The runner regenerates bindings for the baseline, function-rename,
argument-rename, and unsupported-validator fixtures and compiles the same old
caller after each relevant change.

## Runtime stage

Skipped by the comparison's explicit stop rule:

> If Dartvex generates function names but leaves public results as `dynamic`,
> stop the runtime comparison and record that gap before writing new generator
> code.

Consequently, this result makes no claim about Dartvex runtime correctness,
latency, memory, reconnect behavior, auth recovery, or platform builds. The
recorded counts are zero because the runtime workload was not started, not
because either client completed it without faults.

No client abstraction, adapter, application migration, custom generator,
production deployment, local Hive model, `.ica` format, outbox, revision rule,
or server payload changed in this comparison.

## Refreshed baseline

Before the gate, the refreshed cloud base passed:

- `npm ci` (with the existing npm audit report of 4 dependency
  vulnerabilities: 2 moderate, 1 high, 1 critical)
- `npx tsc --noEmit`
- `npm run test:convex` (22 tests)
- the six focused Flutter files named by the two handoffs (82 tests)

After recording the decision, the comparison branch passed:

- `fvm dart test` in `tool/convex_client_gauntlet` (1 test)
- `fvm dart analyze` in `tool/convex_client_gauntlet` (no issues)
- `npx tsc --noEmit`
- `npm run test:convex` (22 tests)
- `fvm flutter test` (343 tests)
- `fvm flutter analyze --no-fatal-infos` (exit 0 with the same 6
  pre-existing info-level lints)
- `fvm flutter build web --no-tree-shake-icons`

The exact `fvm flutter build web` command still fails on the refreshed base's
three existing non-constant `IconData` sites in `folder_provider.dart`,
`hive_adapters.g.dart`, and `archive_manifest.dart`. This comparison does not
change those files. Disabling icon tree shaking proves the web target otherwise
compiles; the pre-existing release-build cleanup remains separate work.

The next comparison may add explicit public result validators and a thin,
Icarus-owned strict wrapper that rejects warnings and unexpected `dynamic`.
Writing a replacement generator or package fork remains out of scope until that
smaller compensation is tested.
