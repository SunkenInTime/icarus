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
