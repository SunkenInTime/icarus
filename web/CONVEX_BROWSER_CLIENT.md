# Convex browser client

`convex.browser.bundle.js` is the unmodified browser bundle produced by the
Apache-2.0-licensed `convex` npm package. It is checked in so the web client does
not depend on a third-party CDN at runtime.

Regenerate it from the repository root after updating the pinned npm dependency:

```sh
cp node_modules/convex/dist/browser.bundle.js web/convex.browser.bundle.js
```
