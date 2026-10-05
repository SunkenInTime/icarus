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

Auth handles also carry an internal generation. Disposal only clears auth when
the handle still owns the current generation, so a delayed cancellation from a
replaced handle cannot erase the fresh callback.

The native manual reconnect API calls the Icarus-patched `convex` 0.10.4 crate
in `../convex_rs`. It waits for a real connecting-to-connected transition; the
published package method only ran its configured health query.

Generated Dart and Rust bridge files are never hand-edited. They are regenerated
from `rust/src/lib.rs` with `flutter_rust_bridge_codegen` 2.11.1. Hand-written
changes are limited to the Dart client implementation, `rust/src/lib.rs`, and
the local `convex` dependency in `rust/Cargo.toml`.

```sh
cd third_party/convex_flutter/rust
flutter_rust_bridge_codegen generate
```

This directory can be removed once a published `convex_flutter` release uses a
Convex Rust client with the same fixes and passes the Icarus auth gauntlet.
