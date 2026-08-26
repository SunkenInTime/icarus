# Convex Dart client contract gate

This isolated Dart package reproduces the compile-time contract gate declared
for Icarus's Convex client comparison. It pins `dartvex` and
`dartvex_codegen` to 0.2.0 without adding either package to the application.

Run the evaluation and its regression test from this directory:

```bash
fvm dart pub get
fvm dart run bin/run.dart
fvm dart test
```

The runtime chaos and profile stages are intentionally absent. The handoff
requires them to stop when generated public results remain `dynamic`.
