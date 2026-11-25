# ADR 0011: Every cloud answer can say which state of the client it comes from

**Status:** Accepted (2026-11-25)
**Feature:** The app's Convex transport (`lib/collab/transport/`, `lib/collab/src/convex_client_*.dart`, the generated `StampedConvexQuery`), on the vendored clients' timed calls (`third_party/convex_rs`, `third_party/convex_flutter`, their `ICARUS_PATCH.md`)

## Context

The library store is to take the editor's live results and its own one-shot reads and batch answers, in whatever order they reach Dart. A live update can arrive after a newer read; two snapshots can share a server time; a reconnect can start the server's time earlier than before. Nothing the app received said which of two answers was newer.

## Decision

The stamped calls (`StampedConvexTransport`, `StampedConvexQuery.fetch`, `watch` and `watchTogether`, `mutationStamped`) answer with a `ResultStamp`. The ordinary calls are unchanged and never reach the stamped path. A stamp holds:

- **client**: which client in this run of the app gave the answer. Stamps of two clients are never compared.
- **snapshot**: how many server transitions that client had applied when the answer was taken. For one client, a higher snapshot is a newer state, and two answers of one query with the same snapshot are the same answer. On native it counts transitions in the Rust client; on web it counts the JS client's transition dispatches, which also include a dispatch the client makes locally when a mutation fails. Both only go up.
- **connection**: the connection generation the client was on. A higher number is a later connection, and numbers can be skipped. On native it goes up each time the client starts again on a new socket, a failed dial included. On web it is the JS client's `connectionCount`, which goes up each time a socket opens. `connectionGeneration()` gives the generation the client is on now; an answer stamped lower comes from an earlier connection.
- **serverTime**: the snapshot's server time in nanoseconds, absent before the client has applied any server state. It does not order answers on its own: two snapshots can share it, and a new connection can start earlier. On web it is a JavaScript number, so it is rounded, but it never goes backwards.

A mutation's stamp, when it succeeds, is a snapshot whose time is at or after its commit. That results from that snapshot on show the write rests on the sync protocol, not on the client, so a reader that needs a result to include a write checks both the snapshot and the time against the answer's. When the function fails, the stamp says when this client handled the answer, not which server state the function ran against.

On web an answer is handed on a microtask after the transition that carried it: the JS client calls its listeners and then our transition handler in one synchronous pass, so by then the handler has counted it. An answer that arrives outside a transition (a new listener on a query the client already holds) gets the count current at that moment, which is the state it holds. The counting starts on the first stamped call, so ordinary calls run exactly as before.

## Consequences

- A function error is a stamped answer on the stamped calls, not a thrown error; a timeout, a transport failure or a value that does not decode still throws or ends a watch.
- The web client's stamped one-shot read is a subscription that ends after its first answer, so it is stamped like a live one.
- `test/collab/live/stamped_transport_live_test.dart` checks all of this against a local deployment, natively and in Chrome, run by `tool/convex_client_gauntlet/runtime/tool/run_with_local_deployment.mjs` in the gauntlet lane.
