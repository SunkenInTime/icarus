# ADR 0011: Every cloud answer can say which state of the client it comes from

**Status:** Accepted (2026-11-25)
**Feature:** The app's Convex transport (`lib/collab/transport/`, `lib/collab/src/convex_client_*.dart`, the generated `StampedConvexQuery`), on the vendored clients' timed calls (`third_party/convex_rs`, `third_party/convex_flutter`, their `ICARUS_PATCH.md`)

## Context

The library store is to take the editor's live results and its own one-shot reads and batch answers, in whatever order they reach Dart. A live update can arrive after a newer read; two snapshots can share a server time; a reconnect can start the server's time earlier than before. Nothing the app received said which of two answers was newer.

## Decision

The stamped calls (`StampedConvexTransport`, `StampedConvexQuery.fetch`, `watch` and `watchTogether`, `mutationStamped`) answer with a `ResultStamp`. The ordinary calls are unchanged and never reach the stamped path. A stamp holds:

- **client**: which client in this run of the app gave the answer. Stamps of two clients are never compared.
- **snapshot**: how many server transitions that client had applied when the answer was taken. For one client, a higher snapshot is a newer state, and two answers of one query with the same snapshot are the same answer. On native it counts transitions in the Rust client from the client's start. On web it counts the JS client's transition dispatches from the first stamped call, because counting starts there; the dispatches include one the JS client makes locally when a mutation fails. Both only go up.
- **connection**: the connection generation the client was on when it applied the state the answer comes from. A higher number is a later connection, and numbers can be skipped. On native it goes up each time the client starts again on a new socket, a failed dial included. On web it is the JS client's `connectionCount` at the transition that carried the answer, which goes up each time a socket opens. A value the client still holds from an earlier connection keeps that connection's number, even when it is handed to a listener after the socket has opened again. `connectionGeneration()` gives the generation the client is on now; an answer stamped lower comes from an earlier connection.
- **serverTime**: the snapshot's server time in nanoseconds, absent before the client has applied any server state (and on web for the JS client's local dispatches before the first server transition). It does not order answers on its own: two snapshots can share it, and a new connection can start at an earlier time, on both platforms. On web it is a JavaScript number, so above 2^53 it is rounded (to 256 ns today). The rounding never turns a time that is at or after another into one before it, but it can make a time up to 256 ns before another look equal to it, so "at or after" can hold on web for a result taken just before a write.

A mutation's stamp, when it succeeds, is a snapshot whose time is at or after its commit. That results from that snapshot on show the write rests on the sync protocol, not on the client, so a reader that needs a result to include a write checks both the snapshot and the time against the answer's. When the function fails, the stamp says when this client handled the answer, not which server state the function ran against.

On web, each answer a listener receives inside a transition is recorded as pending; the transition handler, which the JS client calls after the listeners in the same synchronous pass, stamps everything pending with the state it just applied; the answer is handed on a microtask later. An answer that arrives outside a transition (a new listener on a query the client already holds) takes the stamp of the last transition applied. So the first answers after counting starts, for a query an ordinary listener already holds, carry snapshot 0, no time and the connection current when counting started, until the next transition.

A stamped group is handed on only when every member's latest answer was taken on the connection of the newest one. After a reconnect the JS client can drop a member's held value without telling its listener; the group waits until that member answers on the new connection rather than pair an old value with a new one.

## Consequences

- On the stamped calls, a server function's failure is a stamped answer. On web it is recognised by the `[CONVEX M(...)]` or `[CONVEX Q(...)]` prefix the JS client puts on every server failure. A failure of the call itself is not an answer: a timeout, arguments that do not convert, a local rejection, or a value that does not decode throws, or ends a watch with that error.
- An empty group is refused on both platforms.
- The web client's stamped one-shot read is a subscription that ends after its first answer, so it is stamped like a live one.
- `test/collab/live/stamped_transport_live_test.dart` checks reads, watches, groups and answers against a local deployment, natively and in Chrome. `test/collab/live/stamped_transport_reconnect_web_test.dart`, in Chrome, closes the socket, holds the new socket's messages and withholds one group member's refresh; it checks that held values handed on after the reopen keep the old connection, and that the group waits for every member on the new one. Both run from `tool/convex_client_gauntlet/runtime/tool/run_with_local_deployment.mjs` in the gauntlet lane. Native reconnects are covered by the Rust client's own tests.
