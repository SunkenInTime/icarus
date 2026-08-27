# Convex Dart client fair rerun result

Status: correctness complete; profiling blocked on 2026-08-27

Harness commit: `bf421ffef06b5d04749c77bda182f8f0a53796fe`

Candidates: Dartvex 0.2.0 and `convex_flutter` 3.0.1

Decision: Dartvex wins the runtime correctness gate, but neither client has
earned an application migration.

## Verdict

Dartvex completed all 50 deterministic seeds and all 50,000 ops. Every op
resolved: 45,500 landed and 4,500 produced the planned, visible revision
rejects. The fresh Supabase token was accepted after the rejected-token fault,
the queued batch was replayed exactly once, the persisted mid-run checkpoint
resumed, every verifier hash matched, and every `.ica` export round-tripped.

`convex_flutter` hit the handoff's immediate losing condition on seed 0. Its
first 500 ops resolved as expected (450 landed and 50 visible revision rejects),
then the injected credential was rejected. Supabase `refreshSession()` returned
a different access token, but the package did not accept authenticated work
within the bounded 20-second recovery window after the rejected auth state was
cleared, the production-style refresh handle was replaced, and its public
reconnect path was exercised. The queued batch therefore could not be proven to
land exactly once.

The application dependency remains unchanged. A correctness survivor is not
automatically an adoption winner: the repaired Dartvex contract gate proves a
narrow strict wrapper around one explicit `folders:listForParent` result, but
the runtime adapter still uses path-and-JSON calls because the stable generated
return surface for the runtime functions is not complete. Migrating now would
claim the JSON-plumbing benefit before proving it.

## Fair workload

Both adapters used the same local Convex deployment, disposable client account,
public Supabase anon credential, base fixture, serialized op traces, IDs,
timeouts, and fault schedules. The seed-0 trace and schedule hashes match:

- trace: `ddf6d41ed9ccdbf3c60766fe6b0318218dd8954d8615fcffb2a8daefe849aa06`
- fault schedule:
  `b4e244c38b89789f1191e988768aa681f4722184533077ef58eb6f95ee6a0e52`
- base fixture:
  `test/fixtures/strategy_integrity/base-test-v43.ica`, SHA-256
  `8544873d608a0ad885b2e6042a383596a0b1dc37514034281b4e4eec6168756a`

The 1,000-op trace covers strategy, page, page content, element, and lineup
changes, including add, patch, reorder, delete/recreate, duplicate delivery,
revision conflicts, subscription restart, reconnect, offline delay, auth
rejection/refresh, and durable process restart. A new Dartvex client acts as
verifier C. Canonical state excludes server-authored transport clocks, including
page-content creation/update clocks; a regression test proves those clocks
cannot create a false state mismatch.

## Separate scorecards

| Area | Dartvex 0.2.0 | `convex_flutter` 3.0.1 |
| --- | --- | --- |
| Explicit result rename | Old field access fails analysis | Hand-written decoding |
| Missing return | Icarus strict wrapper rejects public `dynamic` | Not applicable |
| Unsupported validator | Wrapper converts generator warning/exit 0 into failure/exit 2 | Not applicable |
| Determinism | Identical generated SHA-256 on two runs | Not generated |
| Runtime correctness | **Pass: 50/50 seeds, 50,000/50,000 ops** | **Fail: auth recovery at seed 0, op 500** |
| Rejected-token refresh | Fresh token accepted; queued batch lands once | Fresh token not accepted in 20 seconds |
| Restart recovery | Persisted checkpoint resumes | Not reached |
| Canonical and `.ica` verification | Pass on all 50 seeds | Not reached |
| Dependency health | Pure Dart client plus strict tooling package | Native bridge had to pin `flutter_rust_bridge` 2.11.1 instead of resolved 2.13.0 |
| Generated Icarus surface | Incomplete for runtime functions | None |

The Dartvex correctness run recorded 20,224,618 application-JSON bytes sent,
48,117,804 received, 64,794.127 ms wall time, and 260,472,832 bytes maximum
RSS. These are correctness-run observations, not comparative performance
claims. There is no valid `convex_flutter` completion sample to pair with them.

## Why Phase 4 did not run

The handoff permits profiling only after both clients complete all correctness
seeds with canonical equality. `convex_flutter` failed before completing seed
0, so paired profile runs, CPU comparison, build-size comparison, and
cross-platform performance builds are intentionally recorded as zero/not run.
Running them anyway would let speed distract from uncertain queued work.

## Artifacts and reproduction

The historical first result remains unchanged at
[`convex_dart_client_gauntlet_result.md`](convex_dart_client_gauntlet_result.md).
The fair rerun adds:

- [`contract_gate.json`](../../tool/convex_client_gauntlet/results/contract_gate.json)
- [`dartvex_correctness.json`](../../tool/convex_client_gauntlet/runtime/results/dartvex_correctness.json)
- [`convex_flutter_correctness.json`](../../tool/convex_client_gauntlet/runtime/results/convex_flutter_correctness.json)
- [`fair_rerun_matrix.json`](../../tool/convex_client_gauntlet/runtime/results/fair_rerun_matrix.json)
- [runtime commands](../../tool/convex_client_gauntlet/runtime/README.md)

The raw correctness artifacts contain no email, password, access token, refresh
token, Supabase key, or elevated credential. The deployment was the isolated
local instance at `127.0.0.1:3210`; no production or user library data was used.

## Repository verification

After writing the result artifacts, the branch passed:

- the repaired Dartvex gate, its 2 Dart tests, and Dart analysis;
- runtime-gauntlet formatting, Dart analysis, and all 3 deterministic workload
  tests (the separately invoked live-deployment smoke test is skipped without a
  deployment define);
- native runner analysis and a macOS debug build;
- `npx tsc --noEmit` and all 22 Convex tests;
- all 343 Flutter tests;
- Flutter analysis with exit 0 and the same 6 pre-existing info-level lints;
- `fvm flutter build web --no-tree-shake-icons`.

## Next step

Keep the application unchanged for now. Dartvex is the only runtime-surviving
candidate, so any next client evaluation should focus narrowly on completing
explicit return validators and proving that its generated API materially
removes Icarus JSON plumbing without becoming a second generator or package
fork. Independently, `convex_flutter` auth recovery needs a package-level fix
or replacement before it can re-enter this comparison.
