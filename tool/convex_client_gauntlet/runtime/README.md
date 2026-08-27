# Convex Dart client runtime gauntlet

This package runs the same deterministic Icarus cloud workload through Dartvex
0.2.0 and `convex_flutter` 3.0.1. It targets an isolated local Convex deployment
and uses a disposable Supabase user with the public anon key. Never use or pass a
`service_role` key.

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
