# Convex browser client

`convex.browser.bundle.js` is the unmodified browser bundle produced by the
Apache-2.0-licensed `convex` npm package. It is checked in so the web client does
not depend on a third-party CDN at runtime.

Regenerate it from the repository root after updating the pinned npm dependency:

```sh
cp node_modules/convex/dist/browser.bundle.js web/convex.browser.bundle.js
```

Then check that the web client still reads it the way it expects:

```sh
node tool/check_convex_web_binding.mjs
node tool/convex_client_gauntlet/runtime/tool/run_with_local_deployment.mjs
```

The second runs the stamped transport checks in Chrome against a local deployment, after the gauntlet (`test/collab/live/stamped_transport_live_test.dart` and `test/collab/live/stamped_transport_reconnect_web_test.dart`). They rely on how this bundle orders its listeners and transition handlers, on its `connectionCount`, and on the `[CONVEX M(name)]` prefix it puts on a server function's failure ([ADR 0011](../docs/adr/0011-result-stamps.md)). A bundle that changes any of these fails them.
