# Convex Dart client runtime gauntlet

This package runs the same deterministic Icarus cloud workload through Dartvex
0.2.0 and the Icarus-repaired `convex_flutter` 3.0.1 package. It targets an
isolated local Convex deployment and uses a disposable Supabase user with the
public anon key. Never use or pass a `service_role` key.

Each correctness candidate is configured for 50 seeds of 1,000 operations. The
trace includes offline queuing, delay, duplicate delivery, subscription restart,
rejected-token refresh, reconnect, revision conflicts, delete/recreate cycles,
and a persisted mid-run process checkpoint. A fresh Dartvex client performs the
canonical final-state and `.ica` round-trip verification.

## Verify and build

```sh
fvm dart format --output=none --set-exit-if-changed lib app/lib test tool
fvm dart analyze
fvm flutter test test/workload_test.dart
cd app
fvm flutter analyze
fvm flutter build macos --debug
```

The nested macOS app is required because `convex_flutter` loads its native Rust
bridge from the application bundle. Flutter's unit-test process cannot supply
that framework.

## Run correctness

Start an isolated local deployment from the repository root:

```sh
npx convex dev --codegen disable --tail-logs disable
```

Set `SUPABASE_URL`, `SUPABASE_KEY`, `TEST_EMAIL`, and `TEST_PASSWORD` in the
environment. `SUPABASE_KEY` must be the public anon key. Then, from `app/`, run
each candidate with the same settings:

```sh
export CONVEX_URL=http://127.0.0.1:3210
export ADAPTER=dartvex
export SEED_COUNT=50
export ALLOW_CHECKPOINT=1
export RESET_PROGRESS=1
export REPORT_NAME=icarus-dartvex-runtime-correctness
export GIT_COMMIT=$(git -C ../../../.. rev-parse HEAD)
build/macos/Build/Products/Debug/icarus_convex_runtime_runner.app/Contents/MacOS/icarus_convex_runtime_runner
```

When the runner reports `checkpoint`, run the same command again with
`RESET_PROGRESS=0`. Before switching adapters, replace the isolated deployment
data with the empty fixture, change `ADAPTER` and `REPORT_NAME`, and restore
`RESET_PROGRESS=1`:

```sh
export CONVEX_DEPLOYMENT=
export CONVEX_SELF_HOSTED_URL=http://127.0.0.1:3210
export CONVEX_SELF_HOSTED_ADMIN_KEY=$(jq -r .adminKey ../../../../.convex/local/default/config.json)
npx convex import --replace-all --table users ../../../../tool/convex_client_gauntlet/runtime/fixtures/empty.json -y
```

Correctness reports are written to the app container's temporary directory and
copied verbatim into `results/` after checking that they contain no credentials.
Phase 4 profiling is forbidden unless both candidates pass all correctness
conditions.

## Auth and reconnect repair

The local package at `third_party/convex_flutter` delegates refresh to the
Convex Rust state machine, protects replacement auth handles with a generation,
and exposes a real WebSocket reconnect. It uses the local Convex Rust 0.10.4
crate at `third_party/convex_rs`, whose patch coordinates auth retry across the
client and WebSocket workers while preserving in-flight mutation replay. Read
both `ICARUS_PATCH.md` files before changing this boundary.

Generated Flutter Rust Bridge files were produced with the pinned 2.11.1
generator and must not be edited by hand:

```sh
cd third_party/convex_flutter/rust
flutter_rust_bridge_codegen generate
```

## Run paired profile trials

Only profile after both correctness artifacts pass. Build the native runner in
profile mode, choose an empty temporary output directory, and use the same
disposable public-client environment as correctness:

```sh
cd tool/convex_client_gauntlet/runtime/app
fvm flutter build macos --profile
cd ../../../..

export PROFILE_OUTPUT_DIR=$(mktemp -d /tmp/icarus-convex-profile.XXXXXX)
export CONVEX_URL=http://127.0.0.1:3210
export CONVEX_SELF_HOSTED_ADMIN_KEY=$(jq -r .adminKey .convex/local/default/config.json)
export TRIALS=10
tool/convex_client_gauntlet/runtime/tool/run_paired_profile.sh
```

The script replaces deployment data before every candidate, runs ten pairs,
and alternates first position. Summarize the raw directory with the checked-in
tool; the three byte counts come from the built `.app` bundle and its native
framework executables:

```sh
fvm dart run \
  tool/convex_client_gauntlet/runtime/tool/summarize_paired_profile.dart \
  "$PROFILE_OUTPUT_DIR" \
  "$SHARED_BUNDLE_BYTES" \
  "$CONVEX_FLUTTER_FRAMEWORK_BYTES" \
  "$APP_FRAMEWORK_BYTES" \
  > tool/convex_client_gauntlet/runtime/results/paired_profile_macos.json
```

The summary preserves every raw sample, records the alternating order, and
reports median plus nearest-rank p95. Windows and Linux measurements require
their own hosts; do not infer them from the macOS result.
