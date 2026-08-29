# Convex Dart client gauntlet

This isolated Dart package reproduces the compile-time contract gate declared
for Icarus's Convex client comparison. It pins `dartvex` and
`dartvex_codegen` to 0.2.0 without adding either package to the application.

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
