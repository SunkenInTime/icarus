# Icarus Convex code generator

This standalone tool turns the committed, deployment-scrubbed Convex function
spec into Icarus-owned Dart. It does not contact a Convex deployment.

From the repository root:

```sh
fvm dart run tool/icarus_convex_codegen/bin/generate.dart
```

The generator resolves the annotated payload codecs in
`lib/collab/convex_payload_codecs.dart`, validates every public contract node,
and replaces the complete owned output set in `lib/collab/generated/`.

When a public backend validator changes, refresh and audit the scrubbed
snapshots before regenerating:

```sh
npm run snapshot:convex-contract
npm run audit:convex-contract
node tool/check_convex_shipped_clients.mjs
fvm dart run tool/icarus_convex_codegen/bin/generate.dart
git diff --exit-code -- convex/function_spec.json convex/error_codes.json lib/collab/generated
```

`check_convex_shipped_clients.mjs` compares the spec with the one in every
`desktop-stable-v*` tag and fails when a build we shipped would send arguments
the server now refuses or receive results its decoders can't read. A result
value the server sends only to clients that ask for it is declared in
`tool/convex_opt_in_results.json`.

CI repeats generation from the committed snapshots on Windows and Linux. Its
contract job first creates an isolated Convex preview deployment, then runs the
snapshot command in check mode against that deployment. The repository must
have a Convex preview deploy key configured as the
`CONVEX_PREVIEW_DEPLOY_KEY` Actions secret; a production or ordinary deployment
key is intentionally rejected by `--preview-create`.
