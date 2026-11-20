# icarus_library

The library's rows, the ops that change them, and what an op does to them.
It is pure Dart: no Flutter, no Riverpod, nothing from the app's `lib/`. The
decision behind it is [ADR 0009](../../docs/adr/0009-one-store-for-the-library.md);
the words it uses (Row, Element, Store, Base, Op, Pending op) are the ones in
[CONTEXT.md](../../CONTEXT.md).

## What it holds

- **Rows**, in the server's shape with public ids. Every kind is a sealed
  type with a case for a row this build can read and one for a row it
  cannot: `StrategyRow` is a `ReadableStrategy` or an `UnreadableStrategy`;
  `FolderRow` a `ReadableFolder` or `UnreadableFolder`; `PageSettingsRow` a
  `ReadablePageSettings` or `UnreadablePageSettings`; `PageRow` a
  `LivePage`, a `TrashedPage` (`PendingTrashedPage`, deleted by an op the
  server has not confirmed, or `ConfirmedTrashedPage` with the time and who
  deleted it: `DeletedByYou`, `DeletedByName` or `DeleterUnknown`) or an
  `UnreadablePage`; `ElementRow` a `LiveElement`, `DeletedElement` or
  `UnreadableElement`; `LineupGroupRow` a `LiveLineupGroup`,
  `DeletedLineupGroup` or `UnreadableLineupGroup`. A `ReadableStrategy` has
  `createdAt` and `updatedAt`, as the server's row has.
- **Payloads**: an element or lineup group payload stays canonical JSON
  (`{kind, payloadVersion, data}`). The app turns it into a drawn item at the
  edge of the editor.
- **Ops**: the fourteen the server takes, as the sealed `StrategyOp`, sent
  exactly as the app sends them today (`toJson`).
- **`applyOp`**: given a strategy's rows and an op, the rows the server would
  hold after accepting it, the op that undoes it, and which rows and fields
  changed. It is a pure function of the two: the same rows and op always give
  the same result, ids included.
- **The store** (`LibraryStore`): where a library's rows live on the device,
  and the one way to save an edit. It runs on a `StorageEngine`.
  `MemoryEngine` is the one in this package; the engines for the app come
  separately and are held to the contract below.

## Rules it keeps

- **Every outcome is a value.** `applyOp` returns `OpApplied`, `OpUnchanged`
  or `OpRefused`, and a refusal says why: the server's rejection reason, the
  server's failure code, or `UnreadableTarget` with the key of the row this
  build cannot read. Nothing a user, the server or the disk can cause throws.
  An exception means a programmer error.
- **JSON is read once, at the edge.** Stored text goes through `admit`,
  which never throws: it returns `Admitted` with frozen JSON, or
  `NotAdmitted` with the text kept and why (not JSON, a number that is not
  finite, or nesting deeper than `maxJsonDepth`). Each row kind's `parse`
  takes an `Admission` and the ids the key gives, and always returns a row:
  readable, or its unreadable case holding what was stored. Every `decode`
  returns `Read` or `CouldNotRead`. Whole numbers must fit what JavaScript
  holds exactly, and times must fit a `DateTime`. `null` for an optional
  field means the field is absent.
- **Fields this build does not know, and the rule for keeping them.**
  Readable rows and the objects inside them (payload envelopes, page
  settings, the theme palette) keep the fields they did not read, and a row
  is rewritten from what was stored plus the fields the op changes
  (`rewritten`, `withData`), never rebuilt from typed fields alone:
  - An op that replaces a whole value replaces it, exactly as the server
    does: a page settings patch, a theme palette change, a payload written
    whole, a lineup item a merge names. The parity harness is the proof.
  - An op that merges fields keeps everything it does not name, at the row,
    the payload envelope and inside `data`.
  - Any write that is not the op's own target keeps the stored value as it
    was: the strategy row's `updatedAt` stamp, the rows a reorder renumbers,
    a summary rebuild, a page copy.
  - Summaries are disposable and rebuilt from rows, so they keep nothing.

  `test/store_fields_test.dart` checks the rule: for every op type it puts a
  probe field in every map of every stored row, runs the op, and compares
  each probe with a table of what is kept and what is replaced. For a whole
  element write, the fields `field_rules.dart` keeps (`assetId`, the later
  fields) must survive.
- **A row this build cannot read is carried, never touched.** An element
  whose kind is unknown, whose payload version is newer than
  `newestElementPayloadVersion`, whose data is not an object, or that the
  app's `canRead` check refuses is an `UnreadableElement`; any other row that
  does not decode is its kind's unreadable case. `canRead` answers and never
  throws. Every op aimed at one is refused with `UnreadableTarget`, including
  a delete. It keeps its id: an add under the id of an unreadable element on
  another page is refused. A page that cannot be read keeps its place when
  its `sortIndex` can be read: a page op that would have to move it is
  refused, and when its place cannot be read at all, every op that moves
  pages is refused. Deleting a page keeps its rows, as it keeps every row on
  the page; a page copy that would have to copy a lineup group or a non-JSON
  element this build cannot read is refused.
- **Applying an op predicts the server.** The meaning comes from
  `convex/ops.ts` and `convex/lib/fieldMerge.ts`: a patch with a `merge`
  writes only the named fields onto the row as it is now; a delete leaves a
  tombstone, and a deleted page keeps its content and its place; each
  accepted write raises that row's revision by one.
- **Applying an op twice gives the rows that applying it once gave.** The
  second time it is `OpUnchanged`.
- **Ids come from the op.** The undo op's id and the ids of rows a page copy
  creates are derived from the op's id (and, for a copy, the source row's
  id), so recomputing the base with its pending ops never renames anything.
  A derived copy id never takes the id of a row the strategy already has.
- **An undo names only what the op changed.** Undoing an edit to an agent's
  position writes the position back and leaves a teammate's change to its
  side alone.

## Where it differs from the server on purpose

- An op aimed at a row this build cannot read is refused here. The server
  would accept it, since it reads every kind.
- `copyContentFromPagePublicId` is read because shipped builds queued ops
  that carry it, but the store never writes it. A copy made on this device is
  a `page.add` followed by adds whose ids were chosen once, when the user
  acted. For an op that does carry the field, the copied rows get ids derived
  from the op, while the server picks random ones, so the copies match in
  content but not in id.
- This package sees one strategy. Ids that collide with a row in another
  strategy (`element_strategy_mismatch`, a page id used elsewhere) cannot be
  seen, and `strategy.patch` does not check map names.
- A page copy too large for the server's copy budget
  (`PAGE_TOO_LARGE_TO_COPY`) is applied here.
- A strategy patch that both sets and clears the same theme field, or a
  sort index that is not a whole number, is `CouldNotRead`. The server takes
  both; no build sends either.
- A delete of content on a page in the trash fails with `PAGE_DELETED`, as it
  does for clients that send `checkTrashedPageDeletes`, which the app does.
- Pages that share a place are ordered by `publicId` with Dart's string
  order. The server uses `localeCompare`, which can order punctuation
  differently.
- An edit that first sets `mapDoor`, `isZone` or a picture id (`assetId`)
  has `UndoUnavailable`. Those fields are never cleared (a door goes back to
  rest by deleting its row, a zone stays a zone, and the server keeps a
  picture id that a write leaves out), so there is no value an undo could
  write.
- Whole numbers of 9.2e18 or more that arrive as decimals compare and measure
  as Dart writes them, not as JavaScript does.
- Each op is applied alone. The server also lets several page ops queued from
  the same strategy revision land in one batch; that belongs to whoever sends
  batches.

## Merging an edit

Two people's edits to one item combine field by field, as
[collaborative-editing.md](../../docs/collaborative-editing.md) describes.
The package holds both halves:

- **The client's half.** `elementEdit` and `lineupEdit` say which fields an
  edit changed, as `FieldEdit`, or why it has to be written whole, as
  `WholeEdit` with a `WholeReason`. They compare payloads with each field's
  default filled in and treat a missing field and `null` as the same, so
  opening an old item never counts as an edit of it. `elementEditOp` and
  `lineupEditOp` build the patch: the item's page, field names, the place
  when it moved, and, for work that waited offline (`Connection.offline`),
  each field's value in the base. `drawn` says what the client drew:
  `DrawnAt(revision)`, the newest revision whose content it drew, which a
  whole write claims when it is older than the base's (once the client's own
  merge has landed, the row's newer revision also holds a teammate's fields
  the client has not drawn), or `BehindWholeWrite(revision)`, when a whole
  write of the item is still pending, so every edit after it is whole too and
  claims the same revision.
- **The server's half.** `mergeElementPayload` and `mergeLineupPayload` give
  the payload the server would hold, `Merged`, or say why it will not merge:
  `WriteWhole` with a `WholeReason`, or `MergeConflict` naming the field that
  changed since the base. `applyOp` uses them, then checks a merged lineup
  group the way the server checks any group.
- **The payload at the base.** `elementPayloadAtMergeBase` and
  `lineupPayloadAtMergeBase` give a payload with the merged fields set back
  to their base values: what the user's edit was drawn over.

## Field rules

`lib/src/field_rules.dart` is the one table of what the merge needs to know
about each element kind. The app's live sync reads it too.

| Rule | Kinds | Fields |
| --- | --- | --- |
| Identity keys: a merge never writes them, and an edit that changes one is written whole | every kind | `id`, `elementType`, `kind`, `type`, `data` |
| Moves together | agent, ability | `rotation`, `length` |
| Moves together | drawing | `listOfPoints`, `lineStart`, `lineEnd`, `start`, `end`, `boundingBox` |
| Moves together | text | `position`, `size`, `fontSize`, `sizeVersion` |
| Moves together | image | `position`, `scale`, `sizeVersion` |
| Moves together | utility of type `customRectangle` | `position`, `rotation`, `customWidth`, `customLength` |
| Moves together | any other utility | `rotation`, `length` |
| Kept when a write leaves it out, never cleared | every kind | `assetId` (the picture id), when it is a string |
| Later field, level 1, cleared by `""` | agent, ability, text, image, utility | `caption` |
| Later field, level 2, cleared by `[]` | ability | `wallPath` |
| Later field, level 3, never cleared | utility | `mapDoor` |
| Later field, level 4, never cleared | utility | `isZone` |
| Default when missing, inside `visualState` | any | `showVisionCone`: `true` |
| Default when missing, beside `state` | any | `weapon`: `"none"` |

A group is named whole when any field in it changes, so a teammate's half of
it never mixes with this edit's half. An undo names groups the same way. Only the fields the item holds are
named. A later field is one added after its kind shipped: the server hides it
from clients below its level and keeps it when a write leaves it out, so
clearing it means writing its empty value. That is also what undoing the edit
that first set it writes.

The server keeps its own copies of the identity keys
(`ELEMENT_IDENTITY_KEYS` in `convex/lib/fieldMerge.ts`) and the later fields
(`LATER_ELEMENT_FIELDS` in `convex/lib/elementFields.ts`) and the picture
id (`keepPictureId` in `convex/lib/imageAssets.ts`), because
`convex/` deploys on merge and has to keep reading the files it reads now.
`tool/library_parity/field_rules.test.ts` fails when either copy differs
from this table. Groups, empty values and defaults exist only on the client.

## Checked against the server

`node tool/library_parity/run.mjs` generates random op sequences
(`tool/parity_scenarios.dart`) and applies each op twice: with `applyOp`,
and with `ops:applyBatch` from `convex/ops.ts` under convex-test. It fails on
the first op whose outcome or rows differ, including a row either side holds
twice, a number JavaScript cannot hold exactly, or a server exception.

- **Payloads** come from `tool/library_parity/samples.json`. That file holds
  what the app's own move-to-cloud encoder writes for the canvas
  compatibility fixture, and `test/library_parity_samples_test.dart` fails when
  it goes stale (`UPDATE_PARITY_SAMPLES=1` rewrites it). Every element kind
  appears, as do folders and a drawing past the 8,000-entry limit.
- **The run checks itself.** It fails if a seed is missing or a sequence is
  short, or if any outcome listed in `run.mjs` is reached fewer times than its
  minimum. A 300-op run meets none of them.
  `node --test tool/library_parity/compare.test.mjs` proves that a duplicate
  row, a dropped sequence and thin coverage each fail.
- **Running it:** CI runs 24 fixed seeds of 150 ops. `--large` runs 150 seeds
  of 200. `--seed <n> --steps <s>` regenerates one sequence. `--counts`
  prints how often each outcome was reached.
- **Replaying a failure.** A failure writes its ops, with the Dart version
  and step count, to `build/library_parity/`, and prints
  `--replay <file>`, which applies those exact ops again whatever the Dart
  random stream does. Set `DART` to the Dart command when it is not `dart`
  (CI uses `fvm dart`).
- **Left out:** page copies, because their ids differ from the server's on
  purpose.

After the seeds, the run plays the merge stories in
`tool/merge_stories.dart` (`parity_scenarios.dart stories`), in their own
test: two people editing different fields, the same field online and after
one was offline, grouped fields, a later field set, cleared and undone,
edits that fall back to a whole write, and lineup group merges that end
valid and invalid. Each story's ops are built with `elementEditOp` and
`lineupEditOp`, and each says what the user should end up with. The run
fails when the server's outcome or rows differ from `applyOp`'s, and when
either differs from the story, and when a story is missing from the
report. `--replay` skips them. `test/merge_stories_test.dart` plays the same
stories through `applyOp` alone.

`tool/merge_seeds.dart` adds 12 seeded sequences on the stories' strategy,
weighted toward the cases a field merge exists for: offline edits of one
field sent with the rest of the payload as it was then, offline moves in the
stack from a place a teammate has since changed, for elements and lineup
groups, and whole writes from older builds that leave out the picture id
and the later fields. Generating fails when a seed run never produces one of
those (`mustGenerate`).

Default-aware comparison happens only on the client, so the server never
sees it. `tool/library_parity/cases/field_defaults.json` holds cases of it:
`test/field_defaults_cases_test.dart` checks which fields the client names,
and `tool/library_parity/field_defaults.test.ts` checks that the server
merges those fields into the expected payload.

## The store

### The engine contract

A `StorageEngine` grants a `StorageLease`; the store does all its reading
and writing through the lease it holds. An engine keeps these promises, and
`package:icarus_library/engine_contract.dart` checks them: `engineContract`
is a list of checks any engine runs against an `EngineHarness` it supplies
(`open` an engine on the harness's one storage, `close` it, `crash` it so the
app stops without closing, and `holdNextWrite`, which keeps the engine's next
commit pending until `letGo`). Each check returns `Passed` or `Broke(what)`.
This package runs them on `MemoryEngine` in `test/engine_test.dart`, along
with three broken engines the checks catch: one that loses writes in a
crash, one that grants everyone a lease, and one whose prefixes match like
SQL `LIKE`.

- **Names.** Areas and keys use only `nameAlphabet` (`a-z`, `0-9`, `-`, `.`,
  `/`, `_`); areas are at most `maxAreaLength` (64) characters. Names are
  compared exactly, a prefix matches exactly (no wildcards, no folding), and
  listings are in ascending code unit order. A lease's `maxKeyLength` is at
  least 255 and never changes for a given storage.
- **Names past the limit.** A commit that puts one is
  `CommitRefused(KeyTooLong)` and applies none of its changes; reading one is
  `KeyMissing`; deleting one changes nothing, since no such name can be
  stored.
- **Reading.** `read(area, key)` is `KeyHeld(value)`, `KeyMissing` or
  `KeyNotRead(failure)`. `keys(area, prefix)` lists names, `entries` lists
  them with their values.
- **Writing is one commit, and says whether it had an effect.**
  `commit(changes)` takes any list of `Put(area, key, value)`,
  `Delete(area, key)` and `ClearArea(area)` across any areas and applies all
  of them or none, also across a crash. It returns `CommitApplied`, which is
  on disk and survives a crash including power loss; `CommitRefused(failure)`,
  with a guarantee that nothing changed; or `CommitUnknown(failure)`, when the
  engine cannot know.
- **One writer at a time, for its whole life.** An engine grants one lease at
  a time for the storage under it, whichever engine object, process or tab
  asks: a second `lease()` is `HeldByAnotherWriter` until the first is
  released, also while the first holder's write is pending. A lease's
  `status` is `Holding` or `Ended`. It ends when its holder calls `release()`
  or its engine closes, and once ended it never works again: every call
  through it returns `LeaseEnded`, as `CommitRefused` for a commit, and
  changes nothing, even after another writer has come and gone, and even for
  a name past the limit. A commit pending when its lease ends either lands
  whole before the next lease is granted, or does not land; if the engine
  cannot tell which, it returns `CommitUnknown`.
- **Closing.** A lease asked for after `close` is `LeaseFailed(EngineClosed)`;
  one asked for during `close` is either refused that way or granted and then
  ended by the close.
- **Releasing** returns `Released`, or `ReleaseFailed(failure)` when the
  device failed while letting go. Either way the lease is ended for its
  holder; after `ReleaseFailed` the storage may still refuse a new lease
  until the engine closes or its process ends.
- **Failures are values.** Nothing the device does throws.

### Where rows are kept

| Area | Keys |
| --- | --- |
| `library` | `summary/<strategy>`, `folder/<folder>` |
| `journal` | `edit` (the edit being saved), `recovered/<attempt>` |
| `strategy/<sha1 of the strategy id>` | `strategy`, `page/<page>`, `settings/<page>`, `content/<page>/element/<id>`, `content/<page>/lineup/<id>` |

**Keys.** An id becomes a key segment by `encodeId`: unreserved ASCII
(`A-Z a-z 0-9 - . _ ~`) stays, everything else is its UTF-8 bytes as
uppercase `%XX`. An empty id or one holding a lone surrogate is not
storable. Reading a key back gives a typed meaning (`PageAt`, `ElementAt`,
`SummaryAt` and so on) only when every segment is canonical: it decodes as
strict UTF-8 (a leading U+FEFF stays) and encodes back to the same text.
Anything else is a `ForeignKey`, kept as its raw text. A foreign key is
never read as any row and never taken as an id. Foreign keys in the library
and journal areas are reported in `StoreOpened.foreignKeys`; those in a
strategy's area are reported in `StrategyContent.foreignKeys` and
`PageContent.foreignKeys`. Removing a strategy deletes everything in its
area, foreign keys included; foreign keys elsewhere stay where they are.

**Admission.** Before anything is written, every id an op names and every
row an edit writes is checked: an id that is not storable, or a key longer
than the lease's `maxKeyLength`, is refused with `IdNotStorable` and nothing
is written. The only keys the store writes that do not come from those ids
are fixed ones (`edit`, `strategy`, `recovered/` plus 32 hex characters), so
no save and no recovery can write a key the engine cannot hold. A saved
record whose writes name a key longer than the engine holds is refused at
open as `SavedEditUnreadable`.

**What a read costs.** Opening the store reads the journal area and the
library area with one `entries` call each, and nothing of any strategy.
Reading a strategy reads its row, lists every key of its area (so it knows
which page each element is on, and which keys are foreign), and reads its
pages and settings with one `entries` call each. Reading a page is one
`entries` call under `content/<page>/`. A read page stays in memory until
the store closes or `unload(strategy)` drops the strategy.

### Saving an edit

`commit(strategyPublicId, op)` loads the pages the op can look at, runs
`applyOp`, sets the strategy row's `updatedAt` to now, and then:

1. saves one record in `journal/edit` holding the op and every key the edit
   writes: each row it changed, the strategy row, a delete of the old key
   when an element moves page, and the strategy's new summary;
2. writes those keys;
3. clears the record.

When the store opens and finds a record, it writes the record's keys again,
writes `recovered/<receipt>`, and clears the record before reading anything.
Writing the same keys twice gives the same rows, so a crash at any step
leaves the rows from before the edit or the rows after it. Applying the op
again would not do: a page copy cut short leaves some copied rows behind,
and the copy applied to those rows gives different ids. Library edits
(`editLibrary`) and summary rebuilds are saved the same way, and a record is
never saved while an earlier one is unfinished.

Every save returns a `Saving`, which the caller has to handle:

- `Saved`: the record is on disk, so the edit survives a crash. If writing the
  rows or clearing the record failed, the store finishes the record before its
  next read or save, and again when it next opens.
- `NothingToSave`: the op changes nothing.
- `Refused`: `OpRefusal` when `applyOp` refused it, `NoSuchStrategy`, or
  `UnreadableRowInTheWay` when the strategy's own row cannot be read. For
  library edits: `StrategyAlreadyInStore` (also when any key is already
  stored for that strategy), `RowOutsideStrategy` (a row of an added strategy
  names another strategy or a page it does not have), `NoSuchFolder`,
  `FolderNotEmpty`, `FolderInsideItself`.
- `NotSaved`: nothing changed. The record could not be saved; or an earlier
  record could not be finished; or a key is longer than the lease's
  `maxKeyLength`, which is checked before anything is written; or the store
  has stopped (`StoreStopped`) or closed (`StoreClosed`).
- `SaveInDoubt`: the record's write failed and clearing it failed too, so
  the device may or may not hold it. The store stops. The result carries a
  `SaveReceipt`: the attempt id the store issued for this one save (128
  random bits, so it does not repeat on a storage) and when it was issued.
  The next store to open finishes the record if it landed and writes
  `recovered/<attempt>`. `recovered(receipt)` on that store, or any later
  one, answers `EditRecovered`, `EditNotRecovered`, or `RecoveryForgotten`
  once the receipt is older than `recoveryAnswerLifetime` (30 days); each
  open deletes markers older than that.

Saves and reads run one at a time, in the order they were called. `close`
releases the lease at once, whatever the `changes` listeners are doing, and
returns what the release returned; afterwards saves are
`NotSaved(StoreClosed)` and reads `NotRead(StoreClosed)`. A store whose lease
ended stops, and every later save and read says so.

**Folders.** Every walk over stored parent folders remembers where it has
been, so it ends on any data. A folder that would be filed, or a strategy
moved, under a stored loop is refused with `FolderLoop` naming the folders
in it; under a missing folder, `NoSuchFolder`; under a folder this build
cannot read, `UnreadableRowInTheWay`. Opening reads a loop as it is and
lists its folders.

### Reading

`readStrategy` and `readPage` return a `Reading`: `Found`, `NotFound`, or
`NotRead` when the device failed. A strategy whose own row cannot be read
still reads: `StrategyContent.strategy` is its `UnreadableStrategy`, and its
pages read as usual; edits to it are refused. Unreadable pages, settings,
elements and lineup groups come back in the same lists as readable ones; a
key under `content/<page>/` of a kind this build does not know comes back as
an `UnknownKindRow` with its text as stored. `library` is `LibraryOpen` with
the list (summaries, strategies whose own row cannot be read, folders), or
`LibraryShut` once the store has closed, stopped or lost its lease, so a
closed store never hands out data that looks current.

A page copy whose source page cannot be read, or holds a row of a kind this
build does not know or under a foreign key, is refused (`UnreadableTarget`,
`CopyLeavesRowsBehind`) rather than copied without them.

### Deleting

The store writes no key whose row it cannot read, with one exception:
`RemoveStrategy` deletes every key of the strategy, these rows included,
because the user asked for the whole strategy to go.

### Summaries

A `StrategySummary` holds the name, map, folder, created and updated times
(from the strategy row), live page count, `Sides` (attack, defend or mixed),
the agents placed on live pages, and how many items they hold. It also keeps
a tally per page, so trashing a page updates the counts without reading that
page. Every commit writes the new summary in the same record as its rows.
`rebuildSummary` recomputes it from the rows alone. When the store opens and
cannot read a summary, it rebuilds it; when the strategy's own row cannot be
read either, the strategy is listed in `unreadableStrategies`.

### Telling the editor what changed

`changes` is a stream of `StrategyEdited` (the strategy, the op id, the
`RowWrite`s with their changed fields and data fields, the rows removed, the
new summary) and `LibraryEdited`. It fires after the save, once per `Saved`.
A local commit never removes a row; `removed` is there for cloud strategies,
where the server rejecting a pending op can take a row away.

### Room for cloud strategies

Nothing for them is built here. What a local strategy reads and saves
through does not have to change for them: a cloud strategy's base can live
under the same `strategy/<strategy>` keys and its pending ops under their own
keys, read through a new call; `commit` keeps its signature and saves the op
as a pending op instead of clearing it; a change already names its op and
can name rows that are gone; and the record already saves any set of keys
across areas at once, so advancing the base and removing the acknowledged
ops is one more kind of record.

### Measuring it

`dart run tool/store_benchmark.dart` times opening the store and a
700-strategy library list, opening a 300-item page where half the items are
1000-point drawings (in a strategy not yet read, and in one already read),
and two commits on that page. `test/store_budget_test.dart` counts what each
of those asks the engine to read, list and write, and how many keys each
listing returns, and fails when a count grows; it includes a strategy of 20
pages with 300 items each.
