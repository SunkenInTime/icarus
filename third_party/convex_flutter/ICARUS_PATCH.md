# Icarus convex_flutter patch

Source: the published `convex_flutter` 3.0.1 package.

Icarus pins the package's native `convex` Rust client to 0.10.4. The published
package lock selected 0.10.2. Convex Rust 0.10.3 introduced the reconnect-state
repair and auth-token callback used to restore authenticated state after a
WebSocket reconnect; 0.10.4 includes that repair plus a subscription leak fix.

The package's hand-written Rust auth adapter now gives the Dart token callback
to `ConvexClient.set_auth_callback`. That keeps token refresh in the same
upstream state machine that replays subscriptions and mutations after a socket
reconnect. The old adapter owned a separate expiry timer and called static
`set_auth`, which could leave the client disconnected after the server rejected
an expired token.

An auth handle reports `onAuthChange(false)` when the server keeps refusing the
tokens the callback returns (the patched crate's `watch_auth_refused`), and
`onAuthChange(true)` once it accepts one again. The published package only
reported a missing token, so a session the server refused looked signed in on
desktop: the app showed "offline" and reconnected four times a second instead
of asking the user to reconnect or sign out, as it does on web.

Auth handles also carry an internal generation. Disposal only clears auth when
the handle still owns the current generation, so a delayed cancellation from a
replaced handle cannot erase the fresh callback.

The native manual reconnect API calls the Icarus-patched `convex` 0.10.4 crate
in `../convex_rs`. It waits for a real connecting-to-connected transition; the
published package method only ran its configured health query.

`subscribe_group` subscribes to several queries together through the
patched crate's `subscribe_set` and calls Dart with every value, all from one
server state: at most once per transition, and fewer times when the client
applies transitions faster than the group's task reads them, since it then
reads only the latest. Separate `subscribe` calls each run
their own task and post each update from a spawned task, so two queries changed
by one write can reach Dart apart. A group sends a value only when it changed
since the last update, awaits each callback before the next, and sends every
value again after a failure.

`queryTimed` and `subscribeTimed` are `query` and `subscribe` with the
snapshot each result comes from (`TimedAnswer`): the patched crate's
`QueryResults::snapshot`, which orders two results of one query (higher is
newer, equal is the same result), and its `ts`, the snapshot's server time in
nanoseconds, which can tie (the crate's patch notes say why). A query error is
an answer with its snapshot too, not a thrown error. A timed subscription posts
each result from a spawned task, as `subscribe` does, so results can reach Dart
out of order, and a one-shot read can arrive before a live result from an older
snapshot; the snapshot numbers put them back in order. Both are native only,
like `subscribeGroup`: Icarus's web build uses Convex's JavaScript client.
`mutationTimed` and `subscribeGroupTimed` do the same for a mutation's answer
and for a group's updates (`TimedGroupUpdate`, whose values all come from one
snapshot), and every stamp carries its client and connection numbers too. A
mutation whose server function fails is an answer with its snapshot, like a
query error; a timeout or a bridge error still throws. The crate's patch notes
say what a mutation answer's snapshot means and what it rests on.
`connectionGeneration` gives the connection generation the client is on now,
so the app can tell a stamp from an earlier connection by its number alone.
`tool/convex_client_gauntlet/runtime/test/timed_results_test.dart` checks the
snapshots reach Dart, on a local deployment, in the gauntlet lane.

A mutation's future resolving means the Rust client has applied a transition
at or after the write's commit timestamp (the crate's patch notes say what that
rests on), not that Dart has received the live result that shows the write; the
snapshot is how Dart can tell. Since the crate waits for that transition, a
call whose transition comes after this bridge's deadline (30 seconds by
default) now times out where it used to succeed on an older transition. If the outbox retries, the server answers the same op ids as
replays; it can instead pause at its attempt limit.

Generated Dart and Rust bridge files are never hand-edited. They are regenerated
from `rust/src/lib.rs` with `flutter_rust_bridge_codegen` 2.11.1. Hand-written
changes are limited to the Dart client implementation, `rust/src/lib.rs`, and
the local `convex` dependency in `rust/Cargo.toml`.

```sh
cd third_party/convex_flutter
flutter_rust_bridge_codegen generate
```

This directory can be removed once a published `convex_flutter` release uses a
Convex Rust client with the same fixes and passes the Icarus auth gauntlet.
