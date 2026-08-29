# Keep the typed Convex wrapper inside Icarus

The typed Convex wrapper is an Icarus-owned integration layer. Convex's function
spec is the sole source for its modules, functions, parameters, and structural
result types. Code generation writes the complete Dart API, private structural
wire models, and transport implementation. Those wire models stay inside the
collaboration repositories. Exact tagged payload bindings reuse existing
Icarus types where the server declares their identity. No `dynamic`, `Object?`,
raw map, or stringly typed enum may escape the wrapper, and private decoders
must return either a typed value or a typed decoding failure.

The generated API uses Dart's pure-interface and redirecting-factory features.
The root client injects its transport through a factory that redirects to the
private generated implementation. Generated module APIs remain pure interfaces
obtained through root getters:

```dart
abstract interface class IcarusConvexApi {
  factory IcarusConvexApi(ConvexTransport transport) =
      _$IcarusConvexApi;

  FoldersApi get folders;
}

abstract interface class FoldersApi {
  ConvexQuery<List<FoldersListTreeItem>> listTree();
}
```

Authored Dart does not repeat ordinary functions, parameters, or result types.
Its only generation configuration binds an opaque, server-declared payload tag
to one existing Icarus type and codec. The generator never matches payloads by
structure or endpoint. Bindings have no wildcard, ordering, fallback, or
endpoint-specific override; a tag has exactly one meaning everywhere it
appears. Missing, extra, or duplicate bindings stop the build.

For an ordinary closed object validator with no domain tag, the generator emits
a private typed structural model. Repositories map that value into the Icarus
object the app uses. These generated models replace hand-written JSON DTOs such
as `CloudFolderSummary`; their `fromJson` plumbing disappears, and they never
cross the repository boundary.

App code calls named repository methods. Repository code may build sealed,
typed operation objects internally, but callers do not assemble generic
`StrategyOp` values or choose string route names.

The generated client covers every public Convex function that a client may
call, including functions Icarus does not call yet. Convex functions meant only
for backend jobs become internal functions instead of appearing in the Dart
API. This full coverage is deliberate: a client-callable function missing from
the generated Dart API is a contract failure, not an allowed undeclared
endpoint. Icarus accepts the extra declarations because they expose accidental
public functions and contract drift before app code depends on them.

Only the collaboration data layer imports the generated client. Widgets and
providers call hand-written repositories with named domain methods. An
architecture test rejects generated-client imports outside the allowed
directory.

Public Convex functions accept and return Icarus-owned public IDs. They resolve
those IDs to Convex document IDs on the server, and Convex document IDs remain
inside backend functions. The generator rejects `v.id(...)` in a public
function unless the endpoint has an explicitly approved infrastructure-handle
exception. Existing leaks must be removed before generation: user functions
must stop returning user document IDs, and the image upload handshake must use
an Icarus-owned upload-attempt ID instead of persisting an `imageAssets` ID in
the local queue. Existing Icarus public IDs remain `String` values.

Generated methods use ordinary nullable named parameters when a Convex field
has only two states: absent or present. The generator introduces a presence
wrapper only when the validator permits three distinct states: absent, `null`,
and a value.

One-shot calls return `Future<T>` and subscriptions return `Stream<T>`. They
report failures through a sealed exception hierarchy rather than wrapping every
value in a result object. Repositories translate those exceptions into Icarus
sync states.

Client-side failures have distinct exception types for transport, timeout, and
decoding failures. A function failure carries a generated `ConvexErrorCode`
enum and the server message instead of generating one exception class per
server code.

`convex/lib/errors.ts` owns one machine-readable error-code catalog. Its
`ErrorCode` type and every structured error helper derive from that catalog,
and the contract snapshot task writes its scrubbed values beside the function
spec. The Dart generator reads that snapshot to emit `ConvexErrorCode`; it does
not scrape throw sites or maintain a second hand-written list.

Both raw transports must preserve structured Convex error codes and data. The
wrapper never derives a code from a human-readable message. Transport contract
tests prove that native and web produce the same private error value. If
`convex_flutter` cannot expose the structured payload, Icarus extends its fork
before building generated error mapping.

Subscriptions survive connection loss and authentication refresh. Those states
remain on their existing separate streams. A recoverable function error enters
the typed data stream without closing it. A decoding or contract failure
cancels and closes the subscription because Icarus cannot trust later values
from the same mismatched contract.

Convex's generated function-spec JSON is the wire contract. The generator walks
every client-callable public function in that spec and emits the entire Dart
API. Generation fails on a missing argument or return validator, an unsupported
validator, `v.any()`, an opaque value without a server discriminator and exact
binding, any missing, extra, or duplicate binding, a non-injective Dart name
conversion, a collision with generated client or `Object` members, or any shape
that would escape as an untyped value. It never auto-suffixes a collision or
guesses a domain type. The generator remains Icarus-owned and only promises to
support Icarus; its internal package layout is not a commitment to publish a
general Convex package.

The repository commits a scrubbed function-spec snapshot. Developers refresh
it after backend contract changes, and ordinary Dart generation reads the local
snapshot instead of requiring a live Convex deployment. CI also deploys the
current backend to an isolated Convex environment, obtains and scrubs a fresh
function spec, and fails if it differs from the committed snapshot. A stale
snapshot therefore cannot make generation appear clean.

The repository also commits the generated Dart client. CI regenerates it and
fails when the working tree changes. All output lives as standalone libraries
under `lib/collab/generated/`; authored code never lives there, and generated
files never use `part` or `part of` with authored libraries. Each run recreates
the owned output set so a renamed function cannot leave a stale Dart file.
Developers edit Convex validators or the opaque-payload binding file, never
generated files.

Canonical element and lineup JSON remains private to the wrapper. Their exact
tag bindings make generated methods accept and return existing typed Icarus
objects at those payload positions. Convex validates each payload's kind,
version, and JSON envelope; golden round-trip tests validate the bound codec's
conversion between that JSON and the Dart domain object. The literal `kind` in
the server validator is the binding key, so every appearance of `drawing` uses
the `DrawingElement` codec and no endpoint may redefine it. If one endpoint
needs different semantics, the server declares a new tag. Icarus does not
duplicate every Flutter object field in TypeScript validators.

Each generated query method returns a typed query object. Its `fetch()` method
returns `Future<T>` and its `watch()` method returns `Stream<T>`. The endpoint's
arguments and result type are declared once rather than duplicated across
separate fetch and watch declarations. The stream is cold and
single-subscription. Each listener opens one Convex subscription, and canceling
that listener closes it. Generated query objects do not cache or broadcast;
repositories must share a subscription explicitly when several consumers need
the same live result. `fetch()` and `watch()` are independent choices, not two
steps in one read. `fetch()` reads once. `watch()` emits the current result
first and then later changes, so a live consumer does not fetch before it
watches.

Generated functions take typed named parameters instead of creating an
argument class for every endpoint. The generator serializes those parameters
inside the private implementation.

The generated client groups functions by their Convex module, such as
`api.folders.listTree()` and `api.strategies.create(...)`, instead of placing
every function on one flat class. The spec path `folders:listTree`
deterministically becomes `api.folders.listTree()`. The generator has no
structural name override or last-write-wins rename table. If two Convex paths
convert to the same Dart identifier, or a path collides with the client API,
generation stops and Icarus renames the backend function while the server is
clay.

The folder library uses one complete accessible-tree query. The existing
`folders:listAll` and `folders:listForParent` functions become
`folders:listTree`, and repository code shares its single subscription. Root
folders, immediate children, breadcrumbs, owned folders, and shared folders
are derived from that typed tree in Dart. Icarus already needs the complete
tree for its sidebar and path controls, while `listForParent` currently reads
that same tree before filtering it. Keeping both would pay for two reactive
queries without narrowing the server read set.

The durable queue holds sealed typed op variants in memory. Hive stores each op
and its delivery state as a versioned map containing only primitive values. A
strict decoder reconstructs the sealed variant and reports an unreadable record
without exposing an untyped payload. Outbox encoding is separate from the
generated Convex request encoding, so a server contract change cannot silently
rewrite the on-disk queue format.

Native and web share the same generated API, codecs, and exception mapping.
That layer targets one small raw transport interface. The native adapter uses
`convex_flutter`; the web adapter uses the Convex JavaScript client.

Before generated codecs depend on either adapter, both transports normalize
their platform-specific results into one private Convex value model. Native
JSON strings and web JavaScript values never reach generated decoders
directly. A transport conformance suite feeds equivalent fixtures through both
adapters and requires identical normalized results for every supported Convex
value, including numeric boundaries, bytes, nested collections, optional
fields, and nulls.

Typed object decoders ignore wire fields that their target Dart shape does not
declare, allowing a newer server to add data without breaking an installed
client. They still reject a missing declared field or a value of the wrong
type.

Generated enums fail decoding when the server sends an unknown literal. Icarus
does not guess at new permission roles, sync statuses, or operation kinds. A
specific harmless enum may opt into an explicit `unknown` case.

The cloud branch has no users, so protocol version 3 does not carry a converter
for pre-version-3 outbox records. The cutover clears only the branch-owned cloud
outbox and starts with `outboxRecordVersion: 2`; it never clears or rewrites the
local library or `.ica` data. `outboxRecordVersion`, `clientProtocolVersion`,
and each payload's `payloadVersion` remain separate counters. Each changes only
when its own format changes.

An unknown server error code becomes a `ConvexFunctionException` with an
`unknown` enum value while retaining the raw code and message. The affected
work pauses with that diagnostic; parsing the error never drops the op.

Before changing the protocol, Icarus fixes queued-op merging so an op ID always
names immutable work. A retry of unchanged work keeps its ID, but any merge
that changes the intended operation receives a new ID. A regression test must
cover the dangerous sequence: Convex applies an op, its response is lost, the
client restores it, the user edits the same entity, and the next flush applies
that newer edit instead of treating it as a replay. This repair ships as a
separate prerequisite rather than hiding inside the protocol rewrite.

Before wrapper generation begins, Icarus replaces the current generic sync-op
envelope with protocol version 3. The request and acknowledgement contracts
become discriminated unions whose variants declare only the fields they use.
Each request has one closed `type` literal that names exactly one legal
operation. The literal identifies both its entity and action; clients cannot
select those two parts independently and create an illegal pair. Its spelling
uses `<entity>.<action>`, such as `element.patch`, because the separator keeps
both parts readable while the complete string remains one discriminator.
Protocol version 3 does not define `element.move` or `lineup.move`. The current
server executes those kinds exactly like `patch`, and the app does not emit
them. Pre-version-3 outbox records containing `move` disappear with the rest of
the development outbox; a distinct `move` returns only if Icarus gives it
distinct behavior.
Each variant also names the record whose revision it protects. It uses fields
such as `expectedPageRevision` and `expectedStrategyRevision` instead of a
generic `expectedRevision` whose meaning changes between operations.
Acknowledgements distinguish newly applied work from an idempotent replay.
An already-recorded op ID returns a first-class `noop` result rather than an
`applied` result carrying `noop` in a reason string.
The result union also separates expected `rejected` outcomes from unexpected
`failed` outcomes. A rejection carries a closed, generated reason that the
sync logic understands, such as a revision mismatch. A failure retains its
structured code and message and moves the affected work to visible attention;
the client never folds it into a rejection by lowercasing or parsing text.
When a revision mismatch causes rejection, that result includes a
variant-specific `current` snapshot containing the guarded record's revision
and typed value. Convex captures the snapshot in the rejecting transaction.
The client does not receive a generic `latestPayload` or issue a second fetch
that could observe a later state.
The redesign keeps the existing sync behavior: page-scoped delivery,
per-record revisions, durable queued work, client and op IDs for replay
protection, batched per-op outcomes, and no-op replay handling. Existing
pre-version-3 outbox records are cleared at the unreleased cutover. The
generator then reads this typed contract instead of preserving the loose
`entityType`, `kind`, optional payload, string reason, and untyped
latest-payload shape.

The unreleased cloud switches directly to `clientProtocolVersion: 3`; Convex
does not keep a version 2 handler. The cutover wipes the clay deployment and
the development outbox, then rejects any older wire version with a structured
protocol-mismatch failure.

After protocol version 3 settles and before generator work begins, every public
Convex function receives an explicit return validator. This is a separate
backend milestone because Convex enforces those validators at runtime. Tests
exercise each function against its new validator, and the app must remain green
before generated Dart starts depending on the completed return contract.
