# Handoff: typed Dart bindings for Convex

Status: fallback only, superseded on 2026-08-26

> Do not start this implementation first. The current handoff is
> [`convex_dart_client_gauntlet_handoff.html`](convex_dart_client_gauntlet_handoff.html).
> It tests `dartvex` against `convex_flutter` before Icarus commits to owning a
> generator. Return to this document only if Dartvex fails that gauntlet and
> `convex_flutter` remains the runtime.

Historical verified base: `origin/icarus-cloud` at `16a19f7` on 2026-08-25.
This SHA is stale. Refresh the remote before using any fallback step.

PR target: `icarus-cloud`

## Assignment

Deliver one reviewable PR that generates typed Dart bindings from Icarus's
public Convex function contract. Keep Flutter, Convex, and `convex_flutter`.
Move function-name strings, argument maps, JSON decoding, and subscription
lifecycle behind generated wrappers and one handwritten transport.

The **stable modules** in this PR are `health`, `users`, `folders`, `shares`,
`invites`, and `images`.

Strategy, Page, element, lineup, snapshot, and operation functions remain on a
temporary allowlist. The page-scoped sync refactor owns those contracts.

The rule worth remembering is:

> JSON may exist on the wire. It does not belong in handwritten application
> code.

## Context pointers

- **Always:** read [`AGENTS.md`](../../AGENTS.md) and
  [`CONTEXT.md`](../../CONTEXT.md) before editing.
- **Codegen implementation:** when editing the generator, public result
  validators, generated API, or `convex_flutter` adapter, read
  [`convex_dart_codegen_reference.md`](convex_dart_codegen_reference.md). It
  owns file placement, type mapping, server-result, and transport rules.
- **Page sync:** before changing `strategies`, `pages`, `elements`, `lineups`,
  `snapshot`, `ops`, revisions, or the outbox, read
  [`server_side_sync_boundaries_handoff.md`](server_side_sync_boundaries_handoff.md).
  This PR should normally leave those modules untouched.
- **Function metadata:** use the official
  [Convex `function-spec` command](https://docs.convex.dev/cli/reference/function-spec).
- **Generator precedent:** inspect
  [`dartvex_codegen`](https://github.com/AndreFrelicot/dartvex/tree/main/packages/dartvex_codegen)
  only for its spec parser and goldens.

## Fixed contract

The **contract loop** is the source of truth:

```text
Convex args and returns validators
              -> normalized function_spec.json
              -> generated Dart
              -> generate --check
```

A change is incomplete until the contract loop closes with a clean second
generation.

- Public Convex functions declare explicit `returns:` validators.
- `npx convex function-spec` supplies function names, kinds, visibility,
  arguments, and results.
- The refresh command accepts only `dev`, `local`, or a development deployment
  listed in repository configuration. It rejects production and unknown
  targets.
- The repository commits a normalized spec and generated Dart. Normal Flutter
  builds need no generator run or Convex access.
- `convex_flutter` remains the only Convex client runtime.
- Stable functions produce fully typed arguments and results. Unsupported
  validator shapes stop generation with a field path.
- The committed contract contains no deployment URL, auth token, share token,
  signed URL, or captured Strategy payload.
- Local Hive models, `.ica` files, library backups, auth behavior, and sync
  behavior keep their current shape.
- Convex OpenAPI stays outside this design because its HTTP client does not
  preserve reactive subscriptions.

## Execution

### 1. Lock the base

Start from a clean branch or worktree based on the latest
`origin/icarus-cloud`. Refresh before trusting the verified SHA.

```bash
git fetch --prune origin
git rev-parse origin/icarus-cloud
git log -5 --oneline origin/icarus-cloud
git status --short
rg -n "function-spec|convex_dart_codegen|pageContents|getShell|getFullSnapshot" .
```

Inventory public functions and return validators from the refreshed tree.
Record the base SHA, existing warnings, and these baseline results in the PR
description:

```bash
npm ci
npx tsc --noEmit
fvm flutter pub get
fvm flutter test test/collab_sync_models_test.dart
fvm flutter test test/strategy_op_queue_provider_test.dart
fvm flutter analyze --no-fatal-infos
```

Completion criterion: the worktree is clean before edits, the remote base and
public-function inventory are recorded, and every baseline result is recorded.
An unexpected failure blocks implementation until its cause is known.

### 2. Build the generator around fixtures

Read the codegen implementation reference. Implement the spec model, parser,
type mapper, deterministic emitter, override matching, and generated-file
check. Use `dartvex_codegen` only as a reference. Copied MIT-licensed code keeps
its license and provenance.

Fixtures cover:

- query, mutation, action, and subscribed query;
- required, optional, and nullable values;
- arrays, records, nested objects, typed IDs, literal enums, and one
  discriminated union;
- numeric overrides and the named `JsonObject` exception;
- a Dart keyword used as a wire field name;
- an unsupported validator and an absent return validator;
- shuffled function order producing identical output.

Provide these commands:

```bash
fvm dart run tool/convex_dart_codegen.dart refresh --deployment dev
fvm dart run tool/convex_dart_codegen.dart generate --check
```

`refresh` uses `npx convex function-spec --file`, reads its timestamped output,
scrubs the URL, canonicalizes the spec, records the source hash and tool
version, removes the timestamped file, generates Dart, and formats it. The
source hash covers stable module files, their shared validators, and
`convex/lib/contracts/`.

`generate --check` uses committed inputs, generates into a temporary directory,
and compares the result with committed output. Each generated file carries the
contract hash and a `GENERATED CODE - DO NOT EDIT` banner.

Completion criterion: fixture and golden tests pass offline, unsupported input
exits nonzero with an exact path, and two generations from the same spec produce
no diff.

### 3. Add the transport tracer

A **tracer** proves the full call path before broad migration. Implement the
transport from the reference, then choose one stable function for each path:

- query;
- subscribed query;
- mutation;
- action.

For each tracer, add its result validator, deploy it to development, refresh
the spec, generate the wrapper, and migrate the call.

Transport tests prove:

- each call decodes one JSON result;
- malformed JSON becomes `ConvexContractException`;
- subscription decode errors enter the stream;
- cancellation before subscription creation cancels the late handle;
- an old subscription epoch cannot update a new listener;
- error text omits raw private data.

Completion criterion: all four tracer paths pass through a fake transport and
the team development deployment with the same success and error behavior as
the existing handwritten call path.

### 4. Close the contract loop for stable modules

Work one stable module at a time:

1. Add reusable result validators.
2. Attach `returns:` without changing handler logic.
3. Run `npx tsc --noEmit`.
4. Exercise success and authorization-error paths on development data.
5. Refresh the normalized spec and inspect its diff.
6. Generate Dart and run decoder tests.
7. Migrate every application call site in that module.
8. Remove the replaced handwritten top-level decoder.

An existing domain model may keep behavior or semantic types through an adapter
that accepts a generated value. After each module, search `lib/` for its raw
function names. Only generated constants and test fixtures may retain them.

Completion criterion: every stable public function has a non-null return spec;
every stable application call uses generated arguments and results; the
development deployment accepts the validators; and the contract loop is clean.

### 5. Add drift gates

Add credential-free CI checks:

```bash
fvm dart run tool/convex_dart_codegen.dart generate --check
fvm flutter test test/tool/convex_dart_codegen_test.dart
fvm flutter test test/tool/convex_dart_codegen_golden_test.dart
fvm flutter test test/collab/convex_flutter_transport_test.dart
fvm flutter test test/collab/generated_convex_api_test.dart
```

The coverage test fails when a stable public function lacks a return validator,
an unlisted function emits `dynamic`, an allowlist entry is stale, the source
hash changed without a spec refresh, generated output drifted, or the committed
spec contains a deployment URL.

Add a repository check that reports raw Convex calls outside the transport,
generated output, tests, and named page-sync compatibility files.

Completion criterion: changing one stable argument or result validator without
refreshing generated Dart makes CI fail, and regeneration makes it pass.

### 6. Prove behavior and deliver

Run the full gate:

```bash
npx tsc --noEmit
fvm dart run tool/convex_dart_codegen.dart generate --check
fvm flutter test test/tool/convex_dart_codegen_test.dart
fvm flutter test test/tool/convex_dart_codegen_golden_test.dart
fvm flutter test test/collab/convex_flutter_transport_test.dart
fvm flutter test test/collab/generated_convex_api_test.dart
fvm flutter test
fvm flutter analyze --no-fatal-infos
git diff --check
```

Then use disposable data on the team development deployment:

1. Sign in and load the cloud library.
2. Observe a typed folder or shared-item subscription update from a second
   client.
3. Create, update, and delete a folder.
4. Create and revoke a share or invite.
5. Exercise one image action.
6. Disconnect and reconnect, then confirm the subscription resumes.
7. Trigger an authorization failure and confirm baseline error behavior.

Confirm server results or second-client updates. Navigation alone is not proof.
Run `refresh` once more and require a clean second generation.

Open a PR against `icarus-cloud`. Include the base SHA, contract-loop design,
allowlist, generated-file rule, automated results, and visible proof. Leave the
PR unmerged for Dara.

Completion criterion: every automated command passes, every visible scenario
has server-side proof, the contract loop is clean, the diff contains only the
intended codegen work, and the PR is open and unmerged.

## Stop conditions

Stop and ask Dara when:

- the selected deployment is production or contains public user data;
- another branch already owns incompatible codegen work;
- the page-scoped sync contracts have landed with different names or shapes;
- useful types require weaker server validation;
- overrides expand beyond numeric meaning and versioned JSON payloads;
- implementation requires replacing or forking `convex_flutter`;
- unrelated dirty work overlaps the contract, transport, generator, or CI;
- generated output cannot be reproduced from committed inputs.

The assignment is complete when Convex contract drift becomes a generation
failure or a Dart compile failure. A user must never discover it by losing a
cloud update.
