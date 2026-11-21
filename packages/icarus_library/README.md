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
  hold after accepting it, what an undo puts back, and which rows and fields
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
  A whole number past the exact range is refused unless it is exactly how
  JavaScript writes some double, because the web build writes a whole
  double of 2^53 or more without a fraction (`1152921504606847000` for
  2^60). Such a number is unusual, and on the VM it is turned into that
  double wherever it stands, a bare top-level number included, so both platforms hold the same value. A number with a point
  or an exponent is a double on both platforms, so `9007199254740993e0`
  reads as 9007199254740992, and saving writes that value. The store's
  writer keeps a whole double of 2^53 or more as a double, and writes an
  int past 2^53 as the double that holds it exactly, as JavaScript would,
  so what the VM writes reads back as the same double. An int no double
  holds keeps its digits, and the read-back before a commit refuses it.
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
- **Ids come from the op.** The ids of rows a page copy creates are derived
  from the op's id and the source row's id, so recomputing the base with its
  pending ops never renames anything. A derived copy id never takes the id
  of a row the strategy already has.
- **An undo is a value, built into an op when it is used.** `applyOp`
  returns an `Undo` saying what to put back for the row it changed: the
  fields with their values before and after the edit
  (`RestoreStrategyFields`, `RestorePageFields`, `RestorePagePlace`,
  `RestoreSettings`, `RestoreElementFields`, `RestoreGroupFields`), that the
  row did not exist (`RemoveAddedPage`, `RemoveAddedElement`,
  `RemoveAddedGroup`), or the whole row before a delete
  (`RestoreTrashedPage`, `RestoreDeletedElement`, `RestoreDeletedGroup`).
  `buildUndo(rows, undo, opId:, defaultSettings:)` is a pure function that
  turns it into an op against the rows as they are when the user presses
  undo, with their current revisions, so a run of undos works for every
  row kind. It answers `UndoReady(op)`; `RestoreFromTrash(page)` for a
  deleted page, since restoring from the trash is a call of its own and
  not an op; `NothingToUndo` when every field is already back; or
  `UndoBlocked` with `TargetGone`, `TargetUnreadable`, `ChangedSince` (a
  field the edit wrote now holds something else, so the undo would
  overwrite a change not in the history being undone) or `CannotClear`.
  An undo puts back the fields its edit wrote and nothing else, and only
  into the row lifetime its edit was made in:
  - Fields the edit did not write are left alone: undoing an edit to an
    agent's position writes the position back and keeps a teammate's later
    change to its side.
  - Fields are compared with the field rules' defaults filled in on both
    sides, so a default made explicit is not a change, and a built op that
    would change nothing answers `NothingToUndo`.
  - For an element, every field of a field group the edit wrote counts as
    written, as it does for the server's merge: once a teammate moves an
    image, undoing its scale is `ChangedSince`.
  - Lineup items are compared by id and content, never by position, since
    the server's merge cannot keep positions; an item an undo put back last
    never reads as someone else's change. Undoing an edit that reordered a
    group's items writes the payload as it is now with only that order put
    back, so a teammate's later landing move stays.
  - A delete's undo records the revision its tombstone was left at and
    restores only over that tombstone: if the row was brought back and
    deleted again since, it is `ChangedSince`. The editor's own undo and
    redo never trip this, because applying a built undo returns a fresh
    value that replaces the old one on the other stack.
  - An undo that only puts back a place is the reorder op
    (`element.reorder`, `lineup.reorder`, `page.reorder`). Element and
    lineup group undos that write fields are merges whose base is what the
    edit left, so the server refuses one that races a newer change
    (`field_conflict`); the others carry the current revision.
  - An undo that deletes a page (the undo of a page add) is a page delete
    like any other: the page goes to the trash with whatever is on it, and
    the cloud queue's check before sending a page delete applies to it.
  - Undoing a link add after a teammate removed the other link that used a
    landing removes that landing too, because the server keeps a landing
    only while a link uses it.

  Redo is the same mechanism: applying a built undo returns the value that
  undoes it. A new edit to a field blocks redo of an older edit to that
  field and leaves other redos alone; the editor clears its redo stack on
  any new edit. Each new undo or redo needs a fresh op id; retrying the same
  built op after an unknown outcome uses the same id. Reusing the original
  edit's id makes the server treat the undo as that edit again, a no-op.
  `test/undo_sequence_test.dart` runs 3,000 random runs of one to four
  edits on one page, over every row kind, and checks that undoing them in
  reverse, each undo built when it is used, puts every stored row back,
  tombstones included, and that redoing them returns to the end; the few
  differences the protocol forces are listed in the test as a table.

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
- Undoing the first settings edit on a page whose settings were never set
  writes the defaults the app passes to `buildUndo`: the page showed them,
  and the server's `pageContent.patch` requires settings, so the undo
  cannot store them as absent again. Afterwards the row holds explicit
  defaults where it held none, and the page looks as it did.
- Undoing an edit that set `isAutoNamed` on a page saved before that field
  existed writes `isAutoNamed: false` where the field was absent. A page op
  cannot clear the field, and the server reads absent as `false`.
- Undoing a lineup merge that removed a link or another item puts it back
  last, because the server's merge appends the items it adds. The order is
  visible: the lineup panel opened from an origin lists its lineups in
  stored order and opens on the first, and connector lines are drawn in
  the order their links are stored. The undo value keeps each item's
  place (`RestoreGroupFields.indexBefore`) and the built op carries the item
  there, so if the panel sorts by something stable, or the merge ever keeps
  places, nothing here has to change.
- An undo value is good only for the life of the strategy it was made in.
  The editor drops its undo history when a strategy is removed or replaced,
  for example by an import under the same ids.
- An element op whose payload version is newer than this build reads is
  applied, as the server applies it, and the element becomes an
  `UnreadableElement` from a newer build holding that payload whole.
- Undoing an edit that first set `mapDoor`, `isZone` or a picture id
  (`assetId`) is `UndoBlocked(CannotClear)`. Those fields are never cleared (a door goes back to
  rest by deleting its row, a zone stays a zone, and the server keeps a
  picture id that a write leaves out), so there is no value an undo could
  write.
- A whole double of 2^53 or more compares and measures as Dart writes it
  (`1152921504606846976.0`), not as JavaScript does
  (`1152921504606847000`). Both read back as the same double.
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

Then come eight undo seeds: sequences from the same generator as the seeds,
where three steps in ten take an earlier step's undo value, usually the
latest, and send the op `buildUndo` makes from it at that moment, so undos,
redos and undos of older edits all reach the server. They run with the
stories so the seeded corpus and its coverage floors stay as they are.

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
and `CommitUnknown` all or none, never part. The IndexedDB engine can break
that last promise in two cases the browser causes, described under
IndexedDB below: there `CommitUnknown` can mean partly applied.

A read sees every commit that has answered. A read issued while a commit is
still in flight may see the rows from before it; nothing promises more, and
the store awaits each commit before it reads.

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
  modelled power cut, and in `NORMAL` 48 did not. That is a model: whether a
  real drive keeps a synced write through a power cut depends on the drive
  and file system honouring the sync, and no real power was cut. On macOS `fullfsync` is on, because a plain sync
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
- **Creating a library** happens in the library file itself, and only in a
  file that is provably not created yet: zero bytes, or exactly one page with
  no schema entries, application id 0 and user version 0. The open creates it
  in rollback-journal mode with `synchronous = FULL`: one `BEGIN EXCLUSIVE`
  transaction makes both tables and sets the identity, then the open checks
  the file and switches it to write-ahead logging. SQLite applies that
  transaction whole or not at all, so a creation cut short leaves an empty
  file (or a hot journal that rolls back to one), and the next open creates it
  again. Two creators are kept apart by SQLite's own lock on the file: the
  second is refused and retries, then finds the library held. A larger file
  with no tables is a damaged library and is refused, and so is a file that
  is not SQLite, another program's database or from a newer build. Nothing is
  written to any of them. A file emptied to nothing, with no log or journal
  beside it, is taken for a creation cut short and created again, because the
  two cannot be told apart.
- **After an unknown commit** the log can still hold that transaction's
  frames, and they would come back on the next open. So the next transaction
  that succeeds also bumps `generation`; it writes over those frames, and from
  then on the unknown commit can never return.
- **Failures.** A full disk is `OutOfRoom`; a damaged file
  (`SQLITE_CORRUPT`, `SQLITE_NOTADB`, a failed integrity check) is
  `DamagedLibrary`; any other error SQLite reports is a `DeviceFailure`
  naming its code. SQLite can describe damage with bytes that are not UTF-8;
  `package:sqlite3` throws a `FormatException` for that, and the engine
  returns it as `DamagedLibrary` too.
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
- **When storage is gone.** Before SQLite touches anything, the engine looks
  at the files: a library file that is missing or empty while a `-wal` with
  content, or a `-journal` that holds pages, sits beside it is refused as
  `LibraryFileGone`, and every byte is left as it was. SQLite would otherwise
  delete that log, and the saved edits in it with it. A journal holds pages
  when its header is valid and records a size above zero; the journal left by
  a creation cut short records zero and holds nothing. The engine looks at the
  companions first and the library file second, and tries again for up to
  250 ms before refusing, so a process that looks while another creates the
  library is not refused by mistake. A missing library file with nothing
  beside it is created as a new, empty library and the lease is granted; the
  engine cannot tell a first start from a file deleted by the user or a
  cleaning tool.
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
  an abort for `QuotaExceededError` is `CommitUnknown(AbortedForQuota)`. The
  engine tells a quota abort from other aborts by `transaction.error.name`
  alone.
- **On this engine, `CommitUnknown` can mean partly applied.** In two cases:
  - Firefox can keep part of a transaction that aborted on quota: requests
    queued after the failing put still take effect
    ([bug 2080749](https://bugzilla.mozilla.org/show_bug.cgi?id=2080749)).
    Through this engine in Firefox 160, before the room check below existed,
    it happened in 5 runs out of 5: the aborted commit's delete and its last
    put were in the database afterwards.
  - A put that throws while the commit is queued makes the engine abort the
    transaction. If that abort throws too and the browser completes the
    transaction anyway, the puts queued before the throw have landed.
- **Room is checked before a commit.** The engine asks the browser for
  `navigator.storage.estimate()` when it leases. A commit with puts is
  charged two bytes per character of area, key and value plus 1 KiB per put;
  its charge is reserved when the commit is admitted and given back if the
  commit is refused, so commits issued together are admitted one after
  another against the room left by those before them. A commit that would
  leave less than 1 MiB is refused as `CommitRefused(NoRoomForCommit)`, with
  nothing written. A commit with no puts (empty, deletes, area clears) is
  never refused for room, since it frees space or uses none. The engine asks
  again in the background when the last answer is over 10 s old, so in
  normal use a save does not wait on the browser; it waits for a fresh answer
  only when the cached figure says a commit will not fit. Measured in Chrome
  157 and Firefox 160 (`tool/estimate_web.dart`): `estimate()` answers in
  about 1 ms, and it already counts a write that completed just before, at 1.0
  to 1.2 bytes per character, so a fresh figure replaces the old one and each
  put is charged once. A put that completes while an estimate is on its way
  can be missed by that estimate; the 1 MiB margin covers it. In Firefox with
  its quota capped (`tool/firefox_page.sh tool/quota_abort_web.dart 4096`),
  the commit that used to be partly kept is refused with nothing written, and
  filling the database ends in a refusal, never an abort.
- **When the browser cannot say how much room there is**, because it has no
  `navigator.storage`, or `estimate()` fails or gives no answer within 10 s,
  the engine commits without the check, and `IndexedDbLease.roomCheck` is
  `RoomNotChecked` with the reason; with a figure it is `RoomChecked`. An
  estimate that fails after the engine had a figure keeps that figure.
- **A full disk is a quota abort in Firefox.** Firefox does not lower its
  reported quota as the disk fills, so the room check cannot see a full disk
  coming. Staged on a nearly full tmpfs (`tool/disk_full_web.sh`), Firefox
  aborted with `QuotaExceededError` in 4 runs out of 4, and every time it
  rolled the whole commit back. The engine answers it
  `CommitUnknown(AbortedForQuota)` all the same. No other kind of abort was
  staged in Firefox for real; that other aborts roll back whole is the spec's
  promise, checked here only with aborts the test itself starts.
- **Why partly applied is tolerable today.** The web build is cloud only
  (`lib/config/platform_policy.dart`: `webBeta` has
  `allowsLocalLibrary: false`), so the web store holds a copy of server rows
  plus edits waiting to be sent. That alone does not make it safe: a partly
  applied commit can remove or replace an unsent edit, which the server has
  never seen. So the cloud store's commits are required to be safe when any
  subset of their row changes is applied, and its tests inject exactly that
  ([#667](https://github.com/SunkenInTime/icarus/pull/667)). The store
  reports the commit as `SaveInDoubt` carrying `AbortedForQuota` and shuts.
  The day the web build allows a local library, this engine needs
  before-images to undo a partly kept commit, or it must not be used on the
  Firefox versions with this bug.
- **Whatever is thrown is answered, and the lock always comes back.** A
  lease that throws anything while it asks for the lock, opens the database
  or checks it is `LeaseFailed`; the database is then closed, a database the
  lease created is deleted, and the lock is let go, each step whatever the
  one before it did. Every browser call made while acquiring or releasing a
  lease has a time limit (10 s by default, `IndexedDbEngine.patience`), after
  which the caller gets `NoAnswer`. Release always closes the database and
  lets go of the lock, and says `ReleaseFailed` if either step failed. A put
  that throws while the commit is queued aborts it and answers
  `CommitRefused`; if the abort throws too, the answer is `CommitUnknown`. A
  throw anywhere else in a commit, including while reading
  `transaction.error`, is `CommitUnknown`. A read whose callback throws is a
  failure, never a caller left waiting.
- **Errors in browser callbacks are completed, not chained.** A callback
  runs in the root zone, and Dart does not carry an error from a future made
  there to a caller in another error zone (a test, or an app that wraps
  `main` in `runZonedGuarded`): the caller waits forever. So each callback
  catches what it throws and completes the caller's completer with the error.
- **Values must be text.** A read fetches `getAll` over the one key, so a
  missing key is an empty list and a stored value is always distinguishable
  from no value. A stored value that is not a string, `null` and `undefined`
  included, is a failure to `read` and to `entries` alike. This needs no
  `undefined` check, which behaves differently once Dart is compiled to
  WebAssembly. The suite passes compiled to JavaScript and to WebAssembly, in
  Chrome and in Firefox.
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
  `LeaseFailed(BrowserLacks(webLocks))`.
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

#### What a library can be in, and what the app can say

This section is the specification the app's wording is written from. Every
state below has a type the app can switch over; none of them needs a message
parsed. Each sentence claims only what is certain in every way the state can
arise, so the app never says more than it knows.

The app always knows which step a failure came from, because the store
answers each step with its own result:

- **opening:** `StoreNotOpened(OpenStorageFailed(failure))`: the store did
  not open, and opening makes no commit, so it wrote no row;
- **a refused save:** `NotSaved(failure)`: the edit is not stored. The store
  stays open unless the failure ended its lease; then every later step
  answers `StoreStopped`;
- **a save in doubt:** `SaveInDoubt(failure)`: the edit may or may not be
  stored (on IndexedDB, possibly in part), and the store stops;
- **a read:** `NotRead(failure)`: that read failed. As with a refused save,
  the store stays open unless the lease ended.

**Was the library just created?** `StoreOpened.origin` is `StorageCreated`
when the library held no `format` row and no row in any area when it was
opened, and `StorageExisted` when it held a `format` row or any row. Opening
decides and reports; it writes nothing. The `format` row, the store's
marker, goes into the first commit the store makes for any reason, in the
same engine commit as that save. A library that lost its marker is existing,
is never refused for it, and gets it back the same way. A new library that
is opened and closed with nothing saved is still empty, so it is created
again the next time.

- Certain: there were no rows here when Icarus opened it.
- Only possible: that a library existed before and was deleted, evicted by
  the browser, or cleared with the site's data, or that it was opened before
  with nothing saved. A zero-byte file and a first start look the same.
- The app knows whether it expected a library; the engine does not.

| When | What the app can say |
| --- | --- |
| `StorageCreated` where a library was expected, web | "This browser has no copy of your library, so Icarus is loading it from the server. Changes that had not reached the server are not in it." |
| `StorageCreated` where a library was expected, desktop | "Icarus found no library where it expected one, so it started a new, empty library." |

**Format numbers.** A library carries two, both checked every time it is
opened:

- The **engine format** is the engine's own layout: on SQLite the tables,
  their columns and keys, and the generation row, kept in `user_version`
  (`sqliteFormat`); on IndexedDB the object store and its keys, kept in the
  database version (`indexedDbFormat`, which is also the version the engine
  opens with). Written when the engine creates the storage. It changes when
  an older engine would misread the layout or write into it wrongly. It does
  not change for what rows hold.
- The **store format** is the store's row layout: the area and key names, and
  the shape of a summary and of every row the store reads back. It is the
  `format` row in the `library` area (`storeFormat`), written with the first
  save into a library that lacks it. It changes when
  an older store would misread the rows or write into them wrongly; a change
  that older stores read and keep correctly does not change it.

Both are 1, the first format, and nothing earlier shipped. A build that
raises a number must also say how it moves a library from the lower one. A
`format` row is read only when it is a plain decimal of one to nine digits
with no sign, no leading zero and no spaces (`1`, `2`, `17`); anything else,
including a longer number, is `DamagedLibrary`, never a newer format.

A build that meets a number higher than it knows refuses to open with
`NewerFormat`, naming the layer, the number found and the number it knows.
No row is written or changed and no commit is made: the engine checks its
number before it switches SQLite to its log, and opening never commits.
SQLite has opened the file read-write by then,
so it may still roll back an interrupted transaction from a journal, switch
a file to its log, or fold the log into the file when the connection
closes; none of that changes what any row holds. On IndexedDB a newer
database is refused by the browser before it opens. The engine then reads
the version the browser lists for it in `indexedDB.databases()`, which opens
nothing; if the database is no longer listed (it was cleared in between),
the answer is `DeviceFailure`, not a version.

**What can go wrong.** `StorageFailure` is a sealed set; a caller switches
over it exhaustively.

**`StorageFull`** has three cases.

- `NoRoomForCommit`: Icarus's own room check on IndexedDB refused a save
  before anything was written: the browser's estimate, less what pending
  saves have reserved and a 1 MiB margin, was smaller than the save's
  estimated size. Certain: the save was not stored. Only possible: that the
  browser would have had room for it. Comes only as a refused save. "Icarus
  held this change back because storage looked too full to save it
  safely."
- `OutOfRoom`: the disk (SQLite) or the browser (`QuotaExceededError`
  outside a commit's abort) ran out of room. Certain: the device or browser
  said it had no room. Only possible: whether the step completed, which the
  step's result says.
  - opening: "There isn't enough storage space to open your library."
  - refused save: "There isn't enough storage space, so this change wasn't
    saved."
  - save in doubt: "Storage ran out while saving, so this change may not
    have been saved."
  - read: "There isn't enough storage space to read part of your library."
- `AbortedForQuota`: the browser aborted an IndexedDB commit for lack of
  room (in Firefox, a full disk too). Certain: the browser aborted the save.
  Only possible: that part of it was kept (Firefox, bug 2080749). Comes only
  as a save in doubt. "The browser ran out of storage while saving, so this
  change may be only partly saved."

**`NewerFormat`**: a number above what this build knows. Certain: the
library holds a format number higher than this build knows, which is the
number a newer build would write. Comes only while opening. "This library
uses a newer format than this version of Icarus understands. Update Icarus
to open it."

**`DamagedLibrary`**: a failed integrity check, a file SQLite cannot read
(`SQLITE_CORRUPT`, `SQLITE_NOTADB`), a file that is not an Icarus library, a
value that is not text, a key that is not a name, a `format` row that is not
a plain decimal, an IndexedDB database without its rows store. Certain at
opening: the file or database is not one Icarus can read as its library.
Certain at a read or a save: the engine met something it could not read
(SQLite said the file is corrupt or not a database, or reported text it
could not decode, or a stored value or key was not what Icarus writes). Only
possible: how much is affected; a failure found in one read or save need not
mean the rest is unreadable.

- opening: "Icarus can't read this library file, so it can't open it."
- read: "Icarus couldn't read part of your library."
- refused save: "Icarus met something in your library it couldn't read, so
  this change wasn't saved."
- save in doubt: "Icarus met something in your library it couldn't read
  while saving, so this change may not have been saved."

**`LibraryFileGone`**: the SQLite engine found the library file missing or
empty while a file with the log's name (`-wal`) and some content, or a file
with the journal's name (`-journal`) whose header says it holds pages, sits
beside it. Certain: those files are there by name and size (and, for a
journal, header). Only possible: that they are SQLite's and hold changes; a
log can hold only its header. Comes only while opening, and nothing is
touched. "Your library file is missing or empty, and a file named like
SQLite's log or journal is beside it, so Icarus won't start a new library in
its place."

**`BrowserLacks`**: the browser does not report strict durability
(`strictDurability`), or the page has no Web Locks (`webLocks`). Certain:
this browser or page lacks something Icarus needs to keep a library. Comes
only while opening. "This browser can't keep your library safely, so Icarus
won't store it here."

**`NoAnswer`**: one IndexedDB browser call gave no answer within the
engine's time limit (`IndexedDbEngine.patience`, 10 s by default). Certain:
that one call missed its limit. Only possible: that it still completed
later, and that the browser is otherwise responsive.

- opening: "Opening your library took too long, so Icarus stopped. Reload
  the page to try again."
- read: "Reading part of your library took too long."
- save in doubt: "Saving took too long, so this change may not have been
  saved."
- release: a `ReleaseFailed`. Certain: Icarus could not confirm it let go of
  the library, so it is not known whether another tab can open it now.
  "Icarus couldn't confirm it closed your library. If another tab can't open
  it, close this one."

**`HeldByAnotherWriter`** (a `Leasing`, not a failure, answered as
`StoreAlreadyOpen`): when Icarus tried, another tab, window or process held
the library (on SQLite, at least one attempt within 250 ms found it locked).
Certain: it was held during the attempt. Only possible: that it is still
held now. "Your library is open in another Icarus window or tab."

**`LeaseEnded`, `StoreClosed`**: the lease ended (another tab upgraded or
deleted the database, the browser closed it, or the app closed the store).
Certain: this library is no longer open here. "Your library was closed.
Reopen it to keep working."

**`EngineClosed`**: the engine was closed, possibly before any library was
opened through it. Certain: this engine will not open or use a library any
more. "Icarus stopped using this storage. Reopen your library to keep
working."

**`StoreStopped(cause)`**: every step after the store stopped, carrying what
stopped it. The sentence is the one for its `cause`.

**`KeyTooLong`, `NameNotAllowed`, `WouldNotReadBack`**: a row the store built
that the engine, or the store itself, would not keep. Certain: this is a bug
in Icarus, not a state of the library. Comes as a refused save. "Icarus
couldn't save this change."

**`DeviceFailure`**: anything not classified above: another I/O error, a
worker that died, a rollback or abort that failed, a file Icarus could not
read. Certain: something went wrong in the step. "Something went wrong
reading or writing your library."

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
  survives another power cut. A library file that is empty or missing beside
  a log with content or a journal that holds pages, and a library whose
  first page is a blank database over more pages, are refused with every
  byte left as it was, on this model and on real files.
- `test/sqlite/sqlite_engine_test.dart` uses real files and real processes:
  a second isolate and a second process are refused the lease, commits in
  flight when one process releases land before another process gets the
  lease, and a writer process is killed at 24 random points and the library
  reopened in this one. Each kill checks that a commit across three areas,
  including an area clear, is wholly there or wholly absent. A killed process
  is not a power cut: the operating system still writes what the process had
  written.
- `test/indexed_db/indexed_db_engine_test.dart` runs in Chrome and Firefox,
  compiled to JavaScript and to WebAssembly (`--compiler dart2wasm`); CI runs
  Chrome compiled to JavaScript. It aborts a transaction after its first request
  succeeded, including a commit across three areas with an area clear,
  reports a quota error (by patching `IDBObjectStore`), makes a put throw
  while it is queued (a `DOMException` and a plain error), makes the abort
  after it throw, rejects a lock request, makes opening throw before and
  after the database opens, keeps an open waiting behind a blocked delete,
  drops the durability option and hides the property, makes a cursor key
  throw, stores values that are not text (`null` and `undefined`), reports a
  small room left, or an estimate that fails, throws or never answers (by
  patching `StorageManager.estimate`), issues commits together against a
  small room, makes `close`, `deleteDatabase` and `transaction.error` throw,
  upgrades, deletes and
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
token outside the range JavaScript holds exactly and not written as
JavaScript writes a double (anywhere in the text, fields this build does
not know included), makes the row unreadable with its text kept. So the VM
and the web hold the same value for every number they admit. A number
neither can hold, such as `9007199254740991.1`, is held by both as the
nearest double, and a rewrite saves that double.

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
it is given when it is called, not when its turn comes. A library edit
stages what it changes over the store's folders, summaries and unreadable
strategies without copying them, and applies the staged changes only once
the engine applies the commit, so adding, moving or removing a strategy
costs the same in a library of any size.
`test/library_edit_cost_test.dart` requires the same engine work for each
at 100 and 2,800 strategies, and `test/library_edit_time_test.dart`
(tagged `timing`) requires the fastest of each to stay within 1.5 times. A library edit
saves what differs from the stored rows when it ends: moving a strategy
into a folder and back in one edit is `NothingToSave`, several moves of
one strategy raise its revision once, and a strategy added in the same
edit keeps its own revision. Each step sees what earlier steps staged: a
move of a strategy the same edit removes is refused with `NoSuchStrategy`,
and adding it back in the same edit with `StrategyAlreadyInStore`. `test/store_library_batch_test.dart` runs short
random edits and checks that each saves what the same steps save one edit
at a time, or refuses and saves nothing.

**Several ops in one commit.** `commitAll(strategyPublicId, ops)` applies
the ops in order, each to the rows the ones before it left, and sends one
engine commit holding every row they changed and the summary after the
last. It saves what committing the ops one by one at the same instant
would save, with the same `StrategyEdited` for each op, but all of them or
none: when any op is refused, or the engine refuses the commit, nothing is
stored and nothing changes in memory. An op that changes nothing is
skipped, and a batch where every op changes nothing is `NothingToSave`.
`commit(strategyPublicId, op)` is `commitAll` with one op. The pages every
op needs are loaded before the summary is read, so the summary a batch saves
is the one a rebuild from the same rows gives. A summary keeps no tally for a
page whose tally is empty.
`test/store_batch_test.dart` replays the op sequences the parity run's own
generator makes (`tool/parity_scenarios.dart`), in batches of random size,
and checks each batch against the same ops committed one at a time and
against a rebuild of the summary; it also checks the all or none, and that a
batch of 300 ops is one engine commit that reads nothing it had not
loaded. A batch costs about 110 µs an op on the memory engine, linearly
(150, 300 and 600 ops), a third of it in `applyOp`.

Every save returns a `Saving`, which the caller has to handle:

- `Saved`: the engine applied the commit.
- `NothingToSave`: the op changes nothing.

An edit to a strategy that has rows but no summary, before `findStrategies`
has run, is saved like any other: the store rebuilds the summary from the
rows it loads and writes it in the same commit, and the strategy appears in
the library list.
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

### Saving a local strategy whole

`putStrategy(rows)` saves a strategy kept only on this device as the
complete set of rows it should hold, in one engine commit. It is how the
store keeps an exact image of a local strategy while the Hive library
stays the one the app reads, so that reading from the store can be proven
equal to reading from Hive. It stores the rows exactly as given, the
strategy row's `updatedAt` included, never a time of its own, so the
stored rows equal what `AddStrategy` writes for the same rows. A stored row
that parses equal to the given one is left as it is, even if it was written
with different spacing.

- **Only what changed is written.** Each given row is matched to the
  stored row with the same key and compared with it as JSON, by walking
  both (`sameJsonTree`); only rows that differ are encoded and parsed back
  before the commit, as every write is. A stored row the set no longer
  holds is deleted in the same commit, and so is the old name of an
  element or lineup group that moved page. The summary is computed from
  the whole set and saved in the commit too. Putting the same rows again
  writes nothing and answers `NothingToSave`. Over an empty store it adds
  the strategy.
- **What an image cannot carry is refused, changing nothing.** If the
  stored strategy holds a row this build cannot read
  (`UnreadableRowInTheWay`), a row with no id (`UnplacedRowInTheWay`), or
  something a complete set of readable live rows cannot express, it answers
  `PutWouldDrop` with the stored name and what it is: a page in the trash
  (`Dropped.trashedPage`), a tombstone (`tombstone`), a row of a kind or a
  name this build does not know (`unknownKind`, `foreignName`), two rows
  with one id (`duplicateRow`, which no editor action makes), or a changed
  row whose stored version holds a field this build does not know that the
  given row would drop (`unknownField`: unknown fields on the row, its
  payload envelope, its page settings or its theme palette). Nothing writes
  those for a local strategy today; the per-edit step and newer builds
  will, and this call must not flatten them then. The fields inside an
  element's or lineup group's `data` are the app's to know, so the store
  cannot tell an unknown one from one the editor removed; those are not
  checked here. The store has no word yet for a strategy kept in the
  cloud; one written by a build that keeps cloud strategies in the store
  holds names this build does not know, so it is refused as
  `Dropped.foreignName`.
- **It loads before it compares.** Every page's content is read before the
  comparison, the way `commitAll` reads each op's pages. Knowing a page's
  row is not knowing its content: renaming a page whose content has not
  been read leaves the content to be read later.
- **It costs** a structural comparison of every row and a commit of the
  ones that changed. On SQLite, saving one moved agent in a strategy of 40
  pages and 1,000 items takes about 20 ms in all, half of it the app's
  conversion of the strategy to rows; the comparison grows with the number
  of rows and the commit with the rows that changed.
- **What it is not.** An earlier attempt turned two snapshots of the
  editor's strategy into the store's ops (#680). Three rounds of review
  found failures with one cause: a snapshot does not say what the user
  did. The editor's model and the rows disagree on identity (ids per page
  against ids per strategy), on order (one list of lineups against lineup
  groups) and on what exists (the editor has no trash, no tombstones and no
  fields a newer build wrote), so every round recovered a little more
  intent and the next found what could not be recovered. Ops will come from
  the edit itself, in the step that saves edits as they are made, where the
  intent is known. Do not rebuild the snapshot diff.
- **When it stops being the save.** An image holds what this build's editor
  holds and nothing else. That is right while Hive is what the app reads,
  because Hive loses the same things: a field a newer build wrote inside an
  element's `data` is dropped by an older build's save in both. It is wrong
  once the store is what the app reads, since rows then carry what only
  another build or another device knows. From that step on a strategy is
  saved by ops and `putStrategy` is no longer called for it. The app's
  converter also derives a row's id from where its page sits among pages
  that share an item id, so reordering such pages rewrites those rows under
  new ids; the image stays exact, and it is one more reason an image is not
  the save for a store other builds write.

`test/store_put_strategy_test.dart` checks the stored rows against
`AddStrategy`, what is written and deleted, the second put, each refusal on
its own with no commit, and, on the memory engine and on SQLite, a page
renamed before its content is read, read and then saved whole. The app's
`test/library_rows/strategy_image_test.dart` saves every step of a scripted
editing session and of 30 generated ones and checks that the stored rows
equal the image of the editor's strategy and that what is read back is that
strategy again, and the corpus check saves every corpus strategy whole.

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
page whose names they hold, including a row of a kind this build does not
know, is refused with `UnplacedRowInTheWay`; copying
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
build does not know, a row with no id, a foreign name, or an element whose
`deleted` flag cannot be read, is refused (`UnreadableTarget`,
`CopyLeavesRowsBehind`) rather than copied without them.

`PageContent.settings` is `SettingsStored(row)` or `NoSettingsStored`, for a
page saved before settings rows existed.

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
A page whose tally is empty has no entry, so a summary written after edits
equals the one a rebuild gives.
`readability` is `AllReadable` or `SomeUnreadable(damaged, newer)`: `newer`
counts rows of a kind this build does not know and elements from a newer
build (the app says "made with a newer version"), `damaged` counts every
other row it cannot read (the app says "could not be read").
The summary is a cache of the rows. `rebuildSummary` recomputes it from
the rows alone and writes it. When the store opens and cannot read a
summary, it rebuilds it in memory; when the strategy's own row cannot be
read either, the strategy is listed in `unreadableStrategies`. Whenever rows
are loaded, by a read or by an edit, the in-memory summary is brought up to
date with them, and so is the summary a library edit writes: moving a
strategy into a folder before its pages were read saves the summary its
rows give, not the stored one. That summary is only as current as the
rows the store has seen: if an item row went missing on a page no one has
opened, a folder move carries the stale count forward, and it is corrected
when that page is read or the summary rebuilt. Reading every page to move
a strategy would make every move slow to find damage a moment sooner. A
page tally counts only pages the strategy has, so a lost page row is counted once, as orphaned rows, and a page added
under the id of a page that is wholly gone starts empty. A summary changed
in memory this way is marked as not yet in storage: the next save of that strategy writes it, and `rebuildSummary`
writes it even if it compares equal to the one in memory.

A summary that is lost from storage is found again by `findStrategies()`,
which the app runs after open (open itself lists no areas). It lists the
strategy areas with `areas`, rebuilds in memory the summary of each strategy
that has a readable row and no summary, and lists each area that holds rows
with neither as an unreadable strategy. A listed strategy whose area holds
no rows at all becomes an unreadable strategy too ("none of its rows are
stored"), so the user sees it is gone, and `RemoveUnreadableStrategy`
removes its summary. A summary that cannot be read, for a strategy with no
rows, is listed the same way when the store opens. It works out every answer before it changes the list,
so a read that fails partway leaves the list as it was. It returns
`StrategiesFound(rebuilt, unreadable)` or `StrategiesNotSearched(failure)`,
and commits nothing.

### Telling the editor what changed

`changes` is a stream of `StrategyEdited` (the strategy, the op id, the
`RowWrite`s with their changed fields and data fields, the rows removed, the
new summary) and `LibraryEdited`. It fires after the save, once per `Saved`,
and once per applied op, in order, after a `commitAll`.
A local commit never removes a row; `removed` is there for cloud strategies,
where the server rejecting a pending op can take a row away.

### Cloud strategies: storage

A cloud strategy lives in the same area as a local one. Its base (the rows
the server last showed) sits under the usual names, and these rows sit
beside it, each versioned and each read back before it is written:

- `cloud`: the strategy's facts (deleted on the server, edit access lost or
  confirmed after attempt N, upgrade asked of build X by attempt N). Its
  presence is what marks the strategy as kept in the cloud.
- `counters`: the next attempt and read numbers.
- `pending/<place>`: one row per entry.
- `attempt/<number>`: one row per attempt.
- `read/header` and `read/page/<page digest>`: base evidence. The header
  row holds the latest page list and the sightings of the strategy, its pages
  and their settings; each page row holds that page's latest complete read,
  whether it was found missing, and the sightings of items last seen on it.
  On load every sighting is taken from the row with the latest read, so the
  evidence is exactly what the core held.

`readStrategy` and `readPage` return the visible rows (the base with the
queue applied) and the queue's views and tally; `commit` adds an edit to the
queue; `record` takes every other event (claims, answers, reads, restarts are
applied on load); `addCloudStrategy` stores a strategy as the server sent it.
The library summary carries the sync tally.

Loading a strategy's queue is three listings (`pending/`, `attempt/`,
`read/`) and two reads (`cloud`, `counters`), pinned in
`test/cloud_store_test.dart`. The next attempt and read numbers are the
largest of the counters row and every number any stored row mentions, so a
restart never issues a number twice. The highest attempt row is never
deleted, and an attempt row is deleted only once every op it sent is answered
or gone on disk, so an op whose answer is unknown is always resent byte for
byte under its client id. Loading applies a restart for the store's build.

**What the decoder refuses.** An entry row that does not decode, comes from
a newer version, holds work or a scope that does not fit its op, a merge
without its field base, a negative attempt or read number, or an op id
another entry holds, is kept as an unreadable entry: it is shown, counted in
the tally, and only the user can discard it. An unreadable `cloud`,
`counters`, attempt or evidence row stops the strategy (`CloudStateNotReadable`)
instead of guessing, because guessing could resend an op under a new id.

**What each event writes.** Only the rows that changed: an edit writes its
entry row and the summary; a claim writes its attempt, the counters and the
summary; an answer writes the answered entry (and the summary when the sync
state moved); an unchanged page read writes one evidence row. Nothing
rewrites the queue. `test/cloud_store_test.dart` pins each of these with a
counting engine on a 200-entry queue.

**Every commit under any subset of its rows landing.** An engine may answer
a commit "unknown" after applying any part of it; the store then stops and
the app reopens it. Each commit is chosen so any part is a state the queue
can come back from:

- Edits, claims, answers, transport failures, refusals, user actions and
  read numbers are one commit each. Every row in it is a fact that stands
  alone: an entry row is old or new, an attempt row is there or not, the
  counters are taken as a maximum, the facts row is old or new. An attempt
  row that landed without its claim being acted on is resent byte for byte;
  one that did not land means nothing was sent, since the app sends only after
  the claim is saved. These are whole under any subset, with no server read
  needed.
- A base arriving is three commits, in order: the base rows, then the
  evidence, then the queue changes it allows (settled entries leave) with
  the summary. Evidence is never ahead of the rows the user sees, and an
  entry never leaves before the evidence that it landed. If the base rows
  land in part, the visible rows may mix two server states until the next
  read of that page rewrites them; that commit relies on the next server
  read. Between the base rows and the queue changes a reader sees the new
  base with every entry still applied on top; an entry the base already
  shows applies as unchanged or is skipped, so nothing is drawn twice.
- Adding a cloud strategy writes the `cloud` row alone first, then the base,
  evidence, counters and summary. Base rows never exist without the marker,
  so a strategy can never look local. A second commit that lands in part is
  finished by adding the strategy again: the area holds the marker and no
  queue, so the add rewrites the rows and deletes leftovers one by one.
- The summary may be left behind by a commit that lands in part. It records
  how many entry rows exist and the sum of their places; when the store opens
  it lists each cloud strategy's `pending/` names and rebuilds any summary that
  disagrees. A missing or extra entry row always changes that pair, since a
  new entry's place is above every old one. A summary of an answer-unknown
  claim says "sending" until the queue loads; loading refreshes it.

`test/cloud_store_model_test.dart` runs the model through the store on the
memory engine. About one commit in fourteen is answered unknown after a random
subset of its rows lands, the store is reopened between any two commits now
and then, and restarts change the client id and sometimes the build. After an
edit in doubt the model reads the queue to learn whether it landed. At the end
it drains without faults and requires the server to hold exactly the edits
that landed. With no teammate the user is never asked anything but to retry
exhausted retries. Taking out the rule for deleting attempt rows, or the
maximum over stored numbers, makes it fail.

**Store rules.**

- A page read supplies content only: its items and lineup groups. The page
  row and its settings come from the page list, and so does the core's
  evidence about them.
- A page missing from the page list is gone: its rows, settings and items
  are deleted.
- A page delete is checked against the page as the user saw it, the user's
  own pending edits included.
- After a page is copied while online, the server gives the copied items its
  own ids. Until one read of the new page has arrived, the page draws the copy
  from the local preview (ids made on this device) and every edit on that page
  waits. After that read the copy's entry leaves and the page shows the
  server's items. Edits that add to the page then go; an edit made in the wait
  to a copied item names a preview id the server does not have, so it needs
  the user (`ChangedUnseen`).

Each rule has its test in `test/cloud_store_test.dart`.

### Cloud strategies: the queue

`lib/src/cloud/` holds a cloud strategy's pending ops as a list of entries and
`transition(queue, event, now:)`, a pure function from an event to the next
queue and its effects. Storage comes separately.

**Facts are stored; everything else is derived.** An entry stores:
- its op, with the field base of a merge always recorded;
- its scope: the page it was made on, both pages of a move, or the whole strategy;
- what it was authored against: the revision and digest of the row the user
  saw, no row, or a row with no readable revision;
- its send policy, which decides only whether a merge's base goes on the wire;
- the server's answer once known, with the number of the last read started
  before it arrived.

The queue stores:
- numbered attempts, each with the ops it sent and its outcome;
- numbered reads: the app asks for a number (`ReadStarted`) before each read
  and hands it back with the result (`BaseArrived`);
- base evidence, each piece the latest by read number, whatever the revisions
  say: the latest sighting of each row, the latest complete read of each page,
  the latest page list, and pages not found. Pages and their settings are
  sighted only in the page list, the same reads that write the rows the user
  sees;
- facts about the strategy: deleted, edit access lost or confirmed after
  attempt N, upgrade asked of build X by attempt N.

A row missing from a complete read of the page it was last seen on, or a page
missing from the latest page list, is absent as of that read. Only rows of the
kinds the user can see feed a digest: an item's page, place, whether it is
live, and its drawn data with field defaults filled in; never the revision,
timestamps or who deleted it. A strategy's digest covers what strategy ops are
checked against: its own fields and its live pages in order.

`entryViews(queue, now)` derives each entry's state, holds and reason to need
the user, and `standingOf` the strategy's standing, from those facts on every
event. `test/cloud_permutation_test.dart` delivers every order of a run's
answers, transport failures, reads, page and strategy removals, a page
deleted and restored, access and upgrade evidence and a clock advance, then a
restart and reads after it, and requires one final queue and the same
effects. `test/cloud_digest_test.dart` requires two rows to share a digest
exactly when they would be drawn the same.

**A check compares what the user saw.** A revision-checked op is sent only
when the base holds its row with the content it was authored against, and
then carries the base's revision. An item the base holds on a page other than
the one the edit was made on, or shows absent, needs the user, merges and
last-writer-wins edits included. If the content
differs, someone else changed something the user did not see, and the entry
needs the user. With no evidence about the row yet, the entry waits for a
read rather than assuming the row is absent. While an earlier own op on the
row is accepted but not yet in the base, the entry waits for the base. A
field-checked op (a merge with a base) and a last-writer-wins op go without
the content check. An op whose answer is unknown is sent again exactly as it
was first sent, so the server replays its first answer, until the server's
30-day memory (`serverRemembersAnswersFor`, beside `DAYS_30_MS` in
`convex/maintenance.ts`) passes. After that it waits for a read started after
the window passed. If that read holds the row at the revision and content the
op was authored against, and the op has a revision-checked form, it needs a
fresh op id (`NeedsFreshId`), and `Reissue` sends it in that checked form under
the new id. Otherwise it needs the user.

**Gone and live again are ordered by read.** An accepted entry settles when a
read started after its answer shows its row or finds its page gone, or when
the base reaches the revision it was accepted at. Work behind an accepted page
delete waits until a later read shows that page gone (it then needs the user)
or live again. A refusal because the page was deleted is reissued under a
fresh id once a read started after the refusal shows the page live.

**A dependency is satisfied by an applied answer.** An entry waits for an
earlier entry it depends on (the same row, its page's add or delete, a copy's
source page, a delete's page, page changes against renumbering) until that one
is answered applied, never because both are in one batch. A refused prerequisite
keeps its dependants waiting, and the sync state says so.

**Attempts are numbered by the queue.** A claim is attempt N, increasing and
stored; an answer counts only from an attempt that held the op, and an empty
claim is refused. A `CloudQueue` cannot be built with two entries under one id
or an attempt number that could be issued again. Op ids are minted by the
caller and must never repeat: the app uses UUID v4 (`package:uuid`). The queue
refuses an id it holds, but it cannot remember ids it has removed. The queue never makes
or compares an id derived from a page copy: work on a page whose copy is
accepted waits until a read shows the copy, and the copy's entry leaves the
queue at that read.

**Folding.** A new edit folds into the last entry for its row when that
entry has never been sent and nothing later touches its pages or the page
list. That entry may be waiting only behind a claimed or unanswered earlier
edit of the same row, or for its retry time; neither changes what it will be
sent against. It keeps its place and what it was authored against. It never
folds into an entry held behind something refused, needing the user, on a
deleted page, or behind page work, a copy or a strategy change. An add then a
delete cancel only when nothing else in the queue targets that row. A merge
folds into an earlier merge only when it names no field the earlier one does
not, and it writes only the fields it names. `test/cloud_fold_test.dart`
checks every pair `fold` accepts against the two ops in sequence through
`applyOp`, stopping at the first refusal as the queue does: alone, behind a
claimed edit of the same row that is then applied or refused, and after a
teammate's change. What survives: an element patch into an element patch
(whole into whole, or a merge into a merge with the same fields or more) or
into an element add, a whole lineup patch into a lineup patch or add, and an
add then a delete cancelling. `test/cloud_burst_test.dart` measures bursts of
2 to 20 moves, rotations and resizes of one item, claimed part-way.

**Cost.** A queue indexes its attempts by op id and its entries by row, page
and the dependencies above (`lib/src/cloud/derivation.dart`). Each queue
carries its views and tally forward from the queue before it: an event
recomputes the entries it touched, the entries whose base evidence it changed,
any whose retry time or 30-day window has passed, and the later entries that
depend on one whose view changed. A page read or a header read touches every
entry it gives evidence about; a restart or a lost connection touches them
all. `test/cloud_cost_test.dart` counts the views derived and index entries
visited for an edit, a claim, an answer and a transport failure, with the
views and tally the app asks for afterwards, and requires the same count on
queues of 100, 1,000 and 3,000 entries. Copying the entry list and maps into
the next immutable queue still grows with length; on a 1,000-entry queue
those events take 0.3 to 0.5 ms at the median (`CLOUD_COST=1` prints the
times, `CLOUD_COST_TIMES=1` also fails above 2 ms). The model test derives
the views and tally afresh after every step and requires them to equal the
carried ones.

**The sync state** (`Tally`, `syncStateOf`, `accountSyncState`) is derived
from the entries and the standing. An empty queue reads as all saved only in
good standing. The app combines it with what only it knows: media uploads,
text drafts, whether the session is ready.

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
and two commits on that page; `growth` times adding, moving and removing
one strategy at library sizes from 100 to 2,800, one library edit at a
time. `test/store_budget_test.dart` counts what each
of those asks the engine to read, list and write, and how many keys each
listing returns, and fails when a count grows; it includes a strategy of 20
pages with 300 items each.
