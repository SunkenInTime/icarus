# Convex Dart client rerun: Dartvex 0.3.0

Status: static half complete on 2026-11-08; runtime half run on 2026-11-10
(section 4)

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
public declaration in its module is typed `dynamic`, `Object` or `Object?`. That
includes every field of the record typedefs Dartvex writes for result and
argument objects. Dartvex's private `_encode`/`_decode` helpers are skipped,
because they never reach a caller. So is the `value` field on generated enums:
it holds the wire literal, while the result field still has the enum type.
`test/full_spec_gate_test.dart` proves the scan catches a nested `v.any()`,
which Dartvex turns into `dynamic` without a warning.

"Typed" covers arguments and successful results only. A failed subscription
still hands callers `TypedQueryError.data`, which Dartvex's generated
`runtime.dart` declares `Object?`. That's the server's `ConvexError` payload,
and our own `ConvexClientFunctionError.data` is `Object?` too, until our
generator maps its code to `ConvexErrorCode`.

| Result | Count |
| --- | ---: |
| Public functions in the spec | 61 |
| Arguments and results fully typed | 50 |
| Degraded to `dynamic` | 0 |
| Refused, generation exits 70 | 11 |
| Whole spec | refused, exit 70 |
| The 50 typed functions together | 46,366,046 bytes of Dart; `dart analyze` clean, 188 s with a cold analyzer cache |

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

This is the Nov 8 state. The runtime half ran on Nov 10, in section 4.

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
   - Sign-out and sign-in with a mutation in flight, in two cases. On an
     unbroken socket the mutation may still complete. Across a reconnect it
     fails with `Authentication changed before the request completed`, unless
     the server had already confirmed it. Either way the outbox must end with
     the op landed exactly once or visibly failed, never silently dropped.

## 3. What the numbers don't show

ADR 0001 asks four things of a raw client. I read the Dartvex 0.3.0 source
(`lib/src/client.dart`, `exceptions.dart`, `sync/base_client.dart`) against
each. Nothing in this table has been seen at runtime yet.

| ADR requirement | Dartvex 0.3.0 | Fork today |
| --- | --- | --- |
| Structured error code on both transports | `ConvexException.data` and `QueryError.data` carry the server's `ConvexError` payload. `data['code']` is where our native adapter reads `rawCode` today. One client means one mapping for native and web. | Native reads `data['code']` from the Rust error. Web reads the JS error object. Two mappings, kept equal by conformance tests. |
| Consistent multi-query delivery (`subscribeValues`, `watchTogether`) | No grouped-subscribe API. It does deliver every query update from one server transition synchronously: `StreamController.broadcast(sync: true)` plus `addSync`, in one loop in `_handleServerMessage`. Our web adapter already relies on that from the JS client, so its microtask grouping should carry over. One gap: a new subscription's first value may come from the after-unsubscribe cache, which can be older than the other queries in the group. That needs the plan's step 4 test, or an upstream option to skip the cache seed. | `subscribe_group` in our patched Rust crate calls Dart once per transition. That is the strongest guarantee of the three, and it is fork-only code. |
| Real reconnect | `reconnectNow(reason)` restarts the socket through `WebSocketManager` and replays auth, the query set and pending requests. | `reconnect_now` is an Icarus patch on Convex Rust 0.10.4. Upstream has no such call. |
| Auth refresh inside the client state machine | `setAuthWithRefresh` hands the fetcher to `AuthManager`, which refetches on a server auth rejection and retries the fetch after 500 ms and 2 s. 0.3.0 also changed this. After an identity change (sign-out, another user), a mutation that hasn't completed by the next reconnect fails instead of being replayed under the new user. A mutation the server already confirmed is kept (`request_manager.dart`, `prepareReconnect`). Same-user token refreshes keep results. Our outbox replays by op ID, so a failed mutation should be safe, but step 4 has to prove it. | Our Aug 27 patches to both the package and the crate. |

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

## 4. Runtime run, 2026-11-10

This section asks whether moving the desktop transport to Dartvex would end
the bugs we keep fixing in our patched Rust client: [#512][512], [#514][514],
[#530][530] and [#532][532]. Every one of them was in how the Rust worker
orders a send against a failing socket or an auth change.

A throwaway test program drove each client directly, the way Icarus uses it.
Auth goes through a refresh callback and is followed by a reconnect, as
`lib/providers/auth_provider.dart` does on every auth setup. It ran against a
local deployment made from `convex/` on `main`, plus a probe module that counts
how many times each save or action actually ran, through a proxy that drops
sockets or delays replies. The clients were Dartvex 0.3.0, our client from `main` at f3d4a47a with all
four fixes, and two older builds of ours: 72887a96, before #512 and #514, and
d15a9c96, before #530 and #532. Everything ran on Windows 11 under
`flutter test`, debug JIT, Dart 3.12.2. "Ran once" is the server's count.

| Scenario | Our client, without the fix | Our client on `main` | Dartvex 0.3.0 |
| --- | --- | --- | --- |
| Action's answer reaches the old socket while the app redoes auth and reconnects (#512) | ran twice, on 72887a96 | ran once, caller gets it | ran once; caller told `Connection lost while action was in flight`, marked retryable |
| Same, for a save | not run | ran once, caller gets it | ran once; caller told `Authentication changed before the request completed`. Fine when the token is pushed with `updateAuthToken` instead |
| Token the server always refuses, 60 s, then the user signs in again (#514) | 236 sockets; never reported signed out, on 72887a96 | 11 to 13 sockets; signed out reported at 3.3 s; the held save times out for its caller at 30 s, then runs once after sign-in | 5 sockets, then stays connected signed out; reported at 0.2 s; the held save goes out signed out and the server refuses it with `UNAUTHENTICATED` |
| Save and subscribe sent 0 to 7 ms after the socket dies (#530, #532) | 2 of 84 saves told `channel closed` although they ran, on d15a9c96 | 0 of 120 | 0 of 84; median save 1,039 ms, against our 116 to 139 ms |
| Save answered, answer lost with the socket | not run | ran once, 138 ms | ran once, 1,087 ms |
| Save lost on the way, socket drops | not run | ran once, 153 ms | ran once, 1,504 ms |
| Subscribe lost with the socket | not run | first value at 211 ms; cancel removes it on the server | 625 ms; cancel removes it |
| Sign in as another user with a save in flight, same socket | not run | ran once as the first user | same |
| Same, across a reconnect | not run | ran once as the first user, caller gets it | ran once; caller told `Authentication changed before the request completed` |
| 20 s tokens refreshed for 75 s, a save every 2 s | not run | 37 of 37; waits for expiry, then 3 refusals and reconnects; slowest save 237 ms | 38 of 38; refreshes 10 s early on the same socket; slowest 23 ms |
| Grouped read of two queries under 40 writes | not run | never mixed | never mixed |
| Grouped read, one query first answered from the cache of a cancelled subscription while the other is live | not run | never mixed | mixed, count 0 beside a list of 3, in 2 of 2 runs |
| 5 live queries, a save every 500 ms, 3 min | not run | save median 17 ms, p95 22; 286 ms CPU a minute; 134 to 144 MB | 18 ms, 23; 349 ms CPU a minute; 130 to 139 MB |
| Comparison gauntlet, 50 seeds of 1,000 ops, process restart at seed 25 | not run | pass; 221 s; reconnect-to-live median 56 ms | pass after the runner change below; 220 s; 109 ms. Same final state and `.ica` hash as ours in all 50 seeds |

The harness reproduced three of the four bugs on builds without their fix:
#512, #514 and #530. #532 never fired in 84 rounds on a build without it.
Dartvex showed none of the three, with no patches. On `main` our client
passes everything above too, so the question is the next bug of this kind,
not a current one.

The CPU numbers flatter our client. Under debug JIT Dartvex runs as
unoptimized Dart, while our client's Rust is a release build. Our client also calls every
subscriber on every server update, 1,751 callbacks for 349 changes. Dartvex
made 349.

Once, during the refused-token run's re-sign-in, a subscriber on our client
saw 1, then 0, then 1 within 3 ms. A rerun with the server's values logged
showed only in-order values, so I can't say whether the server or the client
sent the old one.

### What Dartvex would change for Icarus

1. **Auth refresh.** Icarus redoes the whole auth setup and reconnects on
   every token refresh. Dartvex treats that as a change of user, so any save
   or action in flight fails even when the server ran it. The adapter has to
   push a same-user token with `updateAuthToken`. A real change of user still
   fails work in flight; the op queue resends by op ID and the server answers
   it as a replay, so nothing is lost, but each one counts as a failure.
2. **Refused token.** Dartvex gives up in 0.2 s and sends what it holds signed
   out. The op queue keeps a batch that fails with `UNAUTHENTICATED` and raises
   the signed-out prompt, near line 2319 of `strategy_op_queue_provider.dart`.
   I read that code; I didn't run it. The gauntlet requires a batch sent under a refused
   token to land without a resend, which is how our client behaves. Dartvex
   passed only after I relaxed that check in a scratch copy, so that a batch
   the client answered with an error passes if the runner's next send applies
   it.
3. **Grouped reads.** A page's frame and slices arrive through
   `subscribeValues`. With the web adapter's grouping over Dartvex, a group
   mixed two server states when one query came from Dartvex's cache of a
   cancelled subscription. Dartvex skips that cache inside its one-shot
   `query()`, but `subscribe` has no public switch for it. This needs an
   upstream option, or our own grouping that ignores cached first values.
4. **Reconnect speed and actions.** After an unexpected drop Dartvex waits
   its 1 s initial backoff, which `ConvexClientConfig.initialBackoff` sets. It
   never resends an action across a reconnect, so a caller like a picture
   upload gets a retryable error instead.

### Recommendation

Switch the desktop transport to Dartvex, after the four changes above. It is
not a drop-in. Our client passes today, so nothing forces
the move. Switching means the next ordering bug is no longer ours to find in
1,265 lines of Rust patches nobody else reads.

The migration, in three pieces:

- One PR on the sync path, with a staged rollout. A `DartvexValueSource`
  replaces the 284-line `convex_client_native.dart`, with same-user refresh
  through `updateAuthToken`, `initialBackoff` near 100 ms, a retry for actions
  that fail as retryable, grouping that ignores cached first values, and the
  scenarios above as tests. Roughly 600 to 900 lines with tests. No server
  change, and shipped desktop builds keep our client.
- One upstream Dartvex PR, for `subscribe` without the cache seed.
- After the rollout, a deletion PR. It removes `third_party/convex_flutter`,
  which is 3,019 lines of Rust and 6,667 of Dart, most of it the generated
  bridge. It removes `third_party/convex_rs`, where we added 1,265 lines to
  0.10.4 in 13 commits since Aug 27. The FRB pin and the `bridge` CI lane go
  with them.

Web stays on the Convex JS client until Dartvex has run in a browser. The risk
is the sync path itself, with the auth and action differences above, and one
maintainer upstream. Pin an exact version; if Dartvex stalls, 11.7k lines of
Dart is a cheaper fork than what we carry now.

Not run: the paired timing trials on macOS from step 3 of the plan, Dartvex
on web, and any of this inside a running Icarus build. The test program drove
the clients directly, not through the op queue.

[512]: https://github.com/SunkenInTime/icarus/pull/512
[514]: https://github.com/SunkenInTime/icarus/pull/514
[530]: https://github.com/SunkenInTime/icarus/pull/530
[532]: https://github.com/SunkenInTime/icarus/pull/532

## What moving the transport would take

1. Runtime gauntlet steps 1 to 4 above pass for Dartvex 0.3.0. Done on
   Nov 10, except the macOS timing trials; section 4 adds four changes that
   come first.
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

`full_spec.dart` takes about 40 s, plus about 3 minutes with `--analyze` on a
cold analyzer cache. A rerun over identical files analyzes in about a second,
which is the `analysisMs` the committed JSON records.
Measured on Windows x64, Dart 3.12.2. The scrubbed spec has no `url` key, which
`dartvex_codegen` requires, so the tool adds a placeholder. Dartvex copies the
URL only into a comment.

## Artifacts

- [`full_spec_gate.json`](../../tool/convex_client_gauntlet/results/full_spec_gate.json):
  per-function status, refusal text and generated size
- [`contract_gate.json`](../../tool/convex_client_gauntlet/results/contract_gate.json):
  fixture gate, now on 0.3.0
