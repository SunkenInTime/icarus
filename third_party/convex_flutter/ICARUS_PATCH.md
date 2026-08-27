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

No generated Dart or Rust bridge file is edited: the public bridge signature is
unchanged. The hand-written changes are limited to `rust/src/lib.rs` and the
minimum `convex` crate version in `rust/Cargo.toml`; `rust/Cargo.lock` is
regenerated with:

```sh
cd third_party/convex_flutter/rust
cargo update -p convex --precise 0.10.4
```

This directory can be removed once a published `convex_flutter` release uses a
Convex Rust client with the same fixes and passes the Icarus auth gauntlet.
