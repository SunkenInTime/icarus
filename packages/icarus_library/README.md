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
- **JSON is read once, at the edge, and never copied on the way in.**
  Stored text goes through `admit`, which never throws. One scan of the
  text refuses nesting deeper than `maxJsonDepth`, a whole number
  JavaScript cannot hold exactly, and an exponent over 400, which the VM's
  JSON decoder reads as zero or infinity whatever the digits. It also sorts
  every other number into ordinary, the spellings Dart and JavaScript write
  (at most 17 significant digits, at most 21 integer and 22 fraction
  digits, and an exponent only after one integer digit, from -324 up to a
  value of at most the largest double), or unusual. Then `jsonDecode` runs
  once. A row with only ordinary numbers is handed on as it is; a row with
  an unusual one gets one walk over the decoded tree, without a copy, that
  refuses a number that is not finite. The answer is `Admitted`, or
  `NotAdmitted` with the text kept and why. A row holding a number token it
  refuses is unreadable with its text kept, even when a later duplicate key
  would replace that value; no build writes duplicate keys.
- **Rows stay values by type.** Every JSON value a row holds (payload
  `data`, `unknownFields`, an unreadable row's `stored`) is a `JsonObject`
  or a `JsonList`. Neither is a `Map` or a `List`: they offer reads only,
  and a nested object or list read from them is again a `JsonObject` or
  `JsonList`. The decoded tree under them is reachable only through
  `JsonObjectInside.raw` and `JsonListInside.raw`, which `src/json.dart`
  defines and `icarus_library.dart` does not export; the package's own
  decoders, merges and copies use them, and must not change what they reach.
  A caller that needs a value it can change asks for a copy: `toMap()` is a
  shallow copy whose nested values stay read-only, and anything named
  `toJson()`, on a view, a row, a payload, an op or a merge, returns plain
  maps and lists all the way down, a fresh copy each time. `toJsonView()`
  returns fresh maps whose nested values are read-only views, for encoding
  and comparing without a copy. `FieldMerge.base` is a `JsonObject`.
  `withFieldDefaults` fills defaults in a view as it does in a plain map. A row or payload built
  from a caller's map copies that map once, at construction, and adopts any
  `JsonObject` or `JsonList` inside it without copying.
  `test/rows_stay_values_test.dart` tries every way in. Each row kind's `parse`
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
  - A deleted row's payload is whatever the last write left there, and is
    not part of what undo restores: undoing an add over a deleted element
    or lineup group deletes it again with the added payload, as the server
    does.
  - Extra fields in a payload envelope are kept by merges and rewrites, but
    they are not a reason to save: a whole write that differs only there is
    `NothingToSave`, because the server's validators allow no extra envelope
    fields at all.

  `test/store_fields_test.dart` checks the rule: for every op type it puts a
  probe field in every map of every stored row, runs the op, and compares
  each probe with a table of what is kept and what is replaced. For a whole
  element write, the fields `field_rules.dart` keeps (`assetId`, the later
  fields) must survive.
- **A row this build cannot read is carried, never touched.** An element
  whose kind is unknown, whose payload version is newer than
  `newestElementPayloadVersion`, whose data is not an object, or that the
  app's `canRead.element` check refuses is an `UnreadableElement`; a lineup
  group that breaks the server's graph rule or that `canRead.lineupGroup`
  refuses is an `UnreadableLineupGroup`; any other row that does not decode
  is its kind's unreadable case. Readable means the package's structural
  rule and the app's decoder both accept the row. `canRead` answers and
  never throws. Every op aimed at one is refused with `UnreadableTarget`, including
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
with broken engines the checks catch: one that loses writes in a crash, one
that grants everyone a lease, three whose prefixes match like SQL `LIKE`
(in `keys`, `entries` and `areas`), one that cuts a delete past the limit down onto a
valid name, one that applies part of a commit and answers
`CommitUnknown`, and a small test engine (`test/sloppy_engine.dart`) that
keeps the whole contract until one flaw is switched on: a lease granted to
two callers asking at once, or to a caller that asks a microtask after a
reservation expires; a held write that lands after its engine closed, or
after its lease was released; a commit cut short by a crash that leaves its
first change; a held write that, once the next holder has saved, puts back
the value it found; or areas listed in the order they were made.

The suite is a floor. It runs in one isolate with a few chosen timings, so
it cannot prove that an engine admits one writer under every timing; each
engine carries its own tests with real concurrency, real processes for
SQLite and real tabs or workers for IndexedDB. Every commit a check makes is compared with storage before
and after it: `CommitApplied` must show every change, `CommitRefused` none,
and `CommitUnknown` all or none, never part.

- **Names.** Areas and keys are non-empty and use only `nameAlphabet`
  (`a-z`, `0-9`, `-`, `.`, `/`, `_`); areas are at most `maxAreaLength`
  (64) characters. Names are compared exactly, a prefix matches literally
  (`_`, `-` and `.` are ordinary characters), and listings are in ascending
  code unit order. A storage's `maxKeyLength` is at least 255 and never
  changes; it belongs to the storage, not to an engine object.
- **A commit naming a bad name is refused whole.** A `Put`, `Delete` or
  `ClearArea` naming anything outside the alphabet is
  `CommitRefused(NameNotAllowed)`; a key past the limit, whether put or
  deleted, is `CommitRefused(KeyTooLong)`. Either way none of the commit's
  changes apply, so a delete past the limit never touches a valid name.
  Reading a name past the limit is `KeyMissing`.
- **Reading.** `read(area, key)` is `KeyHeld(value)`, `KeyMissing` or
  `KeyNotRead(failure)`. `keys(area, prefix)` lists names, `entries` lists
  them with their values, and `areas(prefix)` lists the areas that hold at
  least one name, under the same rules: the prefix matches literally and
  the list is in ascending code unit order (`compareCodeUnits`). An area
  whose last name was deleted or that was cleared is not listed.
- **Writing is one commit, and says whether it had an effect.**
  `commit(changes)` takes any list of `Put(area, key, value)`,
  `Delete(area, key)` and `ClearArea(area)` across any areas, applies them
  in list order, and applies all of them or none, also across a crash. An
  empty commit applies and changes nothing. It returns `CommitApplied`,
  which is on disk and survives a crash including power loss;
  `CommitRefused(failure)`, with a guarantee that nothing changed; or
  `CommitUnknown(failure)`, meaning all or none applied and the engine
  cannot say which.
- **One writer at a time, for its whole life.** An engine grants one lease at
  a time for the storage under it, whichever engine object, process or tab
  asks: a second `lease()` is `HeldByAnotherWriter` until the first is
  released, also while the first holder's write is pending. A lease's
  `status` is `Holding` or `Ended`. It ends when its holder calls `release()`
  or its engine closes, and once ended it never works again: every call
  through it answers `LeaseEnded` before any other check (a bad name, a
  name past the limit), as `CommitRefused` for a commit, and changes
  nothing. Callers asking at nearly the same moment (in the same turn, a
  microtask apart, a timer tick apart) get one lease between them. A commit pending when its lease ends, by release, by the engine
  closing or by a crash, either lands whole before the next lease is
  granted, or does not land. The suite holds a write, ends its lease, waits
  for the ending or 200 ms, asks for the next lease and waits for its
  answer, looks at storage and writes through the new lease if it was
  granted, and only then lets the held write go; it looks again after, and
  everything the next holder saved must still be there.
- **Closing.** A lease asked for after `close` is exactly
  `LeaseFailed(EngineClosed)`; one asked for during `close` is either
  refused that way or granted and then ended by the close.
- **Releasing** returns `Released`, or `ReleaseFailed(failure)` when the
  device failed while letting go. Either way the lease is ended for its
  holder; after `ReleaseFailed` the storage may still refuse a new lease
  until the engine closes or its process ends.
- **Failures are values.** Nothing the device does throws.

### The engines

| Where | Engine | Import |
| --- | --- | --- |
| Windows, macOS, Linux | `SqliteEngine(path)` | `package:icarus_library/sqlite_storage.dart` |
| Web | `IndexedDbEngine(name)` | `package:icarus_library/indexed_db_storage.dart` |
| Tests | `MemoryEngine(storage)` | `package:icarus_library/icarus_library.dart` |

Both real engines pass `engineContract`: `test/sqlite/sqlite_engine_test.dart`
runs it on real files, `test/sqlite/sqlite_fault_test.dart` on a disk that
loses power, and `test/indexed_db/indexed_db_engine_test.dart` in Chrome and
Firefox.
Each engine keeps every area in one table or object store keyed by area and
key, so one commit can change any number of areas inside a single database
transaction. That transaction is what makes a save all or nothing.

#### SQLite

The library is one file holding one table, `rows (area, key, value)`, keyed by
area and key, plus a one-row table `generation`. The key column uses SQLite's
default binary collation, so names compare exactly and case-sensitively, and a
prefix is the range from the prefix up to the next string after it. The engine
runs no other SQL: no domain logic, no ORM. It uses `package:sqlite3`, which
bundles SQLite as a native library through build hooks, so the app needs no
build step of its own. The version is held below 3.6 because later ones need
a `hooks` package newer than Flutter 3.44.4 allows.

- **A commit is one transaction.** `BEGIN IMMEDIATE`, every put, delete and
  area clear, then `COMMIT`. A failure before `COMMIT` rolls back and is
  `CommitRefused`: nothing reached the log with a commit mark, so nothing can
  come back. A failure at or after `COMMIT` is `CommitUnknown`, because the
  log may hold the transaction.
- **Durability.** The file is in write-ahead log mode with
  `synchronous = FULL`: SQLite syncs the log before `COMMIT` returns. On the
  fault disk below, every commit that returned `CommitApplied` survived every
  modelled power cut, and in `NORMAL` 48 did not. Whether a real drive keeps a
  synced write through a power cut depends on the drive honouring the sync,
  which nothing here tests. On macOS `fullfsync` is on, because a plain sync
  there does not flush the drive's cache.
- **One writer.** The connection takes an exclusive lock on the file and holds
  it until the lease is released (`locking_mode = EXCLUSIVE`). Another
  connection in any isolate or process gets `SQLITE_BUSY`, which the engine
  returns as `HeldByAnotherWriter`. Two openers at the same moment can each
  take a shared lock and then both fail to upgrade it, so a refused open
  closes its connection and tries again, 2 to 22 ms apart, for up to 250 ms;
  one of them wins and the rest are refused. Exclusive mode also means SQLite
  keeps the log's index in memory, not in a shared `-shm` file.
- **Off the UI thread.** SQLite's API blocks, so each lease runs it on its own
  isolate and answers one request at a time, in order. A release is queued
  behind the commits already sent, so they land before the lock is let go. If
  that isolate dies, every call waiting on it gets a value: a commit is
  `CommitUnknown`, a read is a failure. A killed isolate still lets go of the
  file: the Dart VM runs its native finalizers as it shuts down, and
  `package:sqlite3` attaches `sqlite3_close_v2` to every connection. A test
  kills the worker while it holds the lease and leases the file again at once,
  from the same process and from another.
- **Opening checks the whole file.** `PRAGMA integrity_check` runs on every
  open. The quicker `quick_check` let a library with flipped bits open with
  8 of 41 strategies missing and no error; `integrity_check` also compares
  each index with its table and refuses that file.
- **Creating a library** happens in the library file itself. A file with
  no tables and no application id has not been created yet, whether the open
  just made it or an earlier creation was cut short, and the open creates it:
  in rollback-journal mode with `synchronous = FULL`, one `BEGIN EXCLUSIVE`
  transaction makes both tables and sets the identity, then the open checks
  the file and switches it to write-ahead logging. SQLite applies that
  transaction whole or not at all, so a creation cut short leaves an empty
  file (or a hot journal that rolls back to one), and the next open creates it
  again. Two creators are kept apart by SQLite's own lock on the file: the
  second is refused and retries, then finds the library held. A file that is
  not SQLite, another program's database or from a newer build is refused. A
  file emptied to nothing is taken for a creation cut short and created again,
  because the two cannot be told apart.
- **After an unknown commit** the log can still hold that transaction's
  frames, and they would come back on the next open. So the next transaction
  that succeeds also bumps `generation`; it writes over those frames, and from
  then on the unknown commit can never return.
- **Failures.** A full disk, an I/O error, a locked or unreadable file is a
  `DeviceFailure` naming SQLite's error code. SQLite can describe damage with
  bytes that are not UTF-8; `package:sqlite3` throws a `FormatException` for
  that, and the engine returns it as a failure too.
- **Listing areas** jumps from area to area through the primary key:
  `min(area)` above the last one found, one index seek per area, so a large
  area costs no more than a small one.
- **Names are checked before anything is written.** A commit whose put,
  delete or area clear names anything outside the alphabet is
  `CommitRefused(NameNotAllowed)`, and one with a key past 1024 characters is
  `CommitRefused(KeyTooLong)`; none of its changes apply. Reading a name past
  the limit is `KeyMissing`.
- **File names.** A path ending in `-wal`, `-shm` or `-journal`, in any case,
  is refused with an `ArgumentError`, because SQLite uses those names for
  another library's files.
- **Closing** waits for leases still opening, ends every lease the engine
  granted, and returns `ReleaseFailed` if any release failed. Closing twice
  returns the first close's answer. The engine grants
  no more (`LeaseFailed(EngineClosed)`). Releasing a lease twice returns the
  first release's answer.
- **When storage is gone.** A missing library file with no log or journal
  beside it is created as a new, empty library and the lease is granted; the
  engine cannot tell a first start from a file deleted by the user or a
  cleaning tool. A missing file whose `-wal` or `-journal` remains is refused
  as a `DeviceFailure`. The engine looks for those first and the library file
  second, so a process that looks while another creates the library is not
  refused by mistake.
- `SqliteEngine.holdNextCommit()` parks the next commit on the worker isolate
  until it is let go, for the contract's pending-write checks. If the worker
  stops first, the hold is released so a test waiting on it cannot hang.
- Switching a checkout between a branch with `sqlite3` and one without can
  leave Flutter's hook cache pointing at a deleted download
  (`install_code_assets failed`). Deleting `.dart_tool/hooks_runner` and
  `.dart_tool/flutter_build` fixes it.

#### IndexedDB

The library is one database named by the caller, with one object store,
`rows`, whose keys are `[area, key]`. IndexedDB compares those arrays by code
unit, exactly, and a prefix is a key range from `[area, prefix]` up to the
next string after the prefix. There is no SQLite and no WebAssembly on the
web.

- **A commit is one `readwrite` transaction** holding every put, delete and
  area clear (a delete over the area's key range). It is `CommitApplied` when
  the transaction fires `complete`, never on a request's `success`. An
  `abort` is `CommitRefused` naming the browser's error, with one exception:
  an abort for `QuotaExceededError` is `CommitUnknown(AbortedForQuota)`.
  Firefox can keep part of a transaction that aborted on quota: requests
  queued after the failing put still take effect
  ([bug 2080749](https://bugzilla.mozilla.org/show_bug.cgi?id=2080749)).
  Through this engine in Firefox 160, before the room check below existed, it
  happened in 5 runs out of 5: the aborted commit's delete and its last put
  were in the database afterwards. The engine tells a quota abort from other
  aborts by `transaction.error.name` alone.
- **Room is checked before a commit.** The engine asks the browser for
  `navigator.storage.estimate()` when it leases, subtracts what each applied
  commit is estimated to take (two bytes per character of area, key and value,
  plus 1 KiB per change), and refuses a commit that would leave less than
  1 MiB: `CommitRefused(NoRoomForCommit)`, with nothing written. It asks again
  in the background when the last answer is over 10 s old, and waits for a
  fresh answer only when the cached one says the commit will not fit, so a
  save never waits on the browser for this. Measured in Chrome 157 and
  Firefox 160 (`tool/estimate_web.dart`): `estimate()` answers in about 1 ms,
  and it already counts a write that completed just before, at 1.0 to 1.2
  bytes per character, so a fresh answer never forgets the engine's own
  writes. In Firefox with its quota capped (`tool/firefox_page.sh
  tool/quota_abort_web.dart 4096`), the commit that used to be partly kept is
  refused with nothing written, and filling the database ends in a refusal,
  never an abort. With the room check, a quota abort needs something else in
  the same origin to take the room between the estimate and the commit.
- **A full disk is a quota abort in Firefox.** Firefox does not lower its
  reported quota as the disk fills, so the room check cannot see a full disk
  coming. Staged on a nearly full tmpfs (`tool/disk_full_web.sh`), Firefox
  aborted with `QuotaExceededError` in 4 runs out of 4, and every time it
  rolled the whole commit back. The engine answers it
  `CommitUnknown(AbortedForQuota)` all the same. No other kind of abort was
  staged in Firefox for real; that other aborts roll back whole is the spec's
  promise, checked here only with aborts the test itself starts.
- **Why a commit in doubt is tolerable today, and when it stops being so.**
  The web build is cloud only (`lib/config/platform_policy.dart`: `webBeta`
  has `allowsLocalLibrary: false`), so everything the web store holds is a
  copy of server rows plus pending ops, and a pending op is one row, present
  or absent. The store reports the commit as `SaveInDoubt` carrying
  `AbortedForQuota` and shuts. The app does not use the store yet; when it
  does, it must re-read the strategy from the server after a save in doubt,
  which repairs a partly applied copy. The day the web build allows a local
  library, there is no server copy to repair from: the engine then needs
  before-images to undo a partly kept commit, or it must not be used on the
  Firefox versions with this bug.
- **Whatever is thrown is answered.** A lease that throws anything while it
  asks for the lock, opens the database or checks it is `LeaseFailed`, and
  the database is closed and the lock let go. An open that the browser keeps
  waiting (behind another tab's blocked upgrade or delete) gives up after
  10 s. A put that throws while the commit is queued aborts it and answers
  `CommitRefused`; if the abort throws too, the answer is `CommitUnknown`.
  A read whose callback throws is a failure, never a caller left waiting.
- **Values must be text.** A stored value that is not a string, `null`
  included, is a failure to `read` and to `entries` alike.
- **Durability.** Every transaction asks for `durability: 'strict'`, and the
  engine refuses to open where a probe transaction does not read back
  `durability` as `strict`: a browser without the property, or older than the
  option. A database the refused lease created is deleted again. The probe
  checks what the browser reports, not what it does, and Firefox 126 to 128
  report `strict` without acting on it differently (below). What strict does
  differs by browser:
  - Chrome has had the option since 83 ([chromestatus](https://chromestatus.com/feature/5730701489995776)).
    Strict flushes to disk before `complete`. Strict was the default until
    121, which made `relaxed` the default ([Chrome blog](https://developer.chrome.com/blog/indexeddb-durability-mode-now-defaults-to-relaxed)).
  - Firefox has had the option since 126 ([bug 1878143](https://bugzilla.mozilla.org/show_bug.cgi?id=1878143)).
    Durability hints set SQLite's `synchronous` mode since 129 ([bug 1883045](https://bugzilla.mozilla.org/show_bug.cgi?id=1883045)).
    In today's source, strict runs the transaction with `synchronous = EXTRA`,
    and the default with `NORMAL`, or `FULL` when the
    `dom.indexedDB.fullSynchronous` setting is on ([ActorsParent.cpp](https://searchfox.org/mozilla-central/source/dom/indexedDB/ActorsParent.cpp)).
  - Safari has had the option since 15 ([WebKit commit](https://github.com/WebKit/WebKit/commit/73adacdf77de005d4ce54729996f6c841e5c9a54)).
    After a strict transaction commits, WebKit runs a full checkpoint of its
    SQLite log. It ignores the checkpoint's result, so a checkpoint that
    fails still reports the transaction complete ([SQLiteIDBBackingStore.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/Modules/indexeddb/server/SQLiteIDBBackingStore.cpp)).

  None of this has been checked by cutting power; it is what each browser's
  source and notes say it attempts. So the engine promises only that the
  browser said `complete` for a strict transaction.
- **What the browser can take away.** In a private window the browser can
  discard the whole database when the session ends. Under storage pressure it
  can evict the origin's data, and a user can clear site data. In each case
  the next open finds no database, creates an empty one and grants the lease:
  the engine reports nothing, because it cannot tell that from a first visit.
  The store then sees an empty library. The engine does not ask for
  persistent storage (`navigator.storage.persist()`).
- **On a page only.** The engine reaches IndexedDB and Web Locks through
  `window`, so it runs on a page, not in a worker.
- **One writer per origin.** A lease holds a Web Lock named after the
  database, taken with `ifAvailable`, so another tab, frame or worker gets
  `HeldByAnotherWriter` at once. The lock is released when the lease is, or
  when the tab closes or crashes. A page without Web Locks (a plain `http`
  origin that is not `localhost`) cannot hold the library and gets
  `LeaseFailed`.
- **Release waits for commits in flight**, then closes the database and lets
  go of the lock. The browser would order them anyway: a transaction started
  by the next holder waits for every overlapping transaction created before
  it.
- **Names** follow the same rules as SQLite, checked before the transaction
  starts.
- **Listing areas** walks a key cursor and, at each area, continues to
  `[area, []]`, which sorts after every key of that area, so it lands on the
  next area's first row without reading the rest.
- **The lease ends with the database.** An upgrade from another tab, a delete
  of the database, or the browser closing the connection itself ends the
  lease, and every later call answers `LeaseEnded`. A lock request the
  browser rejects fails the lease. A database name starting with `-` is
  refused with an `ArgumentError`, because Web Locks reserve those names.
- **Closing** waits for leases still opening, ends every lease and grants no
  more. Releasing twice returns the first release's answer.
- `IndexedDbEngine.holdNextCommit()` parks the next commit before its
  transaction starts, counted as a commit in flight.

#### What the tests simulate, and what they cannot

- `test/sqlite/fault_disk.dart` is a SQLite virtual file system over a disk
  held in memory. It keeps what reached the disk apart from what was only
  written: a sync makes a file durable, and creating, deleting or renaming a
  file is durable only after a directory sync (SQLite asks for one when it
  creates a log). It can stop the app at any step, fail a sync and drop what
  that sync was for, fill the disk, and lock a file against a second
  connection. A crash then loses power in one of three ways: keeping
  everything written (the app died, the OS did not), dropping everything
  unsynced, or keeping a random part of it in 512-byte pieces and a random
  prefix of directory changes (writes reordered and torn). It cannot show a
  drive that reports a sync it did not do, a torn write inside one 512-byte
  piece, or how a real file system orders its metadata. Power loss is tested
  only on this model, never on real files. On it, creating the library is cut
  at every step and at every failed sync, under every loss: each time the next
  open has the library with its tables, and a save acknowledged after it
  survives another power cut.
- `test/sqlite/sqlite_engine_test.dart` uses real files and real processes:
  a second isolate and a second process are refused the lease, commits in
  flight when one process releases land before another process gets the
  lease, and a writer process is killed at 24 random points and the library
  reopened in this one. Each kill checks that a commit across three areas,
  including an area clear, is wholly there or wholly absent. A killed process
  is not a power cut: the operating system still writes what the process had
  written.
- `test/indexed_db/indexed_db_engine_test.dart` runs in Chrome and Firefox
  (CI runs Chrome). It aborts a transaction after its first request
  succeeded, including a commit across three areas with an area clear,
  reports a quota error (by patching `IDBObjectStore`), makes a put throw
  while it is queued (a `DOMException` and a plain error), makes the abort
  after it throw, rejects a lock request, makes opening throw before and
  after the database opens, keeps an open waiting behind a blocked delete,
  drops the durability option and hides the property, makes a cursor key
  throw, stores values that are not text, reports a small room left
  (by patching `StorageManager.estimate`), upgrades, deletes and
  force-closes the database under a lease, refuses a second lease on the
  origin, and hands the library to a worker while commits are in flight. The
  structured-clone failure is staged by patching `put`, not caused by a real
  value. It cannot crash the browser, cut its power, or run Safari. The real
  quota and full-disk runs in Firefox are tools run by hand
  (`tool/firefox_page.sh`, `tool/disk_full_web.sh`), not part of the suite.
- `test/memory_crash_test.dart` runs the same crash checks on `MemoryEngine`.

The crash checks are in `test/crash_harness.dart`. For the store: after a
crash at every step of every op type, the rows are those from before the edit
or after it, a `Saved` edit is never lost, a `NotSaved` one never appears, and
reopening can itself be cut short. For the engine: random commits
across areas with puts, deletes and area clears, crashed at a random step;
every applied commit is there, a refused one left nothing, an unknown one is
wholly there or wholly absent, and no other row changed.

### Where rows are kept

| Area | Names |
| --- | --- |
| `library` | `summary/<s>`, `folder/<f>` |
| `s/<s>` | `strategy`, `page/<p>`, `settings/<p>`, `content/<p>/e/<e>`, `content/<p>/l/<l>` |

**Names.** Each `<x>` is `digestOf(id)`: the SHA-256 of the id's UTF-16
code units (little-endian), cut to its first 32 hex characters (128 bits).
Any id can be stored, including an empty one or one holding a lone
surrogate, and every name has a fixed length. The longest is an element
name, `longestName` (75) characters; the store checks the lease's
`maxKeyLength` against it once, at open, and does not open
(`EngineTooSmall`) on an engine that cannot hold it.

**Ids come from the value, never from the name.** A row's id is kept in its
value, and each parse returns `Placed(row)` or `Unplaced`. A row is placed
when every id it carries is known: its own id from its value, when that id
has the digest its name holds; a parent's id (the page of an element, the
strategy of a page) from its value the same way, or else from the parent
row the store already read. A row whose own id cannot be known that way is
an `UnplacedRow`: its `StoredRowRef` (area and name), its stored value and
the problem. No field typed as a public id ever holds a name. Unplaced rows
come in their own lists (`LibraryList.unplaced`, `StrategyContent.unplaced`,
`PageContent.unplaced`); lists and maps of rows keyed by id hold only placed
rows. Every lookup by id goes through one function per row kind, which
returns the row under that id's name only when the id inside it is that id.

A strategy whose own row cannot be read, and whose summary cannot be read
or rebuilt, is listed in `LibraryList.unreadableStrategies` as an
`UnreadableStrategyListing`: its `StrategyRef` and its header as parsed.
`RemoveUnreadableStrategy(ref)` removes it; `RemoveStrategy(id)` removes
one whose id is known.

A name of any other shape is a `ForeignName`, kept as it is and never read
as a row. The store reads only the library area and the areas of strategies
it lists (there is no call that lists areas), so `foreignNames` covers those
areas only: `StoreOpened.foreignNames` for the library area,
`StrategyContent.foreignNames` and `PageContent.foreignNames` for a
strategy's. A name under `content/<p>/` of a kind this build does not know
is an `UnknownKindRow`. Removing a strategy clears its whole area, foreign
names included.

**What is admitted.** Stored text goes through `admit`, which scans it once
before decoding: nesting deeper than `maxJsonDepth`, or a whole-number
token outside the range JavaScript holds exactly (anywhere in the text,
fields this build does not know included), makes the row unreadable with
its text kept. So the VM and the web read the same rows the same way, and
a rewrite can never save a number the web rounded.

**One place commits.** Exactly one function in the store calls
`lease.commit`. It takes typed writes (a row, a summary, a delete, a clear),
encodes each, and parses the text back with the parser its name's kind
dictates, summaries included; a value that cannot be encoded (a number
that is not finite) and one that would read back differently are the same
`NotSaved(WouldNotReadBack)`, and nothing is written. A commit names each
(area, name) at most once: when an edit writes one twice, the last write
is kept.

**What a read costs.** Opening the store lists the library area with one
`entries` call and reads nothing of any strategy, when every summary is
readable; each summary it cannot read costs a read of that strategy and
all its pages, to rebuild it. Reading a strategy reads its row, lists
every name in its area (so it knows which page each element is on, and
which names are foreign), and reads its pages and settings with one
`entries` call each. Reading a page is one `entries` call under
`content/<p>/`. A read page stays in memory until the store closes or
`unload(strategy)` drops the strategy.

### Saving an edit

`commit(strategyPublicId, op)` loads the pages the op can look at, runs
`applyOp`, sets the strategy row's `updatedAt` to the later of now and its
current value, and sends one engine commit holding a `Put` for each row it
changed, a `Delete` of the old name when an element or lineup group moves
page, and a `Put` of the strategy's new summary. The engine applies a
commit whole or not at all, across areas and across a crash, so the disk
holds the strategy from before the edit or after it, never part of it.
Library edits (`editLibrary`) and summary rebuilds are one commit the same
way; removing a strategy is `ClearArea` of its area and a `Delete` of its
summary. Opening and reading never commit: the only calls that write are
`commit`, `editLibrary` and `rebuildSummary`. `editLibrary` copies the list
it is given when it is called, not when its turn comes.

Every save returns a `Saving`, which the caller has to handle:

- `Saved`: the engine applied the commit.
- `NothingToSave`: the op changes nothing.
- `Refused`: `OpRefusal` when `applyOp` refused it, `NoSuchStrategy`,
  `UnreadableRowInTheWay` when the strategy's own row cannot be read,
  `UnplacedRowInTheWay` when the name it would write holds a row with no
  id (or, for an op that places pages, when the strategy holds a page with
  no id), or `CopyLeavesRowsBehind`. For library edits:
  `StrategyAlreadyInStore` (also when any name is already stored for that
  strategy), `RowOutsideStrategy` (a row of an added strategy names another
  strategy or a page it does not have), `NoSuchUnreadableStrategy`,
  `NoSuchFolder`, `FolderNotEmpty`, `FolderInsideItself`, `FolderLoop`.
- `NotSaved`: nothing changed. The engine refused the commit, a row would
  not encode or read back, reading the pages the op needs failed, or the
  store has stopped (`StoreStopped`) or closed (`StoreClosed`).
- `SaveInDoubt(failure)`: the engine could not say whether the commit
  applied. The store is finished, and the result comes back only once its
  lease is released, so the caller can reopen at once. After a save in
  doubt the caller reopens and reads: what is stored is what was saved.
  Whether to issue the edit again is the editor's call, and it is safe only
  for an edit that carries the base or the expected revision it was made
  against, so the op's own conflict rules apply: a field merge without a
  base skips the revision check, and issued again it can overwrite a newer
  edit another tab saved in between; a `RemoveStrategy` issued again can
  clear a strategy another tab has just edited. With no other writer,
  `test/store_outcome_test.dart` shows for every op type and every library
  edit that issuing it again leaves it applied once.

Saves and reads run one at a time, in the order they were called. A store
finishes when it closes, when its lease ends, or after a save in doubt; the
three differ only in the reason they carry (`StoreClosed`, or
`StoreStopped` with the cause). A finished store has released its lease, so
the reopen it requires is never blocked; it has closed `changes`; and every
later save and read returns that reason. `close` waits for operations called
before it, not for `changes` listeners, and returns what the release
returned; a second `close` returns the same.

**Folders.** `PutFolder` writes the folder row whole, replacing what was
stored, so a rename reads the folder first and puts it back with the new
name. Every walk over stored parent folders remembers where it has
been, so it ends on any data. A folder that would be filed, or a strategy
moved, under a stored loop is refused with `FolderLoop` naming the folders
in it; under a missing folder, `NoSuchFolder`; under a folder this build
cannot read, `UnreadableRowInTheWay`. Opening reads a loop as it is and
lists its folders.

### Reading

`readStrategy` and `readPage` return a `Reading`: `Found`, `NotFound`,
`NotRead` when the device failed, or `InUnreadableStrategy(listing)` when
the strategy's area holds rows but its own row is missing or has no id. Such
a strategy is listed in `unreadableStrategies`, refuses every write with
`StrategyNotReadable`, including `RemoveStrategy`, and is removed only by
`RemoveUnreadableStrategy`, which is for strategies with no known id.
`RemoveStrategy` by a known id removes the strategy's whole area, readable
pages included, whether its own row reads or is damaged, because removal is
the user's own action; only a strategy whose own row is missing or holds no
id needs the removal by reference. A strategy whose own row cannot be read but whose
id is known still reads: `StrategyContent.strategy` is its
`UnreadableStrategy`, and its pages read as usual; edits to it are refused.

**Rows whose page has no row.** Settings and content under a page name
whose page row is missing, or has no id, are treated alike: they are kept,
reported in `StrategyContent.unplaced`, counted as damaged (or newer, for a
kind this build does not know), and their names refuse writes. Adding a
page whose names they hold is refused with `UnplacedRowInTheWay`; copying
from that page id is refused with `CopyLeavesRowsBehind`; a copy from an id
with no page row and no content is left to `applyOp`, as on the server.
Unreadable pages, settings, elements and lineup groups whose ids are known
come back in the same lists as readable ones; rows with no id come back in
`unplaced`; a name under `content/<p>/` of a kind this build does not know
comes back as an `UnknownKindRow` with its text as stored. `library` is
`LibraryOpen` with the list (summaries, unreadable strategies, folders,
unplaced library rows), or `LibraryShut` once the store has finished, so a
finished store never hands out data that looks current.

A page copy whose source page cannot be read, or holds a row of a kind this
build does not know, a row with no id, or a foreign name, is refused
(`UnreadableTarget`, `CopyLeavesRowsBehind`) rather than copied without
them.

### Deleting

The store writes no name whose row it cannot read, with one exception:
removing a strategy clears its whole area, these rows included, because
the user asked for the whole strategy to go.

### Summaries

A `StrategySummary` holds the name, map, folder, created and updated times
(from the strategy row), live page count, `Sides` (attack, defend or mixed),
the agents placed on live pages, and how many items they hold. It also keeps
a tally per page, so trashing a page updates the counts without reading that
page. Every commit writes the new summary in the same commit as its rows.
`readability` is `AllReadable` or `SomeUnreadable(damaged, newer)`: `newer`
counts rows of a kind this build does not know and elements from a newer
build (the app says "made with a newer version"), `damaged` counts every
other row it cannot read (the app says "could not be read").
The summary is a cache of the rows. `rebuildSummary` recomputes it from
the rows alone and writes it. When the store opens and cannot read a
summary, it rebuilds it in memory; when the strategy's own row cannot be
read either, the strategy is listed in `unreadableStrategies`. Whenever rows
are loaded, by a read or by an edit, the in-memory summary is brought up to
date with them. A summary changed in memory this way is marked as not yet
in storage: the next save of that strategy writes it, and `rebuildSummary`
writes it even if it compares equal to the one in memory.

A summary that is lost from storage is found again by `findStrategies()`,
which the app runs after open (open itself lists no areas). It lists the
strategy areas with `areas`, rebuilds in memory the summary of each strategy
that has a readable row and no summary, and lists each area that holds rows
with neither as an unreadable strategy. It returns `StrategiesFound(rebuilt,
unreadable)` or `StrategiesNotSearched(failure)`, and commits nothing.

### Telling the editor what changed

`changes` is a stream of `StrategyEdited` (the strategy, the op id, the
`RowWrite`s with their changed fields and data fields, the rows removed, the
new summary) and `LibraryEdited`. It fires after the save, once per `Saved`.
A local commit never removes a row; `removed` is there for cloud strategies,
where the server rejecting a pending op can take a row away.

### Room for cloud strategies

Nothing for them is built here. What a local strategy reads and saves
through does not have to change for them: a cloud strategy's base can live
under the same names in its area and its pending ops under names of their
own, read through a new call; `commit` keeps its signature and saves the op
as a pending op; a change already names its op and can name rows that are
gone; and one engine commit already writes any set of names across areas
at once, so advancing the base and removing the acknowledged ops is one more
commit.

### Measuring it

`dart build cli -t bin/engine_costs.dart -o build/engine_costs` builds the
engine cost tool ahead of time, and `build/engine_costs/bundle/bin/engine_costs
<folder>` times, on the memory engine and on SQLite in `<folder>`: opening the
store and listing a 700-strategy library, opening a 20-page strategy, a cold
read of a 300-item page, saving a moved item and a 1000-point drawing, 200
moves awaited one by one and 200 issued at once, and one engine write of a
single key. `tool/engine_costs_web.sh` does the same
for the memory engine and IndexedDB in headless Chrome, compiled with
`dart compile js -O4`.

`dart run tool/store_benchmark.dart` times opening the store and a
700-strategy library list, opening a 300-item page where half the items are
1000-point drawings (in a strategy not yet read, and in one already read),
and two commits on that page. `test/store_budget_test.dart` counts what each
of those asks the engine to read, list and write, and how many keys each
listing returns, and fails when a count grows; it includes a strategy of 20
pages with 300 items each.
