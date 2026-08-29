# Convex Dart client fair rerun result

Status: complete on 2026-08-27

Harness and repair commit: `fb83488c0924f8daf57c4bdfc48d7a4a5ff0c8f5`

Candidates: Dartvex 0.2.0 and `convex_flutter` 3.0.1 with the Icarus auth and
reconnect repair

Decision: keep `convex_flutter`; do not migrate to Dartvex.

## Verdict

The earlier “Dartvex wins” statement was not a fair final verdict. Dartvex had
passed while `convex_flutter` was blocked by a package auth defect, so the run
had identified a broken candidate rather than measured two valid candidates.

That defect is now fixed at the package and Rust-client layers. Both candidates
completed all 50 deterministic seeds and all 50,000 ops. Each recorded 45,500
landed ops, 4,500 planned visible revision rejects, zero unresolved ops, exact
once-only replay after auth refresh, durable checkpoint recovery, 50 matching
canonical verifier hashes, and 50 successful `.ica` round-trips.

There is therefore no correctness winner. In the valid paired profile,
`convex_flutter` was 31.9% faster by median runner wall time and 34.0% faster on
real reconnect-to-live time. Dartvex used 5.1% less peak RSS, 36.4% less CPU in
relative terms (5.29 percentage points), and 12.9% less transfer than
`convex_flutter` (14.9% more when expressed from the Dartvex baseline). Remote
convergence differed by only 0.156 ms at the median.

Those are trade-offs, not a blanket performance winner. Icarus should keep its
current client because Dartvex's stable generated return surface is still
incomplete for the runtime functions, so migrating would not yet remove the
path-and-JSON boundary that motivated the evaluation. The cost is explicit:
the current repair vendors both `convex_flutter` and Convex Rust 0.10.4 until
equivalent fixes are published upstream.

## Auth repair

The failure had four interacting causes:

- the published Flutter adapter owned a separate token-expiry timer and fed the
  Rust client static auth, outside the state machine that replays auth,
  subscriptions, and in-flight mutations after reconnect;
- disposing an old refresh handle could asynchronously clear a newer auth
  callback;
- the public native `reconnect()` method was an authenticated health query, not
  a socket transition;
- Convex Rust applied independent client-worker and WebSocket network backoffs
  to one auth rejection. A fresh token could sit behind a 15-second backoff,
  while stale responses and connection metadata could start further protocol
  recovery loops.

The repair gives the token callback to the upstream Convex state machine, adds
generation ownership to auth handles, implements a real reconnect that waits
for connecting then connected, and patches Convex Rust to preserve one session
identity with monotonic connection counts. Auth rejection now uses a bounded
250 ms callback cadence, coordinates that state with the WebSocket worker so it
does not add a second network backoff, discards responses from the replaced
socket, and only exits auth recovery after a changed token receives a valid
server response.

Ten consecutive debug calibration runs passed before the authoritative rerun.
In the final profile samples, `convex_flutter` accepted the refreshed token in
73.848–171.027 ms; all queued work landed exactly once.

## Fair workload

Both adapters used the same isolated local Convex deployment, disposable client
account, public Supabase anon credential, base fixture, serialized op traces,
IDs, timeouts, and fault schedules. The seed-0 trace and schedule hashes match:

- trace: `ddf6d41ed9ccdbf3c60766fe6b0318218dd8954d8615fcffb2a8daefe849aa06`
- fault schedule:
  `b4e244c38b89789f1191e988768aa681f4722184533077ef58eb6f95ee6a0e52`
- base fixture:
  `test/fixtures/strategy_integrity/base-test-v43.ica`, SHA-256
  `8544873d608a0ad885b2e6042a383596a0b1dc37514034281b4e4eec6168756a`

The 1,000-op trace covers strategy, page, page content, element, and lineup
changes, including add, patch, reorder, delete/recreate, duplicate delivery,
revision conflicts, subscription restart, real reconnect, offline delay, auth
rejection/refresh, and durable process restart. A clean Dartvex client acts as
verifier C. Canonical state excludes server-authored transport clocks.

## Correctness

| Result | Dartvex | `convex_flutter` repaired |
| --- | ---: | ---: |
| Seeds | 50/50 | 50/50 |
| Operations | 50,000/50,000 | 50,000/50,000 |
| Landed | 45,500 | 45,500 |
| Planned visible rejects | 4,500 | 4,500 |
| Unresolved | 0 | 0 |
| Refreshed token accepted | yes | yes |
| Queued auth-fault batch landed once | yes | yes |
| Persisted checkpoint resumed | yes | yes |
| Canonical verifier and `.ica` round-trip | 50/50 | 50/50 |

The debug correctness reports recorded 64,346.843 ms total runner wall time and
256,311,296 bytes maximum RSS for Dartvex, versus 74,446.106 ms and 266,141,696
bytes for `convex_flutter`. These prove completion but are not used as the
performance comparison; the paired profile build below is authoritative for
that.

## Paired macOS profile

Ten paired profile-build trials were run per candidate, alternating which
candidate ran first and replacing deployment data before every run. CPU is
defined as process user plus system seconds divided by the runner's wall-clock
window. P95 uses nearest rank, so with ten samples it is the maximum observed
sample.

| Metric | Dartvex median / p95 | `convex_flutter` median / p95 |
| --- | ---: | ---: |
| Remote convergence | 7.304 / 7.804 ms | 7.459 / 7.575 ms |
| Reconnect to live | 110.893 / 150.191 ms | 73.243 / 94.765 ms |
| Fresh token accepted | 9.144 / 9.662 ms | 127.134 / 171.027 ms |
| Full auth recovery | 147.883 / 166.973 ms | 205.734 / 543.221 ms |
| Runner wall time | 2,749.544 / 3,396.189 ms | 1,873.387 / 2,312.830 ms |
| Peak RSS | 134,406,144 / 134,856,704 B | 141,312,000 / 141,541,376 B |
| Average process CPU | 9.248% / 10.118% | 14.533% / 15.306% |
| Application JSON transfer | 1,439,001 / 1,439,001 B | 1,652,716 / 1,771,501 B |

The shared universal macOS harness bundle is 78,540,800 bytes and contains both
adapters, so candidate-isolated bundle size is not available. The
`convex_flutter` native framework executable is 23,195,280 bytes; the shared App
framework executable is 8,000,528 bytes. The build contains arm64 and x86_64
slices and ran on an arm64 Mac. Windows and Linux remain package-supported but
could not be built or measured from this macOS host; they are recorded as
unmeasured rather than silently generalized.

## Separate scorecards

| Area | Dartvex 0.2.0 | `convex_flutter` repaired |
| --- | --- | --- |
| Runtime correctness | pass | pass |
| Rejected-token recovery | pass | pass after package/Rust repair |
| Real reconnect | pass | pass after replacing health-query implementation |
| Median wall time | slower | faster |
| CPU, RSS, transfer | lower | higher |
| Generated contract boundary | strict wrapper passes, runtime return surface incomplete | none; hand-written JSON boundary |
| Maintenance | pure Dart package plus local strict gate | vendored Flutter package, Rust crate, generated bridge, and pinned FRB 2.11.1 |

## Artifacts

- [`contract_gate.json`](../../tool/convex_client_gauntlet/results/contract_gate.json)
- [`dartvex_correctness.json`](../../tool/convex_client_gauntlet/runtime/results/dartvex_correctness.json)
- [`convex_flutter_correctness.json`](../../tool/convex_client_gauntlet/runtime/results/convex_flutter_correctness.json)
- [`paired_profile_macos.json`](../../tool/convex_client_gauntlet/runtime/results/paired_profile_macos.json)
- [`fair_rerun_matrix.json`](../../tool/convex_client_gauntlet/runtime/results/fair_rerun_matrix.json)
- [runtime commands](../../tool/convex_client_gauntlet/runtime/README.md)
- [`convex_flutter` patch notes](../../third_party/convex_flutter/ICARUS_PATCH.md)
- [Convex Rust patch notes](../../third_party/convex_rs/ICARUS_PATCH.md)

The raw artifacts contain no email, password, access token, refresh token,
Supabase key, Convex admin key, or elevated credential. The deployment was the
isolated local instance at `127.0.0.1:3210`; no production or user library data
was used.

## Verification

- The contract gate passed all six checks; its two regression tests and Dart
  analysis passed.
- The runtime harness passed four workload tests, with the environment-gated
  transport smoke test skipped, and both the runtime and nested app analyzed
  cleanly.
- The Icarus suite passed all 343 tests, including all 15 auth-provider tests.
  TypeScript analysis passed and the 22 Convex boundary tests passed.
- The Icarus app analyzed with six pre-existing info lints and no warning or
  error. Web and macOS release builds passed with icon tree shaking disabled;
  the macOS app bundle was 97.8 MB.
- Convex Rust passed all 36 tests. The native Flutter package passed Cargo
  check/test, and its Dart `lib/` analyzed with no warning or error.
- All four checked-in JSON artifacts parse, their recorded SHA-256 values
  match, the final diff has no whitespace errors, and the artifact secret scan
  passed.

## Next step

Keep `convex_flutter`, upstream the package and Convex Rust repairs, and remove
the local vendors when published releases pass this same gate. Dartvex can be
reconsidered after its stable generated return surface covers the actual Icarus
runtime boundary and proves that a migration removes JSON plumbing instead of
moving it into another wrapper.
