# Convex Dart client gauntlet

This isolated Dart package reproduces the compile-time contract gate declared
for Icarus's Convex client comparison. It pins `dartvex` and
`dartvex_codegen` to 0.3.0 without adding either package to the application.

Run the repaired compile-time contract gate and its regression test from this
directory:

```bash
fvm dart pub get
fvm dart run bin/run.dart
fvm dart test
```

The gate uses an explicit return schema and an Icarus-owned strict wrapper. The
wrapper rejects Dartvex warnings and public methods that degrade to a
`dynamic` result. The result-rename fixture changes only `publicId` to
`folderPublicId`, so the unchanged caller proves the generated return type at
analysis time.

## The real spec

`bin/full_spec.dart` runs `dartvex_codegen` over every public function in
`convex/function_spec.json`, one function at a time, and reports each one as
typed, degraded (a `dynamic` or `Object?` reaches the caller) or refused. With
`--analyze` it also analyzes the bindings for every accepted function, which
takes minutes:

```bash
dart run bin/full_spec.dart --analyze --output results/full_spec_gate.json
```

The 0.3.0 result is in
[`convex_dart_client_dartvex_0_3_rerun_result.md`](../../docs/cloud_sync_refactor/convex_dart_client_dartvex_0_3_rerun_result.md).
