# ADR 0011: Every cloud answer can say which state of the client it comes from

**Status:** Accepted (2026-11-25)
**Feature:** The app's Convex transport (`lib/collab/transport/`, `lib/collab/src/convex_client_*.dart`, the generated `StampedConvexQuery`), on the vendored clients' timed calls (`third_party/convex_rs`, `third_party/convex_flutter`, their `ICARUS_PATCH.md`)

## Context

The library store is to take the editor's live results and its own one-shot reads and batch answers, in whatever order they reach Dart. A live update can arrive after a newer read; two snapshots can share a server time; a reconnect can start the server's time earlier than before. Nothing the app received said which of two answers was newer.

## Decision

The stamped calls (`StampedConvexTransport`, `StampedConvexQuery.fetch`, `watch` and `watchTogether`, `mutationStamped`) answer with a `ResultStamp`. The ordinary calls are unchanged and never reach the stamped path. A stamp holds:

- **client**: which client in this run of the app gave the answer. Stamps of two clients are never compared.
- **snapshot**: how many server transitions that client had applied when the answer was taken, counted in the Rust client from the client's start. For one client, a higher snapshot is a newer state, and two answers of one query with the same snapshot are the same answer.
- **connection**: the connection generation the client was on when it applied the state the answer comes from. A higher number is a later connection, and numbers can be skipped: it goes up each time the client starts again on a new socket, a failed dial included. `connectionGeneration()` gives the generation the client is on now; an answer stamped lower comes from an earlier connection.
- **serverTime**: the snapshot's server time in nanoseconds. It is absent before the client has applied any server state: an answer given before the first transition (a failed mutation, an action, an empty group). The time does not order answers on its own: two snapshots can share it, and a new connection can start at an earlier time.

A mutation's stamp, when it succeeds, is a snapshot whose time is at or after its commit: the first such transition when the response came first, else the snapshot held when the response arrived. That results from that snapshot on show the write rests on the sync protocol, not on the client, so a reader that needs a result to include a write checks both the snapshot and the time against the answer's. When the function fails, the stamp says when this client handled the answer, not which server state the function ran against.

A stamped group's update carries one stamp for every member, and fills members that did not change from the last full update.

## Web

Not implemented: on web every stamped call throws `UnsupportedError` at once. The store does not run on web yet, so nothing calls them there. A first version stamped answers on Convex's JavaScript client by counting its transition handler calls and binding each listener's answer to the transition that carried it. Three rounds of review each found the same kind of fault: a value labelled with a connection or count it did not come from, because the stamp depended on our handler running last in a dispatch loop another listener can leave early, on top of the client's cached-listener timer. Web stamping is to be built directly on the JS `BaseConvexClient`, whose one transition callback gives the changed queries and the timestamp together: [#798](https://github.com/SunkenInTime/icarus/issues/798).

## Consequences

- On the stamped calls, a server function's failure is a stamped answer. A failure of the call itself is not an answer: a timeout, or a value that does not decode, throws, or ends a watch with that error. A timed answer with both or neither of a value and an error is a fault and ends the watch.
- An empty group is refused.
- `test/collab/live/stamped_transport_live_test.dart` checks reads, watches, groups and answers against a local deployment, from `tool/convex_client_gauntlet/runtime/tool/run_with_local_deployment.mjs` in the gauntlet lane. Reconnects are covered by the Rust client's own tests.
