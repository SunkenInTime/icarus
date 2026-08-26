# Reference: Convex to Dart code generation

Status: fallback reference, superseded on 2026-08-26

Start with
[`convex_dart_client_gauntlet_handoff.html`](convex_dart_client_gauntlet_handoff.html).
Use this reference only if the gauntlet keeps `convex_flutter` and the team then
chooses to build the fallback generator described here.

Use this reference when implementing the generator, adding public Convex result
validators, or adapting `convex_flutter`. The execution order and completion
criteria live in
[`convex_dart_codegen_handoff.md`](convex_dart_codegen_handoff.md).

## File ownership

```text
convex/lib/contracts/
  common.ts
  folders.ts
  images.ts
  invites.ts
  shares.ts
  users.ts

tool/convex_dart_codegen.dart
tool/src/convex_dart_codegen/
tool/convex_contract/
  function_spec.json
  codegen_overrides.json
  contract_manifest.json
  fixtures/

lib/collab/convex_api/
  convex_contract_exception.dart
  convex_flutter_transport.dart
  json_value.dart

lib/collab/generated/convex_api/
  api.dart
  runtime.dart
  types.dart
  modules/

test/tool/
test/collab/
```

The repository owns the pure-Dart generator. The files under
`lib/collab/generated/convex_api/` come only from that generator. The transport,
contract exception, and versioned JSON type are handwritten.

## Type mapping

| Convex validator | Dart contract type |
| --- | --- |
| `v.string()` | `String` |
| `v.boolean()` | `bool` |
| `v.number()` | `num` |
| `v.null()` | `Null` |
| `v.id("table")` | typed `ConvexId<Table>` wrapper |
| `v.array(T)` | `List<T>` |
| `v.object({...})` | generated immutable type |
| literal union | generated enum |
| discriminated object union | generated sealed type |
| `v.record(v.string(), T)` | `Map<String, T>` |
| optional field | `Optional<T>` |
| nullable value | `T?` |

`v.number()` does not distinguish integers from fractional values.
`codegen_overrides.json` may narrow an exact function and field path to `int`
or `double`. Each override matches exactly one field. A missing or stale match
stops generation, and the generated decoder checks the conversion.

Map the recursive `cloudJsonObjectValidator` to one named `JsonObject` type.
It is the escape hatch for versioned canvas payload data. An outer snapshot,
result, acknowledgement, or asset remains fully typed.

An absent return validator, `v.any()`, bytes, bigint, or another unsupported
shape stops generation unless the exact function appears in the temporary
page-sync allowlist. Each allowlist entry names the replacement contract that
removes it.

Generated names follow Dart conventions while JSON codecs preserve wire names
exactly. Keyword escaping changes only the Dart name. Decoder errors include
the function and field path without including the response value.

## Server results

Place reusable result validators under `convex/lib/contracts/` and attach them
to stable public functions.

```ts
export const cloudFolderSummaryValidator = v.object({
  publicId: v.string(),
  name: v.string(),
  parentFolderPublicId: v.union(v.string(), v.null()),
  role: v.union(
    v.literal("owner"),
    v.literal("editor"),
    v.literal("viewer"),
  ),
  createdAt: v.number(),
  updatedAt: v.number(),
});

export const listForParentResultValidator = v.array(
  cloudFolderSummaryValidator,
);
```

```ts
export const listForParent = query({
  args: { /* existing validators */ },
  returns: listForParentResultValidator,
  handler: async (ctx, args) => { /* existing behavior */ },
});
```

The result validator describes the public value, not the database document.
Reuse existing settings, palette, and payload validators. A function with no
result declares `returns: v.null()` and returns `null` explicitly. Preserve
optional versus nullable fields and the existing public-ID boundary.

Adding `returns:` validates existing behavior. It does not change
authorization, sorting, filtering, or writes. Exercise success and error paths
on the development deployment before accepting the validator.

## Generated API

The application calls generated module wrappers:

```dart
final folders = await api.folders.listForParent(
  parentFolderPublicId: const Optional.absent(),
  scope: FolderScope.owned,
);

final subscription = api.folders.watchForParent(
  parentFolderPublicId: const Optional.absent(),
  scope: FolderScope.owned,
);
```

Only query functions receive subscription wrappers. A function changing from
query to mutation changes its generated method and breaks stale callers at
compile time.

Existing domain models may keep behavior or semantic types. Their adapters
accept generated values. They never accept a raw response map.

## Transport

Generated wrappers target this handwritten interface:

```dart
abstract interface class ConvexTransport {
  Future<Object?> query(String name, JsonObject args);
  Future<Object?> mutation(String name, JsonObject args);
  Future<Object?> action(String name, JsonObject args);
  Stream<Object?> watch(String name, JsonObject args);
}
```

`ConvexFlutterTransport` owns the runtime mismatch once. It decodes JSON strings
returned by query, mutation, action, and subscription callbacks. Its `watch`
method preserves the epoch and late-cancellation protection currently in
`ConvexStrategyRepository._watch`.

The transport reports malformed JSON as `ConvexContractException`. Error text
names the function and expected field path. It omits private values, tokens,
signed URLs, and Strategy contents.

Generated-wrapper tests use a fake transport. Authentication, reconnect, and
connection state remain owned by `convex_flutter`.
