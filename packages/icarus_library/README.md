# icarus_library

The library's rows, the ops that change them, and what an op does to them.
It is pure Dart: no Flutter, no Riverpod, nothing from the app's `lib/`. The
decision behind it is [ADR 0009](../../docs/adr/0009-one-store-for-the-library.md);
the words it uses (Row, Element, Store, Base, Op, Pending op) are the ones in
[CONTEXT.md](../../CONTEXT.md).

## What it holds

- **Rows**, in the server's shape with public ids: `StrategyRow`,
  `FolderRow`, `PageRow`, `PageSettingsRow`, `ElementRow` and
  `LineupGroupRow`. A row's state is its type: a page is a `LivePage` or a
  `TrashedPage`, and a trashed page is either a `PendingTrashedPage`, deleted
  by an op the server has not confirmed, or a `ConfirmedTrashedPage` with the
  time and who deleted it (`DeletedByYou`, `DeletedByName`, or
  `DeleterUnknown` when the server has no name for them); an element is a `LiveElement`, a `DeletedElement` or an
  `UnreadableElement`; a lineup group is a `LiveLineupGroup` or a
  `DeletedLineupGroup`.
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
  and the one way to save an edit. It runs on a `StorageEngine`, which is
  `MemoryEngine` in tests and `HiveEngine` (from `hive_storage.dart`) in the
  app.

## Rules it keeps

- **Every outcome is a value.** `applyOp` returns `OpApplied`, `OpUnchanged`
  or `OpRefused`, and a refusal says why: the server's rejection reason, the
  server's failure code, or `UnreadableTarget`. Nothing a user or the server
  can cause throws. An exception means a programmer error.
- **JSON is read once, at the edge.** Every `decode` returns `Read` with a
  typed value or `CouldNotRead` with the JSON it was given, untouched.
- **A row this build cannot read is carried, never touched.** An element
  whose kind is unknown, whose payload version is newer than
  `newestElementPayloadVersion`, whose data is not an object, or that the
  app's `canRead` check refuses decodes as an `UnreadableElement` holding its
  row's JSON exactly. `ElementRow.decode` requires `canRead`, so the app's own
  decoder decides what it can draw; `canRead` answers and never throws. It is saved back byte for
  byte. Every op aimed at it is refused with `UnreadableTarget`, including a
  delete; deleting its page keeps it, as it keeps every row on the page.
- **Applying an op predicts the server.** The meaning comes from
  `convex/ops.ts` and `convex/lib/fieldMerge.ts`: a patch with a `merge`
  writes only the named fields onto the row as it is now; a delete leaves a
  tombstone, and a deleted page keeps its content and its place; each
  accepted write raises that row's revision by one.
- **Applying an op twice gives the rows that applying it once gave.** The
  second time it is `OpUnchanged`. The store saves an op together with its
  `OpApplied.writes` and, after a crash, writes those again; an op that is
  also applied again changes nothing.
- **Ids come from the op.** The undo op's id and the ids of rows a page copy
  creates are derived from the op's id (and, for a copy, the source row's
  id), so recomputing the base with its pending ops never renames anything.
  A derived copy id never takes the id of a row the strategy already has.
- **An undo names only what the op changed.** Undoing an edit to an agent's
  position writes the position back and leaves a teammate's change to its
  side alone.

## Where it differs from the server on purpose

- An op aimed at an `UnreadableElement` is refused here. The server would
  accept it, since it reads every kind.
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
- An edit that first sets a later field (`caption`, `wallPath`, `mapDoor`,
  `isZone`) has `UndoUnavailable`. The server keeps a later field that a write
  leaves out, so the undo would have to write the field's empty value, and
  this package does not know those yet.
- Whole numbers of 9.2e18 or more that arrive as decimals compare and measure
  as Dart writes them, not as JavaScript does.
- Each op is applied alone. The server also lets several page ops queued from
  the same strategy revision land in one batch; that belongs to whoever sends
  batches.

## The store

### Where rows are kept

A `StorageEngine` reads, writes, deletes and lists string keys inside a
named area. A write that returns `Done` is on disk; a write that fails may
have written some of its keys. Engines never throw for what the disk does:
they return `StorageFailed`. `HiveEngine` keeps each area in its own Hive box
in the directory the app passes (IndexedDB on the web):

| Area | Box | Keys |
| --- | --- | --- |
| `library` | held in memory | `summary/<strategy>`, `folder/<folder>` |
| `journal` | held in memory, compacted after every clear | `edit` |
| `strategy/<strategy>` | lazy: only keys are held | `strategy`, `page/<page>`, `settings/<page>`, `content/<page>/element/<id>`, `content/<page>/lineup/<id>` |

Ids are URI-encoded inside keys. Opening the store reads the journal, the
summaries and the folders, and nothing of any strategy. Reading a strategy
reads its row, its page rows and its page settings, and lists the keys under
`content/` so the store knows which page each element is on. Reading a page
reads only the keys under `content/<page>/`. A page read stays in memory for
as long as the store is open.

### Saving an edit

`commit(strategyPublicId, op)` loads the pages the op can look at, runs
`applyOp`, and then:

1. saves one record in `journal/edit` holding the op and every key the edit
   writes: each row in `OpApplied.writes`, a delete of the old key when an
   element moves page, and the strategy's new summary;
2. writes those keys;
3. clears the record.

When the store opens and finds a record, it writes the record's keys again
and clears it before reading anything. Writing the same keys twice gives the
same rows, so a crash at any step leaves the rows from before the edit or the
rows after it. Library edits (`editLibrary`) are saved the same way.

Every save returns a `Saving`, which the caller has to handle:

- `Saved`: the record is on disk, so the edit survives a crash. If writing the
  rows or clearing the record failed, the store finishes the record before its
  next read or save, and again when it next opens.
- `NothingToSave`: the op changes nothing.
- `Refused`: `OpRefusal` when `applyOp` refused it, `NoSuchStrategy`, or
  `UnreadableRowInTheWay` when the edit would write over a row this build
  cannot read. For library edits: `StrategyAlreadyInStore`, `NoSuchFolder`,
  `FolderNotEmpty`, `FolderInsideItself`.
- `NotSaved`: the record could not be saved and nothing changed. Also
  returned for later saves while an earlier record cannot be finished, or
  after the store has stopped (`StoreStopped`).
- `SaveInDoubt`: the record could not be saved and could not be cleared
  either, so the disk may or may not hold it. The store stops: every later
  save is `NotSaved(StoreStopped)`. Reopening settles it: a record that did
  land is finished, so the edit is there; one that did not leaves the rows as
  they were.

Saves and reads run one at a time, in the order they were called. Only one
`LibraryStore` can be open on an engine at a time; a second `open` returns
`StoreNotOpened(StoreAlreadyOpen)` until the first is closed. After `close`,
saves are `NotSaved(StoreClosed)` and reads are `NotRead(StoreClosed)`. Hive
names its boxes without the directory, so only one `HiveEngine` can hold the
store's boxes in a process; any other gets `StorageFailed` until it closes.
Before a record is saved, every key in it is checked against the engine's
`maxKeyLength` (255 for Hive), and an edit with a longer key is `NotSaved`
with `KeyTooLong`, so a record the engine can never replay is never written.

### Reading

`readStrategy` and `readPage` return a `Reading`: `Found`, `NotFound`,
`Unreadable` when the strategy's own row cannot be read, or `NotRead` when
the device failed. `library` is the list in memory: one `StrategySummary` per
strategy, the folders, and any summary or folder row this build cannot read.

### Rows this build cannot read

A key whose text is not JSON, whose row does not decode, whose row names
another key, or whose kind under `content/<page>/` is unknown is carried as an
`UnreadableRow`: its area, key, text exactly as stored, and why. An element
that decodes as an `UnreadableElement` stays in `PageContent.elements`. The
store never writes a key that holds a row it cannot read: an edit that would
is refused with `UnreadableRowInTheWay`, and `AddStrategy` is refused when
any key is already stored for that strategy. The one exception is
`RemoveStrategy`: the user deleting a strategy deletes every key it has,
these rows included. Rows are written as canonical JSON of `toJson()`.

### Summaries

A `StrategySummary` holds the name, map, folder, created and updated times,
live page count, `Sides` (attack, defend or mixed), the agents placed on live
pages, and how many items they hold. It also keeps a tally per page, so
trashing a page updates the counts without reading that page. Every commit
writes the new summary in the same record as its rows. `rebuildSummary`
recomputes it from the rows, keeps the times since no row holds them, and
saves it through a record like any edit.
When the store opens and cannot read a summary, it rebuilds it from the
strategy named by the summary's `publicId`, taking `createdAt` and
`updatedAt` from it when they are whole milliseconds. A later summary version
must keep those three fields; a summary without them is listed as
unreadable. A record is never saved while an earlier one is unfinished.

### Telling the editor what changed

`changes` is a stream of `StrategyEdited` (the strategy, the `RowWrite`s with
their changed fields and data fields, the undo, the new summary) and
`LibraryEdited`. It fires after the save, once per `Saved`.

### Measuring it

`dart run tool/store_benchmark.dart` times opening a 500-strategy library
list, opening a 300-item page where half the items are 1000-point drawings,
and two commits on that page, on both engines. `test/store_budget_test.dart`
counts the keys each of those touches and fails when the count grows.

