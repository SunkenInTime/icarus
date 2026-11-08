# Convex Dart client rerun: Dartvex 0.3.0

Status: static half complete on 2026-11-08; runtime half planned, not run

Base: `origin/main` at `b1b56044b67e8cef805f1a42150cd4f8938eaf79`

Candidates: Dartvex 0.3.0 (published 2026-11-07) and our fork, `convex_flutter`
3.0.1 vendored with the Icarus patches on Convex Rust 0.10.4

## Why this rerun

In August both clients passed the gauntlet. We kept `convex_flutter` mainly
because Dartvex's generated return types did not cover our functions
([fair rerun](convex_dart_client_fair_rerun_result.md)). Since then upstream
`convex_flutter` has stopped moving, our fork grew a third patch set
(`subscribe_set` and `subscribe_group`, Oct 21), and Dartvex shipped 0.3.0. This
rerun asks the August question again on today's facts.

## Verdict

Don't adopt `dartvex_codegen`. It refuses 11 of our 61 public functions, and for
the other 50 it writes 46 MB of Dart, against 309 KB from our own generator.

That no longer decides the client question, though. ADR 0001 already says
Icarus owns its generator, and that generator targets one small raw transport
interface (`ConvexClientValueSource` in `lib/collab/src/convex_client_types.dart`).
Dartvex can sit under that interface as a plain client, with no Dartvex codegen
involved, and replace both of today's implementations: the Rust bridge on native
and the Convex JS bundle on web.

Recommendation: a hybrid. Keep our generator, and move the transport to the
Dartvex 0.3.0 client once the runtime gauntlet passes for it on today's
protocol. Until that run passes, keep the fork. The steps are at the end of this
doc.

## 1. Compile-time gate on the real spec

The August gate only ran one-function fixtures. The new
`tool/convex_client_gauntlet/bin/full_spec.dart` feeds every public function in
`convex/function_spec.json` to `dartvex_codegen` 0.3.0, one at a time so one
refusal can't hide the rest. Then it generates the whole spec once, and the
spec minus the refused functions with `dart analyze`.

A function counts as typed only when generation exits 0 with no warning and no
public declaration in its module is typed `dynamic`, `Object` or `Object?`.
Dartvex's private `_encode`/`_decode` helpers are skipped, because they never
reach a caller. So is the `value` field on generated enums: it holds the wire
literal, while the result field still has the enum type.

| Result | Count |
| --- | ---: |
| Public functions in the spec | 61 |
| Fully typed, no `dynamic` or `Object?` reaching a caller | 50 |
| Degraded to `dynamic` | 0 |
| Refused, generation exits 70 | 11 |
| Whole spec | refused, exit 70 |
| The 50 typed functions together | 46,366,046 bytes of Dart; `dart analyze` clean in 188 s |

The answer to the deciding question is no. Nothing degrades to `dynamic` any
more, and 0.3.0 is now strict where 0.2.0 failed open. But generation
stops at 11 functions, and the 50 it accepts are not usable bindings.

### What is refused, and why

All 11 refusals have one cause. Each function returns a union of two objects
with no field that tells them apart:

```
pages:add            {ok: true, revision} | {ok: true, reused: true, revision}
strategies:create    {ok: true}           | {ok: true, reused: true}
```

The same shape appears in `folders:create`, `pages:delete`, `pages:rename`,
`pages:reorder`, `pages:restore`, `strategies:createWithInitialPage`,
`strategies:duplicate`, `strategies:move` and `strategies:update`. Dartvex 0.3.0
refuses any union whose members can't be told apart at runtime, unless the
objects share a required literal field with different values. That rule is
right. The second member is a superset of the first, so a decoder can't pick
one safely.

A server change could fix it: declare one object with `reused: v.optional(v.literal(true))`.
It accepts exactly the values the union accepts today. It is still a change to
production return validators, so it belongs in its own PR. Our own generator
doesn't need it.

### Why the typed half is still unusable

Element and lineup payloads use the depth-bounded JSON validator in
`convex/lib/payloadValidators.ts`. `jsonValueValidator1` through `N` stand in
for `v.any()`, which the ADR bans. Dartvex has no way to bind a tagged payload
to an existing Icarus type, so it expands that validator into a sealed class
family at every depth, at every position where a payload appears:

| Function | Generated Dart for that function alone |
| --- | ---: |
| `ops:applyBatch` | 20.7 MB |
| `strategy:getFullSnapshot` | 5.3 MB |
| `page:getSnapshot` | 5.1 MB |
| `page:getElementSlice` | 4.6 MB |
| `elements:listForStrategy` | 4.2 MB |
| `elements:listForPage` | 4.1 MB (126k lines, 4,568 classes) |

Even typed, a payload arrives as a tree of structural JSON classes. A repository
would still convert that tree into `DrawingElement` and friends. That is the
August stop condition: the JSON boundary moves into another wrapper instead of
going away. Our generator handles the same validator through the exact tag
bindings the ADR describes.

The fixture gate (`bin/run.dart`) still passes all six checks on 0.3.0
(`results/contract_gate.json`).

## 2. Runtime comparison: not run, and why

The August runtime harness speaks cloud protocol 5. The server now requires 6
(`convex/lib/cloudProtocol.ts`), and payloads changed with it, so neither
candidate would get past the first `ops:applyBatch` without a workload update.
Worker D is doing that update right now for the gauntlet CI lane. They have
uncommitted changes to `runtime/lib/runner.dart` and `runtime/lib/workload.dart`,
plus `runtime/tool/run_with_local_deployment.mjs`. That script runs the workload
under `flutter test` against a throwaway local deployment, with tokens it mints
itself, and takes `GAUNTLET_ADAPTER` and `GAUNTLET_PORT`. Writing a second
protocol-6 workload beside theirs would mean two copies to keep in sync, so I
left `runtime/` untouched.

Plan, once D's harness lands:

1. Bump `runtime/pubspec.yaml` to `dartvex: 0.3.0` and fix `DartvexTransport`
   for the 0.3.0 breaks that touch it: auth methods on a closed client now
   return failed futures, and `authTokenType` must be `User` or `Admin`.
2. On Windows, run correctness for both candidates with the August settings (50
   seeds of 1,000 ops, with checkpoint and restart), port 3510, data replaced
   between candidates. Both must pass every August condition before any timing
   counts.
3. For timing, run the 10 paired profile trials on Dara's Mac with
   `run_paired_profile.sh`, so the numbers sit next to August's. Windows
   `flutter test` runs are debug JIT and don't compare with August's macOS
   profile builds.
4. Add two checks August didn't have, both for the hybrid:
   - The microtask grouping that `convex_client_web.dart` uses for
     `subscribeValues`, run over Dartvex, never delivers values from two server
     states. This includes the case where one query of the group is seeded from
     Dartvex's after-unsubscribe cache (see the table below).
   - A mutation in flight during a sign-out and sign-in fails with a
     `ConvexException`, and the outbox replays it instead of dropping it.

## 3. What the numbers don't show

ADR 0001 asks four things of a raw client. I read the Dartvex 0.3.0 source
(`lib/src/client.dart`, `exceptions.dart`, `sync/base_client.dart`) against
each. Nothing in this table has been seen at runtime yet.

| ADR requirement | Dartvex 0.3.0 | Fork today |
| --- | --- | --- |
| Structured error code on both transports | `ConvexException.data` and `QueryError.data` carry the server's `ConvexError` payload. `data['code']` is where our native adapter reads `rawCode` today. One client means one mapping for native and web. | Native reads `data['code']` from the Rust error. Web reads the JS error object. Two mappings, kept equal by conformance tests. |
| Consistent multi-query delivery (`subscribeValues`, `watchTogether`) | No grouped-subscribe API. It does deliver every query update from one server transition synchronously: `StreamController.broadcast(sync: true)` plus `addSync`, in one loop in `_handleServerMessage`. Our web adapter already relies on that from the JS client, so its microtask grouping should carry over. One gap: a new subscription's first value may come from the after-unsubscribe cache, which can be older than the other queries in the group. That needs the plan's step 4 test, or an upstream option to skip the cache seed. | `subscribe_group` in our patched Rust crate calls Dart once per transition. That is the strongest guarantee of the three, and it is fork-only code. |
| Real reconnect | `reconnectNow(reason)` restarts the socket through `WebSocketManager` and replays auth, the query set and pending requests. | `reconnect_now` is an Icarus patch on Convex Rust 0.10.4. Upstream has no such call. |
| Auth refresh inside the client state machine | `setAuthWithRefresh` hands the fetcher to `AuthManager`, which refetches on a server auth rejection and retries the fetch after 500 ms and 2 s. 0.3.0 also changed this: a mutation in flight during an identity change (sign-out, another user) now fails instead of being replayed under the new user, while same-user token refreshes keep results. Our outbox replays by op ID, so a failed in-flight mutation should be safe, but step 4 has to prove it. | Our Aug 27 patches to both the package and the crate. |

### Web

Dartvex is pure Dart and picks a `package:web` WebSocket on web
(`transport/ws_web.dart`). A minimal client that subscribes, reads
`QueryError.data`, and calls `reconnectNow` compiles with `dart compile js -O2`
to 251 KB. That's a standalone program, not tree-shaken with our app. I did
not run it in a browser. Today the web build ships
`web/convex.browser.bundle.js` (163 KB) behind a 550-line `dart:js_interop`
binding. The binding needs its own checker, `tool/check_convex_web_binding.mjs`,
because a member missing from the bundle compiles fine and only throws in the
browser. A web build once called `clearAuth`, which the browser client doesn't
have. One Dart client for both platforms removes that whole class of bug, and
makes the ADR's transport conformance suite compare a client with itself.

### Maintenance

| | Dartvex | `convex_flutter` upstream | Our fork |
| --- | --- | --- | --- |
| Last release | 0.3.0, 2026-11-07 | 3.0.1, 2026-02-23 | not published |
| Activity | 485 commits, the latest 100 between Jun 11 and Nov 7; 8 issues and PRs, all closed; tracks the official JS client (0.3.0 matches `convex` 1.49.0, and an issue opens automatically on protocol drift) | 1 commit since Feb 27 (an Oct 26 version bump, never published); PR #20 (Convex Rust 0.10.4) open since May; #18 "3.0.1 has broken TLS on iOS/Android" open since March | 6 commits (Aug 27 and Oct 21) |
| People | one maintainer (all 485 contributions), 14 stars | 34 stars, outside PRs stalled | us |
| What we carry | nothing today; pinned versions if adopted | — | a Flutter package, a patched Rust crate, a generated FRB 2.11.1 bridge, and a cargo build per platform |

Dartvex depends on one person. The fork depends on us, and the fork is Rust plus
a code-generated bridge. If Dartvex stalls, 11.7k lines of Dart is a far
cheaper fork than what we carry now. Worker F's upstreaming of our Convex Rust
fixes shrinks the fork's crate half but leaves the package and bridge.

### August's performance numbers

August measured the fork 32% faster on runner wall time and 34% faster on
reconnect-to-live (73 vs 111 ms median). Dartvex used 36% less CPU and 13% less
transfer, and remote convergence was equal (7.3 vs 7.5 ms). Runner wall time is
the harness's total, not something a user waits on. None of these gaps is one a
user would notice, so performance doesn't decide this. The rerun in step 3
checks that 0.3.0 hasn't regressed.

## What moving the transport would take

1. Runtime gauntlet steps 1 to 4 above pass for Dartvex 0.3.0.
2. One `DartvexValueSource implements ConvexClientValueSource` replaces
   `convex_client_native.dart` and `convex_client_web.dart`.
   `subscribeValues` uses the web adapter's microtask grouping. Errors map from
   `data['code']`.
3. The transport conformance tests and the drive scripts pass on Windows, macOS
   and web. Sign-in, sign-out and an offline-then-online edit are seen in a
   running build.
4. Staged rollout, since this is the sync path. Then delete
   `third_party/convex_flutter`, `third_party/convex_rs`, the FRB pin,
   `web/convex.browser.bundle.js` and `check_convex_web_binding.mjs`.

## Reproduce

```bash
cd tool/convex_client_gauntlet
dart pub get
dart run bin/run.dart --output results/contract_gate.json
dart run bin/full_spec.dart --analyze --output results/full_spec_gate.json
dart test
```

`full_spec.dart` takes about 40 s, plus about 3 minutes with `--analyze`.
Measured on Windows x64, Dart 3.12.2. The scrubbed spec has no `url` key, which
`dartvex_codegen` requires, so the tool adds a placeholder. Dartvex copies the
URL only into a comment.

## Artifacts

- [`full_spec_gate.json`](../../tool/convex_client_gauntlet/results/full_spec_gate.json):
  per-function status, refusal text and generated size
- [`contract_gate.json`](../../tool/convex_client_gauntlet/results/contract_gate.json):
  fixture gate, now on 0.3.0
