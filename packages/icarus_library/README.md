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
and `CommitUnknown` whole or nothing by the next lease. An in-doubt commit
is judged only after a new lease, because an engine may finish it while
granting that lease (the IndexedDB engine does, below); no engine may leave
one in part.

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
  which the storage reported durable (SQLite synced its log; a browser
  reported a strict transaction complete) and so survives a crash as far as
  that report holds; `CommitRefused(failure)`, with a guarantee that nothing
  changed; or `CommitUnknown(failure)`, meaning the next granted lease shows
  all or none of it and the engine cannot say which.
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

The library is one database named by the caller, with two object stores:
`rows`, whose keys are `[area, key]`, and `last`, which holds the record of
the last commit (below). IndexedDB compares those arrays by code
unit, exactly, and a prefix is a key range from `[area, prefix]` up to the
next string after the prefix. There is no SQLite and no WebAssembly on the
web.

- **A commit is two transactions, and lands whole.** Both run with strict
  durability over the `rows` store and a second store, `last`.
  1. **The record.** One put of a single fixed record, `last/commit`,
     holding the commit's complete list of puts, deletes and area clears. A
     transaction with one request is either kept or not; there is nothing
     queued after it that the browser could keep on its own.
  2. **The changes**, as one transaction holding every put, delete and area
     clear (a delete over the area's key range).

  The next commit's record overwrites this one, so there is no third
  transaction and nothing to clean up. Commits on a lease take turns, and a
  turn lasts until the commit's outcome is known, so the next record is only
  ever written after a commit known to be whole. When a commit's outcome is
  in doubt, the lease itself is in doubt: it ends, and every later commit on
  it, queued ones included, is refused with `LeaseEnded` before writing
  anything. So a record that a partly kept commit still needs is never
  overwritten; the next lease finds it and completes the commit.
- **What each outcome means.**
  - The record refused (an abort that is not for room, or a failure to start
    it): `CommitRefused`, nothing changed.
  - The record aborted for room (`AbortedForQuota`) or given no answer
    (`NoAnswer`): `CommitUnknown`. The record may or may not have been kept,
    and the next lease settles it either way, whole.
  - The record kept, every change queued, and the changes `complete`:
    `CommitApplied`.
  - The record kept and the changes aborted for any reason, failing to start,
    or given no answer: `CommitUnknown`. The next lease completes the
    commit. Once the record has landed, the commit is never reported refused,
    because the next lease will apply it.
- **Finishing the last commit while taking the lease.** After the lock is
  held and the browser's durability checked, and before the lease is granted,
  the engine reads the record and checks the rows against it: every key it
  put holds that value, every key it deleted is gone, and every area it
  cleared holds exactly the keys put after the clear. It waits for every
  read it started, and a read that failed refuses the lease rather than
  letting a mismatch it did see choose a replay. If they match (the usual
  case), taking the lease writes no row. (Taking a lease still starts and aborts
  a read-write transaction to probe strict durability, and opening a format
  1 database runs the browser's upgrade; neither changes a row.) If they do
  not, the engine applies the
  record's changes again; puts, deletes and area clears give the same rows
  however many times they run, so a commit that landed in part is completed,
  one that landed whole is untouched, and one whose record landed but whose
  changes never started is applied whole. This is the one write taking the
  lease may make: the store never commits at open, but this engine may
  complete its own last commit, which it already promised, while taking the
  lease. Recovery is a property of the next lease that is granted: a lease
  that is refused or times out may already have written some of the
  replay's rows, and the next one finishes the job. If the replay fails for
  room, the lease is refused as `StorageFull` (`OutOfRoom`), the record
  stays, and nothing is lost; the next lease with room completes it. A replay
  that throws while it is being queued is aborted, and the lease is refused
  once the browser confirms the abort (or says the abort failed). An intact
  library opens on a full disk, because the check only reads. A record is
  accepted only if it is exactly what the engine writes: an object with
  `format` equal to the engine format and `changes`, nothing else, every
  change of a kind and with names and lengths a commit is allowed. Anything
  else is `DamagedLibrary`, or `NewerFormat` when its format is newer, and no
  row changes. The check is never skipped.
- **Why.** Firefox can keep part of a transaction that aborted for room:
  requests queued after the failing one still take effect
  ([bug 2080749](https://bugzilla.mozilla.org/show_bug.cgi?id=2080749),
  unconfirmed and unfixed when this was written). Through this engine in
  Firefox 160 it happened 5 runs out of 5 before the room check existed. And
  a put that throws while the changes are queued, followed by an abort that
  throws too, can leave the browser completing the transaction with the puts
  queued before the throw. Both now end in `CommitUnknown` and a next lease
  that finds the commit whole. The engine tells a quota abort from other
  aborts by `transaction.error.name` alone.
- **Room is checked before a commit.** The engine asks the browser for
  `navigator.storage.estimate()` when it leases. Every commit is charged for
  its record (1 KiB, plus two bytes per character and 1 KiB for each change
  in it) and for its rows (two bytes per character of area, key and value
  plus 1 KiB per put);
  its charge is reserved when the commit is admitted and given back if the
  commit is refused, so commits issued together are admitted one after
  another against the room left by those before them. A commit that would
  leave less than 1 MiB is refused as `CommitRefused(NoRoomForCommit)`, with
  nothing written. A commit that holds no put (only deletes and area clears)
  is admitted whenever its record alone fits in what the estimate says is
  left, without the margin, so a full library can always free room; if the
  browser still aborts its record for room, the commit is in doubt and the
  next lease settles it whole or absent, like any other. An empty commit
  writes no record and needs no room: the record already there belongs to
  a commit known to be whole, so it answers `CommitApplied` in its turn. The
  engine asks
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
  estimate that fails after the engine had a figure leaves the room
  unchecked too: the old figure is not used as if it had been checked.
- **A full disk is a quota abort in Firefox.** Firefox does not lower its
  reported quota as the disk fills, so the room check cannot see a full disk
  coming. Staged on a nearly full tmpfs (`tool/disk_full_web.sh`), Firefox
  aborted with `QuotaExceededError` in 4 runs out of 4, and every time it
  rolled the whole commit back. Either way the next lease settles the commit
  whole.
- **Whatever is thrown is answered, and the lock always comes back.** A
  lease that throws anything while it asks for the lock, opens the database
  or checks it is `LeaseFailed`; the database is then closed, a database the
  lease created is deleted, and the lock is let go, each step whatever the
  one before it did. Every browser call made while acquiring or releasing a
  lease has a time limit (10 s by default, `IndexedDbEngine.patience`), after
  which the caller gets `NoAnswer`. An open that has already answered
  creates nothing behind the caller: an upgrade that arrives later aborts
  itself, and if the upgrade made a new database before the open gave up,
  the late success closes and deletes it. Upgrading a format 1 database is
  the browser's own transaction, so it is done or not done, never half. Release always closes the database and
  lets go of the lock, and says `ReleaseFailed` if either step failed. A
  throw while the record is queued aborts it and answers `CommitRefused` (or
  `CommitUnknown` if the abort throws too); any throw once the record has
  landed, including while reading `transaction.error`, is `CommitUnknown`. A read whose callback throws is a
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
  not open, and the store makes no commit at open. On IndexedDB the engine
  may have written rows while taking the lease, completing its own last
  commit; what is certain is that no row outside that commit changed;
- **a refused save:** `NotSaved(failure)`: the edit is not stored. The store
  stays open unless the failure ended its lease; then every later step
  answers `StoreStopped`;
- **a save in doubt:** `SaveInDoubt(failure)`: the edit may or may not be
  stored, and the store stops. Every engine settles it whole or nothing by
  the next lease;
- **a read:** `NotRead(failure)`: that read failed. As with a refused save,
  the store stays open unless the lease ended.

**Was the library just created?** `StoreOpened.origin` is `StorageCreated`
when the library held no `format` row and no row in any area when it was
opened, and `StorageExisted` when it held a `format` row or any row. The
store's open decides and reports; the store writes nothing (on IndexedDB the
engine may have just completed its own last commit while granting the
lease, described under IndexedDB). The `format` row, the store's
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
  database version (`indexedDbFormat`, 2, which is also the version the engine
  opens with). Written when the engine creates the storage. It changes when
  an older engine would misread the layout or write into it wrongly. It does
  not change for what rows hold.
- The **store format** is the store's row layout: the area and key names, and
  the shape of a summary and of every row the store reads back. It is the
  `format` row in the `library` area (`storeFormat`), written with the first
  save into a library that lacks it. It changes when
  an older store would misread the rows or write into them wrongly; a change
  that older stores read and keep correctly does not change it.

The engine format is 2 on IndexedDB (format 1 had no `last` store; opening
a format 1 database runs the browser's upgrade, which adds the store and
changes no row) and 1 on SQLite; the store format is 2. Format 2 adds cloud
strategies: a store that knows only format 1 would list a cloud strategy as an
ordinary one, leave out its unsent work and let an ordinary removal erase it,
so it must refuse the library instead. A format 1 library opens under format 2
unchanged; nothing is written by opening it. The first commit this build makes
to it, whatever that commit saves, writes `format` = `2` in the same engine
commit, and from then on a format 1 build refuses it with `NewerFormat`.
Nothing earlier shipped. A build that raises a number must also say how it
moves a library from the lower one. A
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
  room (in Firefox, a full disk too). Certain: the browser aborted the save,
  and the next time the library opens the save is there whole or not at all,
  never in part. Only possible: which of the two. Comes only as a save in
  doubt. "The browser ran out of storage while saving, so this change may not
  have been saved."

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
  origin, and hands the library to a worker while commits are in flight. It
  cuts a commit at every point it can be cut (the record aborted, aborted
  for room and kept or lost, or given no answer; the changes failing to
  start, aborted, aborted for room keeping nothing, the first request or only
  the last as Firefox did, or given no answer; a throw while queued with an
  abort that throws too) and checks that the next lease finds the commit
  whole or absent, as each answer says. It also opens an intact library on a
  full disk, refuses one whose last commit needs completing until there is
  room, refuses an unreadable or newer record, and upgrades a format 1
  database with rows. The
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

A folder row keeps `createdAt` in milliseconds when it has one, as the
server's folder row does.

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
commit whole or not at all, across areas and across a crash, so a granted
lease shows the strategy from before the edit or after it, never part of it.
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

A cloud strategy lives in the same area as a local one. Its cached rows (the
rows the server's results last showed) sit under the usual names, and these
rows sit beside them, each versioned and each read back before it is written:

- `cloud`: the account the strategy's work belongs to (the identity subject
  the app sends as `accountSubject`), and the strategy's facts (deleted on the
  server, edit access lost or confirmed after attempt N, upgrade asked of
  build X by attempt N), and that account's role on it (owner, editor or
  viewer) as the last page list the queue took said. A row without a role, or
  with a role this build does not name, reads as `RoleUnknown`.
- `assets/<page digest>`: the pictures the last page result the queue took
  listed for that page (picture id to the server's asset fields, url
  included), whole, an empty page as an empty map. It is written in the same
  commit as that result, only when it differs from what is stored, and
  deleted with the page.
- `pending/<place>`: one row per entry.
- `attempt/<number>`: one row per attempt.
- `landed/<attempt>/<position>`: one row per piece of landed work.
- `read/header` and `read/page/<page digest>`: what the results showed, as
  the queue keeps it (`Shown`): revisions and digests, not rows. A digest
  read back from here is never reused: a page result digests every item
  whose digest this run of the app has not computed. After that, an item
  whose page, revision and life are the ones `Shown` holds keeps its digest,
  because the server raises an item's revision with every change to what the
  digest covers (every convex test checks this through
  `convex/revisionGuard.setup.ts`). For the same reason the store leaves an
  item it already holds at that revision and life, on that page only, as
  stored, and encodes a group here again only when what it holds changed.
  `heldOnPage` hands out those stored rows of one page (the results, not the
  page as drawn with queued work). The app's sender seeds a memo of decodes
  from them when a page's watch begins, keyed by id, page, revision and life,
  and adds every row it decodes from an answer, whether the queue then takes
  that answer or not. It is right for one reason only: within a life a
  revision names one content, so an item at the same id, page, revision and
  life is the same row and isn't decoded again.
  Tests and driver builds also take every page from scratch, compare every
  item they leave as stored and encode every group, and fail on any
  difference (`shownTakesChecked`, on unless the build is a release without
  `ICARUS_DRIVE`).

Any row under one of these names, or under the `pending/`, `attempt/`,
`landed/`, `read/` or `assets/` prefixes, marks the area as a cloud strategy
(`isCloudName`, one function used by loading, both removals, the discard, the
folder move and the `putStrategy` guard). A name under a cloud prefix that
this build cannot decode, including a number too large to be exact in
JavaScript, holds the strategy. An area with cloud rows but no `cloud` row is
a held cloud strategy, never a local one. The library area holds one more row, `numbers`: the next
attempt and session numbers for the whole library, never reset, so a result
from a session of an earlier copy of a strategy can never pass for one of a
new copy. A number is written before anyone is given it. The row is in one
of three named states: missing, read, or unreadable. When it is unreadable,
or missing while the library holds a cloud strategy, the store does not
guess: every cloud queue reads as held, importing a cloud strategy is
refused (`NumbersUnreadable`), and local strategies are untouched. Getting out of that state needs a repair that is not built yet.

**Reads never commit.** `readStrategy` and `readPage` return the drawn rows
(the cached rows with landed work and then the queue applied) and the queue's
views and tally, as recorded. Finding a held queue changes the summary in
memory to the counts of the cached rows the held pages draw, saved with the
next commit. Drawing a page loads the pages that hold
the rows its queued and landed work act on, so a page draws the same in a
fresh store as in a warm one. An edit finds its row the same way, so an
element shown only by landed or queued work can be edited. A page whose
content no stored result covers, and every page of a held strategy, says
`ContentNotRead` instead of looking empty, and copying such a page is
refused (`CopyNeedsContent`). `commitAs` and `commitAllAs` add edits.
`record` takes a list of events and first records any passed resend window, so
`record(account, id, [])` is the store's `look`: it writes the expiry, and a view can
never show one that is not on disk. A strategy's current session, and what
that session has been shown (including the freshness the page-delete rule
reads), are kept at the library level in memory, so unloading the strategy,
or a call that reads its queue back from disk, does not end them: a strategy
loaded again in the same run takes results issued under its session and keeps
what it was shown. A full reopen starts a new session, where nothing stored
counts, so none of this is persisted. The sender calls `record(account, id, [])` on its
timer and before it shows the sync state. Loading a queue opens no session: until
a call records `AppRestarted` or `ConnectionReturned` (which commits the new
session number and returns it), the queue is in session 0, which is never
issued, so every result is refused, including one labelled 0. `addCloudStrategy` creates the strategy
empty (its `cloud` row and nothing else), opens a session, and runs `record`
on the results it was given, in one commit, by the same rules as any later
result. The library summary carries the sync tally; every page whose drawing
a call can change gets its count rebuilt in that call, including a page a row
left and the pages of queued and landed work on any row of a page the call
changed. A clean stored summary of a cloud strategy is listed as
`CloudUnverified` until that strategy's queue has been loaded in this run,
because only the queue can say nothing is waiting; loading it on the normal
lazy read promotes it and sends `StrategyRefreshed`. The status is on the
list entry itself, so it never compares equal to a summary kept here. Stored
pending and held counts show at once, and any time loading a queue changes a
strategy's entry, held included, the store sends `StrategyRefreshed`. Reading
a page also counts that page as drawn, so after any page load the list and the
page agree (a reader that learned a payload kind stops listing it as newer). No
queue is loaded just to draw the list. Every row the drawing rebuilt from
stored work, rather than taking it from the cached rows, goes through the
same parse and reader check as a row read from storage, so a moved row this
reader cannot read draws as unreadable. Drawing builds rows only from the
pages it was asked for and the pages the rows' queued and landed work point
at, and a call re-encodes the stored results only when it changed what they
show, so one queued edit does the same work on a strategy of 10 pages and of
100. A cold read of one page still lists every key of the strategy (3,303 at
100 pages); that is measured and not yet addressed.
Loading a strategy's queue is five listings (`pending/`, `attempt/`,
`landed/`, `read/`, `assets/`) and one read (`cloud`).

**Role and pictures.** `CloudStrategy.roleOf(account)` is the stored role for
the account that owns the work and `RoleUnknown` for any other, so a second
account on the machine never sees the first one's role. `editsAs(account)` is
true only for a known owner or editor role while edit access is not lost: lost
access wins over the stored role, and unknown never edits. A page whose
content a stored result covers reads `ContentShown`, carrying its pictures; a
page with content but no `assets/` row (stored before pictures were kept)
reads `ContentNotRead`, and is read again. A picture an element names that
the map does not hold is one the server did not describe; the element's row
keeps its reference either way. Only a result the queue takes stores either:
an older result, one out of place, one deferred until the list shows its page,
or one from an ended session stores neither.

**Results reach the cached rows in the order they arrive.** Results come
from subscriptions, which deliver ordered states, so the latest one wins:

- A header replaces the strategy row, the page rows and the settings, and a
  page it no longer lists is gone, with its settings and content.
- A page read replaces that page's row and its whole content. A row it
  holds that the cached rows have on another page at a higher revision stays
  where it is.
- A page-gone answer removes the page.
- A result from a session that has ended changes nothing.

**A queue row this build cannot read holds the whole strategy.** An entry,
attempt, landed or results row that does not decode or comes from a newer
version, an entry whose work or scope does not fit its op, a merge without
its field base, an op id another entry holds, or a missing `cloud` row beside
queue rows puts the strategy in one sealed state: held. Its cached rows still
read and draw, and `readStrategy` returns them with `CloudHeld`, which lists
each row it could not read. Nothing is recorded, sent or rewritten: `commit`
and `record` are refused with `QueueHeld`, and so is `rebuildSummary`. Held is a standing of its own in
the summary, kept in memory when the store finds it and saved with the next
commit; a summary from a newer build also reads as held. A newer build reads
the queue; otherwise the only way out is `discardUnreadableQueue(account, id, const
DiscardsUnsentWork())`, which deletes the queue rows and writes fresh facts
and the rebuilt summary in one commit, or changes nothing. On a queue that is
not held it refuses with `QueueNotHeld` and writes nothing; it does load the
queue to find that out, so a strategy listed as unverified is promoted and
the store sends `StrategyRefreshed`, as any first read of the queue does.
Removing a strategy releases its session record. Discarding one's
own readable work is the queue's own discard. While the numbers
row holds the library, the summary it writes still says held. Removal reads
the strategy's queue from disk and refuses a held queue or outstanding work.
A read that fails ends a removal, a discard, a folder move or the
`putStrategy` guard as not saved; a failed read is never taken as "not a
cloud strategy".

**One call, one commit, computed once.** Each `commit`, `commitAll` or
`record` call runs all its events through the queue first, then computes the
writes once from the state after the last event: the cached rows that differ,
every queue row that differs, the stored results that differ, the library's
numbers and the summary. The queue a step hands back is kept even when the
event did not apply, so a resend window that passed is written down by the
call that found it. A call in which nothing applied writes nothing. A commit
either lands whole or not at all. When the engine answers that the outcome
is unknown (`SaveInDoubt`), the store stops: it releases its lease and
answers every later call as shut, so the caller reopens the store before it
retries or reads, and the reopened store reads what actually landed. A
commit refused because the lease ended (`LeaseEnded`) stops the store the
same way. Any other commit that was refused or not stored is different: the
store stays open, and memory is exactly as it was before the call (the
queue, its session and the numbers, with the cached rows read back from
disk), so the same event delivered again applies.

`test/cloud_store_test.dart` pins these rules and the writes each kind of
call makes. `test/cloud_store_model_test.dart` runs the model through the
store on the memory engine. After every successful commit it opens a fresh
store over the same engine and requires the entries, attempts, landed work,
facts, numbers, stored results, cached rows and summary to equal what the
first store holds, compares each page's count in the list with what the page
draws, and counts engine commits around every read (none may happen). About
one commit in fourteen is answered unknown (landed
or not) and one in twenty-eight refused. It reopens between commits, restarts
with new client ids and builds, delivers results from sessions that ended
(none may change a row), removes and adds the strategy again with a result
from the earlier copy in flight, writes rows from a newer version, and
submits mixed event lists. After a call that was refused or not stored it
requires memory to be what it was before the call, and delivers the same
events again. It labels results with the session it last saw committed, as a
subscription would, never with whatever the store holds now. It moves
elements across pages, lands two moves of one row before any result, edits a
row shown only by landed work, deletes the source page of a queued move, and
compares a held queue's pages with the list. No element may be drawn on two
pages. At the end it drains against a server model with teammates and
requires the drawn rows to equal the server's.

**Whose work it is.** A cloud strategy belongs to one account, given to
`addCloudStrategy` and kept in its `cloud` row. Damage never widens what a call
may do. The account is read from that row by itself, so damage to another
field holds the queue and leaves its owner known, and the owner can still
discard their own held work. A row whose account cannot be read has an
unreadable owner (`OwnerUnreadable`), and that permits nothing: its strategy is
held, and no account may discard it (`OwnerNotRead`). Every call that changes
or sends a cloud strategy's work names the account asking: `commitAs`,
`commitAllAs`, `record` (which also carries claims, answers, results, user
choices and session events) and `discardUnreadableQueue`. Each keeps the order
it reads in: it finds the strategy and checks its row, then loads the queue.
Once the queue is loaded and the owner known, another account is refused with
`WorkOfAnotherAccount`, ahead of every other queue refusal (`QueueHeld`,
`ResultOutOfPlace`, `QueueNotHeld`). A refusal found before that point
(`NoSuchStrategy`, `StrategyNotReadable`, a failed read) comes first, because
it is the first true thing the store knows. In every case a call from another
account applies no event, issues no session or attempt number, and commits
nothing; it may load the strategy exactly as a read does, which can move a
listed strategy from `CloudUnverified` to `KeptInCloud` and send
`StrategyRefreshed`. `commit` and `commitAll` take no account: they are for
strategies kept on this device, and refuse a cloud strategy (`AccountNeeded`),
as `commitAs` refuses a local one (`NotACloudStrategy`). Reading names no
account, so the list and the sync state can show another account's work.
Nothing moves work from one account to another, and nothing in the store
clears it: removing a strategy is refused while it has outstanding work or a
held queue, so another account's work, and held work whose owner cannot be
read, stay until their owner, or a newer build that reads the queue, acts on
them.

### Cloud strategies: the queue

`lib/src/cloud/` holds a cloud strategy's pending ops as a list of entries and
`transition(queue, event, now:)`, a pure function from an event to the next
queue and its effects. Nothing here touches storage.

**The server judges delivery.** An op leaves the queue, or is handed to the
user, only on the server's answer to it:

- Applied, or nothing to do: done.
- Rejected: the user decides, with the row the server sent. Later work on
  that row waits behind it. A rejection whose row already holds exactly what
  the op wrote is done; that is judged only for strategy and page renames,
  because a rejected element's row comes without its page and place.
- Failed: the user decides. A failure is a verdict, so it is not retried.

Results, the rows the server sends while the app watches a strategy, never
settle or drop an entry. They end the drawing of landed work (below), and
they tell a whole-row write whether its row is as the user saw it. Two
results also stop sending: one saying the strategy is gone stops every claim
for that strategy, and the page delete, until
[#670](https://github.com/SunkenInTime/icarus/issues/670): the server guards a
page delete by the strategy's revision only, so one rule decides a page
delete, with no partial cases. It is decided only when the device holds a
page list and a result of that page, both from the current session and both
received after this device's last answered op that touches that page or the
page list; until then it waits, and `resultsNeeded` asks for whichever of
the two is missing (`PageListResult`, `PageResult`). Then: if the page list
says the page is gone, the delete goes and the server answers (the page's
own result is not needed then, since it cannot change the outcome). Otherwise the
page (its name, its settings, and the rows on it by id and content, leaving
out a row a result shows on another page) is compared with what the user
saw; equal means the delete goes, anything else means the user is asked.
Both results arrive after every answered op of this device's that touches
the page, so they already include its landed work. A delete with nothing
ahead of it on a page already read this session goes at once; one queued
behind this device's own work on that page waits for the page list and the
page to come round once more after the last answer, which is deliberate and
goes away with #670. Every answer, whatever it says, resets the results of
every page its op touches (both ends of a move) and, when it touches the page
list, the list for every page, and throws away the views computed from them
in the same step. A page list and a page result that disagree about whether
the page exists are no verdict: the hold waits and asks for both. For a page
delete the hold's verdict that the page is gone comes before the revision
check, and a page delete queued behind other entries asks for nothing until
it reaches the head. This is the one part of the queue where what the device
has read decides anything; every review of it found another edge, and the
page it protects goes to the trash, from which it can be restored. All of it is in `lib/src/cloud/held_page_delete.dart`, which comes
out in one piece when the server checks the page.

**Entry states.** An entry is in one of four states, derived from the facts
it stores and the attempts that sent it:

- `Waiting`: never sent, or sent and refused whole (upgrade, sign-in, access);
  it may be held behind an earlier entry or waiting for a result.
- `Sending(attempt)`: in an open attempt.
- `Unanswered`: sent, and the answer never came. It is sent again with
  backoff, under the same op id, always in its checked form; after
  `retriesBeforePause` failures it needs the user, who can retry. The
  backoff is measured from the last failure's time; when the clock reads
  earlier than that time it has moved back, the wait cannot be measured, and
  the entry is sent at once rather than held until the clock catches up.
- `NeedsUser(reason)`: rejected or failed (`RefusedByServer`), unanswered for
  29 days (`WindowClosed`), retries exhausted, page delete held, too big to
  send (`Oversized`), written over a row someone else changed
  (`ChangedUnseen`), found at commit to be drawn over a row that changed or
  was replaced since (`ChangedSinceDrawn`, counted with the server's
  rejections), or a format this build no longer sends.

**What an entry stores.** Its op, with the field base of a merge always
recorded; its scope (the page it was made on, both pages of a move, or the
whole strategy); what it was authored against (the revision and digest of
the row the user saw); the session it was authored in; how it was made
(`madeAs`, stored only when live or checked); the server's refusal once
known, or the conflict its commit found; and whether its resend window has
passed. The queue stores
numbered attempts, the landed work, the latest results of this session, the
strategy's facts (deleted, edit access lost or confirmed after attempt N,
upgrade asked of build X by attempt N) and the session.

**Sessions.** A restart, a reconnect or an account change opens a new
session (`SessionOpened`). Results carry the session they were read in, and
one from a session that ended does not apply. Rows from earlier sessions
stay for drawing and for ending landed work, but the two decisions results
make (a page delete, and a write behind a landed merge) use only a header and
pages read in the current session.

**The form of a send.** Two kinds of op have a live form, the one that skips
the server's check so that two people editing at once converge on the last
arrival: a field merge sent without its base, and an element or lineup delete
sent last-writer-wins. Every other op is sent the same way in both forms. A
live send carries a basis: a time the server gave this device in an earlier
answer. The server refuses a batch that arrives more than 30 s after its basis
(`UNCHECKED_OUTSIDE_WINDOW`), so a call the transport delivers late cannot
overwrite a teammate's newer work.

- The queue holds the latest server time it was given, with the moment it
  arrived by the device's own monotonic clock (`ServerTimeHeld`). It holds
  one only while connected, and every new session (a restart, a reconnect, an
  account change) and a lost connection start with none. The session is in
  memory only.
- An op takes the queue's basis when it is written (`PendingOp.basis`, stored
  as `basis`). Nothing changes it after that: a fold keeps the earlier op's
  basis, the older one, and a "keep mine" replacement has none, so it always
  goes checked. A stored op without the key has no basis.
- A claim is given the device's monotonic reading (`BatchClaimed.elapsed`),
  and `sendPolicy` decides each op's form. It is the only place that does:

| Attempt on record | Connected, and written in this session | Basis | Age at claim | Form |
|---|---|---|---|---|
| yes, or the entry was made checked | any | any | any | checked |
| no | no | any | any | checked |
| no | yes | none | any | checked |
| no | yes | yes | no monotonic reading | checked |
| no | yes | yes | more than 20 s (`liveFor`) | checked |
| no | yes | yes | 20 s or less | live |

- The batch carries the oldest basis among its live ops (`SendBatch.basis`),
  and none when it has none. Every live op passed the age check at the same
  claim, so the oldest passes too, and a batch the server accepts is within
  30 s of every live op's own basis.
- A batch refused for lateness (`BatchRefused`, `uncheckedTooLate`) did
  nothing on the server. Its ops wait again with no retry delay, and since the
  attempt stays on record, they go checked, under the same op ids. An edit to
  the same fields does not fold into them (folding needs an op never claimed).
  The refusal also drops the server time the queue held: it proved older than
  the device's clock said (a device whose monotonic clock stopped while it
  slept), so edits go checked until an answer brings a new one.
- A server time is held only by the session that asked for it
  (`ServerTimeHeld.session`); one that arrives in another session is
  ignored.
- The 10 s between `liveFor` and the server's 30 s covers the server reading
  its clock when the mutation starts (so the device's count runs about half a
  round trip behind) and the call's own trip.

**The resend window.** The server remembers its answer to an op id for 30
days (`serverRemembersAnswersFor`, beside `DAYS_30_MS` in
`convex/maintenance.ts`), so sending the same op id again inside that time
replays the first answer instead of applying it twice. The queue resends only
until 29 days after an op's first send (`resendWindow`), a day of margin. A
batch refused whole (upgrade, sign-in, access) was never tried by the server,
so it does not count as a first send, even when the refusal arrives after the
attempt was given up. When a transition finds the time
passed, it records it on the entry before anything else, even when the event
changes nothing more; from then on the entry needs the user and is never sent
again, even if the clock moves back. Views show only what a transition
recorded: `look(queue, now)` records any expiry and returns the recorded
queue with its views and tally, so a caller never shows an expiry it did not
keep. Deadlines are kept in the queue's index bucketed by day, so the check
visits only entries that are due. The queue cannot stop a send it already
handed over: the sender must give an attempt up as unanswered within
`sendGiveUpAfter` (one hour) of claiming it, well inside the day of margin.
An open attempt shows as sending until it does.

**Which revision an op names.** An op names the revision the user's edit
was made against. The device keeps, per row, a justified row: a revision
together with the content at that revision, compared by content for every
row, the strategy included (its own fields and the order of its live pages,
which is what a strategy-revision write covers). Nothing is justified when a
session opens, so a row cached from an earlier session never counts. A row
becomes justified in two ways: a result of this session shows it, or this
device's own op on that row is answered applied at exactly the revision
`applyOp` gives for that op over a row that was itself justified when the
edit was made. Every entry records the row it predicts
when it is made, and whether the row it was made against was justified (the
row a queued edit ahead of it predicted, or the justified row itself); landed
work keeps the prediction only when both hold and the answer matched. An op
that changes nothing predicts the row as it is, so "nothing to do" at the
justified revision keeps the row justified. Any other answered revision,
including "nothing to do" at another revision, means someone else wrote in
between: the row is not justified until a result shows it, and every later
edit of that row loses its justification too.
A justified row is stored state, never read off what is drawn.
This rests on two facts about `convex/ops.ts`: every applied write raises its
row's revision by exactly one, and no queued write changes a row without
raising it. Three paths outside the op loop break the second fact, and none
of them is something the queue sends: trashing and restoring a page set
`deletedAt` without a revision, deleting a folder clears a strategy's folder
without one, and a tombstone purged after 30 days can come back at revision
1. That is why a page delete's answer never justifies a page row, why
nothing queued checks the folder, and why justified rows from answers never
outlive the 29-day window. A result never changes the revision an op names,
and `_judge` is the only place an outgoing revision is chosen.

- An op made with nothing of this device's ahead of it on its row goes at
  its authored revision, and the server decides.
- A field merge that stays on its page names its fields and goes at its
  authored revision once no earlier edit of this device on that row is still
  unanswered; landed work never holds it, and the server merges it field by
  field. A merge that names another page is written whole by the server, so
  it is gated like a whole-row write.
- Any other op made behind this device's own queued or landed work on its
  row, including work answered "nothing to do", goes
  only once that row is justified at the revision it names, with the content
  the user saw (or already holding what the op writes, so the server's answer
  settles it). Otherwise it waits for the row's result (`AwaitingResult`),
  on the page a result last showed the row on, or the page the op was made on
  when no result has shown it (a teammate may have moved it since the editor
  drew it).
  It needs the user when a result of this session shows the row otherwise,
  or when a result of its page no longer holds a row that results showed or
  this device added. Once a current result shows its page gone, it names
  the revision the user saw instead of waiting for its row; its other holds
  and the resend window still apply, and a delete goes in its checked form,
  never last writer wins, so the server compares that revision. The server's
  answer settles it. For example, `PAGE_DELETED` for a page in the trash
  (`RefusedAsPageDeleted`), not found or nothing to do for a row purged with
  its page, refused as changed for an item a teammate moved, or applied if a
  teammate restored the page before the write arrived. A solo
  session
  waits only after a session opens: such an op made behind landed work, or
  behind work queued in an earlier session, waits for its row's first result
  in the new session.
- An op the server refuses as `PAGE_DELETED` needs the user as
  `RefusedAsPageDeleted`, counted on its own (`Attention.refusedAsPageDeleted`)
  so the sync UI can ask one question for all of them. The queue never holds
  it, sends it again or settles it from a page list: a teammate restoring the
  page changes nothing until the user answers. The answers are the ones every
  refusal has. Keep mine, once the page is restored, sends it under the new id
  it is given; Discard lets it go. After a purge, keep mine is refused as
  `not_found` like any other refusal.
- A page add, reorder or delete answers only the strategy revision, so the
  pages it renumbers are not justified by the answer, and a page rename
  behind one waits for a page list.
- An undo of a delete ([#668](https://github.com/SunkenInTime/icarus/issues/668))
  goes without asking only over this device's delete answered at the
  revision the undo names, with the tombstone as the user saw it justified
  (by the delete's prediction, or by a result of this session), within 29
  days of first sending that delete. Until the tombstone is justified it
  waits for its row's result; anything else needs the user.
- Keep mine names the revision the user chose theirs over.
- A revision means something only within a row's lifetime, and a purged
  tombstone can come back at revision 1. So an entry that carries a revision
  check and was written more than 29 days ago needs the user before it is
  sent, and the reason says it was written too long ago (`WrittenLongAgo`)
  even when it was first sent late and its answer was lost: an edit written
  offline and first sent on day 28 gets one day of resends. An entry without
  a revision check that was sent and lost needs the user after 29 days from
  its first send (`WindowClosed`). Keep mine starts the 29 days again.
- Live sends: a delete sent live is last writer wins, as in the shipped app.

**A row's life.** A revision orders writes within one life of a row. A row's
life is its `createdAt`, which the server sets on insert and never rewrites,
so a row deleted and created again under the same id starts a new life at
revision 1. Wherever the queue stores a revision (shown rows and the highest
version each row has shown, authored, produced and kept-over-server rows,
server copies and landed work) it also stores the row's life when it knows it.
A `Version` orders by life first when both lives are known, and by revision
otherwise, so a higher revision under an older life never outranks a newer
life. Records written before lives were stored read back with no life and
compare by revision, as they did. The server never sends a row without a life
(every row table requires `createdAt`, and so does every read's return
validator), so the store refuses a result with a row that has none
(`ResultWithoutLife`) instead of storing it: a version with no life is only
ever one stored before lives were. Such a version sits outside the order
lives give: a row resting at a highest version stored with no life compares
by revision against a later life of the row, which a newer life should
outrank. Only a store written before lives were stored can hold one, and the
cloud store has not shipped.

**Ops name lives.** An op names the life of the row the user edited
(`expectedLife`), taken from the row as authored or, for keep mine, from the
server's copy the user chose theirs over; sent again, it names the same life,
never the life of a row shown since. An op whose row's life the device does
not know names none: such an op is behind an unanswered add, and the 29-day
window asks the user long before a purge could bring the id back. Each entry
keeps the strategy life it was written in, and a batch names it
(`strategyLife`); ops written in two known lives of the strategy never share a
batch. The server refuses an op whose named life is not its row's as
`row_replaced`, with the current row: the op is never counted as delivered,
even when the current row holds what it wrote, the user decides, and the row's
page is read again. The server refuses a batch whose strategy life is not the
strategy's as `STRATEGY_REPLACED`: its ops go to the user, the page list is
owed, and while it is owed nothing is sendable. The debt is stored with the
results (`listOwed`), counted in the tally (`readsOwed`), and paid by the next
page list. An answer with no life (applied, replayed or rejected with a copy
that has none) is that op's own answer, `AnswerWithoutLife`: the op asks the
user, as a forgotten answer does, and the batch's other answers are kept.
Two edits of a row fold only when they name the same row life and the same
strategy life, and `fitsBatch` is the one rule for which ops may share a batch:
the queue's claim and the app's picker both use it.

**One strategy life per record.** A queue record holds the edits of one life
of its strategy, and that life only moves forward: a life is a creation time,
so a later life is a larger number. One rule in the queue, `resultFit`, says
what a result may do, and the store asks it before writing anything:

- a page list of an earlier life than the record's is old news and is
  dropped, nothing adopted and nothing paid;
- a page list of a later life sets every entry aside in one step (below);
- a page result whose page row has a later life than the list shows owes the
  page list and is not applied; the page is read again after the list;
- a page result of an earlier life than the list shows is dropped.

Setting aside moves the entries into a new generation of the record's
set-aside list (`StrategyFacts.setAside`, stored in the same row as the
record's other facts, so the move and the removal of every queued row are one
commit). Each generation keeps the life its edits were written in and the life
that replaced it, and a kept entry's place is never given to a new entry.
Adopting the new life drops everything that described the old one: attempts,
landed work, everything shown, the store's page content (so every page is read
again before anything is drawn), and a strategy seen as gone, which the
replacement is not. Set-aside edits are kept so the user can be shown what was
not applied; queue logic never reads them again, nothing sends, draws, folds or
offers anything on them, and only `UserDiscardedReplaced` removes them. The
sync status counts them (`Tally.setAside`) under its own face,
`Face.strategyReplaced`; its words are a placeholder. `STRATEGY_REPLACED` for
life L only owes the page list, and only a list of a life after L, or an answer
that the strategy is gone, pays that debt; a refused read keeps the
restriction. Ops share a batch only when they were written in the same strategy
life, an unknown life included.

**What has been read.** The page list and each page have one read state:
not read this session, read this session, owed, or refused. A read is owed
when an answer says what was shown may be stale (`row_replaced` owes the row's
page, `STRATEGY_REPLACED` the list); it is refused when the server sent a
result the store would not keep (`ResultWithoutLife`, `ResultOutOfPlace`), and
the sender records that as `ResultRefused`. Owed and refused reads are stored
with the results and survive a restart. While the list is owed or refused
nothing is sendable, and while a page is, nothing on it is. Owed reads count as
`readsOwed` and keep the strategy from showing as saved; refused reads count as
unreadable work, the face other unreadable work has. The sender reads an owed
page at once and a refused one on its read backoff; a read the store keeps, or
an answer that the strategy is gone, pays the debt.

**When the queue stops making progress.** Every way a cloud strategy can stop
moving has a row: what it waits for, what the sender calls meanwhile and how
often, the bound, the face the sync status shows, and what starts it again.
All reads go through one ladder in the sender: a read that does not settle
what it was for, a result the queue does not take, and a read that is lost all
climb the same rung for that list or page, and an edit-access check climbs
the strategy's access rung, which stops after its bound until the user
retries, a sign-in, or the app starts again. A stalled wait ends early only on
new evidence: a server answer about the strategy that is not only applied edits
(a rejection or a batch refused whole), the user pressing retry, or a new
connection. An edit is not evidence, and neither is an answer that only
confirms this device's edits, so a drag cannot turn into a read per move. The table is written by `test/library_store/stall_exits_test.dart`
from `lib/library_store/stall_exits.dart`, with the calls counted in a
simulated hour of each, and the test fails when the two disagree
(`UPDATE_STALL_EXITS=1` rewrites it).

<!-- stall exits: generated by test/library_store/stall_exits_test.dart -->

| Stall | Waits for | Calls | How often | Bound | On screen | Calls, first hour | Calls an hour after | Goes again on |
|---|---|---|---|---|---|---|---|---|
| A strategy is read for the first time, or again after it was replaced | the page list; then a page only when it is shown, when work names it, or when a replaced life owes it | the page list, then each such page, one per step | at once, one read per step | one read per page | saved | 1 | 0 | each page that is read; a page that will not read climbs the ladder as a lost read |
| A result the queue asked for does not settle it | the page or page list a held edit or a debt names | that read | at once, then 2 s, 4 s, 8 s, 16 s, 32 s, 64 s, 128 s, 256 s, 512 s apart, then every 10 min; never twice within 2 s | 3 reads, then shown as could not resolve; the ladder goes on | awaitingResult | 15 | 6 | a read that settles it, news about that subject: an edit on it rejected or failed (its page, or the page list for an edit of the strategy, a page or settings), a batch refused whole (the page list), the user pressing retry, a new connection, or a sign-in after a sign-out or to another account (a sign-in that only refreshes the same account on the same connection does not); each no sooner than the floor after the last read of the same subject |
| Our own answer is newer, by the server clock, than every result read since, and none of them shows what it wrote (the clock went back on a new connection) | a read of the page or page list whose server time reaches the answer's, or one that shows the written row at the answer's revision or later. Answers that leave no row to show: a page reorder, add or delete, on every page it renumbers; an edit of an item, for the page list's view of its page (a list shows no items); an answer with no revision (nothing to do, failed, rejected without the server's row), or answers on one subject of which one had none; the page an item moved off | that read | at once, then 2 s, 4 s, 8 s, 16 s, 32 s, 64 s, 128 s, 256 s, 512 s apart, then every 10 min; never twice within 2 s | 3 reads, then shown as could not resolve; the ladder goes on | awaitingResult | 16 | 6 | a read whose server time reaches the answer's, which the ladder issues once the server clock has caught up; a read showing the write; news about that subject: an edit on it rejected or failed (its page, or the page list for an edit of the strategy, a page or settings), a batch refused whole (the page list), the user pressing retry, a new connection, or a sign-in after a sign-out or to another account (a sign-in that only refreshes the same account on the same connection does not); each no sooner than the floor after the last read of the same subject |
| The queue does not take a result (a page list of an earlier life than the record holds) | a list the queue takes | the page list | at once, then 2 s, 4 s, 8 s, 16 s, 32 s, 64 s, 128 s, 256 s, 512 s apart, then every 10 min; never twice within 2 s | 3 reads, then recorded as refused (unreadable work); the ladder goes on | unreadableWork | 14 | 6 | a list the queue takes, news about that subject: an edit on it rejected or failed (its page, or the page list for an edit of the strategy, a page or settings), a batch refused whole (the page list), the user pressing retry, a new connection, or a sign-in after a sign-out or to another account (a sign-in that only refreshes the same account on the same connection does not); each no sooner than the floor after the last read of the same subject |
| A page is newer than its page list | a page list showing the page in that life | the page and the page list, each on its own ladder | at once, then 2 s, 4 s, 8 s, 16 s, 32 s, 64 s, 128 s, 256 s, 512 s apart, then every 10 min; never twice within 2 s | 3 reads, then recorded as refused (unreadable work); the ladder goes on | unreadableWork | 29 | 12 | a list that shows the page, news about that subject: an edit on it rejected or failed (its page, or the page list for an edit of the strategy, a page or settings), a batch refused whole (the page list), the user pressing retry, a new connection, or a sign-in after a sign-out or to another account (a sign-in that only refreshes the same account on the same connection does not); each no sooner than the floor after the last read of the same subject |
| Our own answer is ahead of the server clock, and the editor watches that page or page list live (the clock went back on a new connection). A read made while the watch is up is answered from the watch, at the time of its last answer, so none is made | a result of that subject whose server time reaches the answer's, or one that shows the written row | nothing: each round of the ladder passes without a read, and the user's retry asks the client to reconnect when the watch has answered since the last reconnect a retry asked for | no calls: the rounds pass on the ladder's timing, 2 s, 4 s apart | 3 rounds, then shown as could not resolve; a retry asks for one reconnect per answer of the watch | awaitingResult | 2 | 0 | the next change to the subject; the user's retry, whose reconnect makes the server answer every watch again at its current time; any other reconnect after which the watch gives no result in time; or the watch closing, after which the ladder reads it |
| The editor watches the page live, and the watch has given no result on this connection yet | the watch's first result | nothing until the bound, then the read the queue asked for | after 10 s without a first result, then as the read's own row | one wait of 10 s per watch and connection | saved | 2 | 0 | the watch's first result, which is taken as a read's would be; the page closing; or the bound passing, after which the page is read as before |
| A read is lost or times out, or the read to take up a strategy is refused for the sign-in or the build on a connection that has ended | an answer | that read | at once, then 2 s, 4 s, 8 s, 16 s, 32 s, 64 s, 128 s, 256 s, 512 s apart, then every 10 min; never twice within 2 s | 3 reads, then shown as could not resolve; the ladder goes on | awaitingResult | 15 | 6 | an answer, news about that subject: an edit on it rejected or failed (its page, or the page list for an edit of the strategy, a page or settings), a batch refused whole (the page list), the user pressing retry, a new connection, or a sign-in after a sign-out or to another account (a sign-in that only refreshes the same account on the same connection does not); each no sooner than the floor after the last read of the same subject |
| A read comes back in rows this build cannot read, or the store will not keep it | an answer this build can read and keep | that read | at once, then 2 s, 4 s, 8 s, 16 s, 32 s, 64 s, 128 s, 256 s, 512 s apart, then every 10 min; never twice within 2 s | 3 reads, then recorded as refused (unreadable work); the ladder goes on | unreadableWork | 15 | 6 | an answer, news about that subject: an edit on it rejected or failed (its page, or the page list for an edit of the strategy, a page or settings), a batch refused whole (the page list), the user pressing retry, a new connection, or a sign-in after a sign-out or to another account (a sign-in that only refreshes the same account on the same connection does not); each no sooner than the floor after the last read of the same subject |
| Landed work waits for a read that shows it | a read of the page or page list that holds it | that read | after 30 s without an edit, then every 5 min | 3 reads that show nothing new, then shown as could not resolve and read every 10 min | saved | 2 | 0 | a read that shows it, or an edit (which starts the quiet period again) |
| Edit access lost, and the page list says this account can view | a page list saying this account edits | the page list | at once, then every 10 min | 6 refusals while the strategy is not open in the editor, then none | editAccessLost | 7 | 0 | the user pressing retry or opening the strategy in the editor (six more refusals), a sign-in, or the app starting again. Being shared the strategy again shows only on a read, so it needs one of these. While the strategy is open in the editor the check never stops |
| Edit access lost, and the page list is refused as FORBIDDEN (a teammate not shared a replacement) | a page list this account may read | the page list | at once, then every 10 min | 6 refusals while the strategy is not open in the editor, then none | editAccessLost | 7 | 0 | the user pressing retry or opening the strategy in the editor (six more refusals), a sign-in, or the app starting again. Being shared the strategy again shows only on a read, so it needs one of these. While the strategy is open in the editor the check never stops |
| Taking up a strategy this account can only view | nothing: it is not added to the library | the page list, once | never | one read | nothing: not in the library | 1 | 0 | the user opening it again |
| Taking up a strategy the server no longer has | nothing: it is not added to the library | the page list, once | never | one read | nothing: not in the library | 1 | 0 | the user opening it again |
| The server refuses the sign-in (UNAUTHENTICATED or ACCOUNT_MISMATCH), on a send or on a read | the sign-in to change | nothing | never | no calls | what the waiting work showed before the refusal: sending for an unsent edit; in the read test, needsYou for a refused edit waiting for its page | 1 | 0 | a sign-in |
| The server asks for a newer build, on a send or on a read | a newer build | nothing | never | no calls | upgradeRequired | 1 | 0 | the app starting again on a newer build |
| The client does not say in time which connection it is on (the lookup throws or never answers) | a lookup that answers | a batch whose answer came back then is sent again; a read whose result came back then is read again; a session is not opened until a lookup answers | each lookup given up after 10 s; the batch again on the lost-send ladder, the read on the lost-read ladder, the session on the local-trouble ladder | 8 failures or refusals in a row, then the user is asked | sending while the batch is sent again; needsYou once the lost-send ladder asks the user | 8 | 0 | a lookup that answers, then the user asking to retry |
| The app has no connection | a connection | nothing | never | no calls | sending | 0 | 0 | the connection coming back |
| No one is signed in | a sign-in | nothing | never | no calls | sending | 0 | 0 | a sign-in |
| Sending is held by hand (the drive tool around a check, or at the end of its run) | the hold to be released | nothing | never | no calls | sending | 0 | 0 | the release |
| A batch gets no answer, or keeps being refused in a way the queue sends again (edit access the page list then confirms, or outside its window) | an answer that lands it | the same edits | the queue's backoff, doubling from 0.6 s; never twice within 0.18 s | 8 failures or refusals in a row, then the user is asked | needsYou | 8 | 0 | the user asking to retry |
| An unchecked batch reaches the server outside its window | the same edits, sent again with their checks | the same edits, checked | at once | one send again in checked form; a refusal after that climbs the lost-send ladder | saved | 3 | 0 | at once |
| A batch for this strategy went out moments ago | the send floor | nothing until the floor passes | one batch per 0.18 s per strategy | the floor. It only spaces batches that are ready at once; fresh edits already wait to settle, so a user dragging makes at most a batch a second, and a batch refused or lost again climbs the lost-send ladder | sending | 4 | 0 | the floor passing |
| The strategy was replaced | the user to discard what was set aside | nothing | never | no calls | strategyReplaced | 2 | 0 | the user discarding |
| The strategy was deleted on the server | the user | nothing | never | no calls | deletedOnServer | 1 | 0 | the user discarding |
| The server refused an edit | the user | nothing | never | no calls | needsYou | 1 | 0 | the user retrying, using the cloud version or discarding |
| This device cannot write the queue (the store, the session or the claim) | a write that succeeds | nothing: a result already read is kept and written again, not read again | the write again after 2 s, doubling to 1 min; 1 min while the store holds the strategy | none while the app runs | what the waiting work showed (in the test, needsYou: an edit the server refused, waiting for its page result) | 2 | 0 | a write that succeeds |
| The user is still editing | a pause in the edits | nothing | 0.18 s after the last edit, at most 1 s after the first | 1 s | sending | 2 | 0 | the pause |
| Nothing is queued and nothing is subscribed (send mode) | nothing: the store does not learn of teammates' edits. Saved here means your changes are on the server; whether you are seeing teammates' latest has no face in the store yet | nothing | never | no calls | saved | 0 | 0 | an edit, or a live result of the page list or the page the editor has open |

<!-- end of stall exits -->

**Which results a record takes.** A record takes results from one source,
fixed by the mode the app started in. In send mode that is this device's own
reads (`CloudResults.thisDevicesReads`, chosen when the sender starts), and
the editor's live watches of the open strategy's page list and open page,
whose answers the sender takes exactly as it takes a read's: newest only per
subject, and a one-shot read of a watched subject held while its watch has
given a result on the current connection (for a clock wait, until it ends;
otherwise for a short grace); in
shadow mode it is the editor's live queries (`CloudResults.liveQueries`, chosen
when the shadow starts). A result from the other source is not taken
(`NotThisModesResults`), so the two never mix in one record. Inside its mode a
result has the same rights wherever it comes from: it can adopt a later strategy
life and pay what is owed.

Every result has a start in the queue's (session, step) order, and no two
starts are equal. A read of this device asks the queue for its start before it
is made (`ReadBegun`, answered with `ReadStartIssued`); a live result takes the
next step when it arrives, so live results follow the order they arrive in. A
debt, an answer that lands and an adoption also move the order on. A result is
dropped, and changes nothing, freshness included, when:

- it started before the record last adopted a strategy life. Adoption fences the
  starts rather than clearing them, so nothing started before an adoption is
  taken after it, whichever way the life moved;
- it started before the result already taken for the same list or page;
- it started before the debt on its list or page;
- it is a page list showing the very life the server just refused.

Page-gone and strategy-gone answers obey the same rules as rows. Only a page
result started after this device's own answer landed can show that answered
item missing.

**After `STRATEGY_REPLACED`.** The refusal names the strategy's current life
([#772](https://github.com/SunkenInTime/icarus/issues/772)), and the list debt
keeps it (`ReadOwed.namedLife`, stored as `named`, kept when the list is later
refused). While it is set, a page list of the named life or a later one is
adopted, earlier or later than the record's own life, and the edits written in
the record's life are set aside; a list of any life before the named one is
dropped and the list stays owed. A later life is adopted because lives are
creation times and only grow: it is a replacement made after the refusal.

A refusal that names no life (a server from before #772) is an error answer,
stamped before the server's check, so on its own connection only content pays
it: a page list of a later life than the one the record holds. A later
connection or session pays it too, and then a page list of an earlier life than
the record's is dropped, except after a `STRATEGY_REPLACED` for the record's own
life, when it is adopted if it shows a different life (a list showing the very
life just refused is dropped).

Two limits, neither reached today:
- A delayed repeat of an earlier `STRATEGY_REPLACED` answer would overwrite a
  newer named life in the debt. The sender sends one batch at a time and holds
  sends while the list is owed, so nothing produces that order now.
- A build from before #772 cannot read an owed list that has the `named` key.
  The cloud store has not shipped, so only our own machines could hold one.

**An edit names its view.** `commitAs` and `commitAllAs` take `seen:`, the
`StrategyContent` or `PageContent` the edit was built from, and the life the
edit names comes from that same object. An edit seen in another life than the
record's, earlier or later, or seen in a read that names no life, is never
applied to the current rows: it is kept with the set-aside edits and refused to
the caller as `EditOfAReplacedStrategy`. The store cannot tell whether `seen` is
the read the edit was really built from; the editor, when it moves onto the
store, must make the edit and keep the read it came from together, so that a
caller cannot pair one read's edit with another read's `seen`. A page delete
records the page as the store holds it at commit, unless `pagesAsSeen` names
the page: then it records that `SeenPage`, which the editor builds with
`seenPageOf` and `contentSeenOf` from the rows it drew, or with
`ContentNeverRead` when it drew none. `pagesAsSeen` is part of `made:`.

**How an edit was made.** `commitAllAs` takes `made:`, a `HowMade`: `MadeLive`
names the queue session the editor read (`queue.session.number` of the
`CloudStrategy` in the read it drew) when it judged its page live, and
`MadeChecked` says it did not. Both may carry `drawnLives`, the life of each
row the batch names as the editor drew it. `MadeLive` of a session that has
since ended is made checked. Each op of the batch is judged against the held
rows (`atCommit`):

- A row whose life differs from the drawn one was replaced since the draw:
  the op is queued as `ChangedSinceDrawn(rowReplaced)` and not applied.
- A patch or reorder of a row drawn live that the store holds deleted is
  queued as `ChangedSinceDrawn(deleted)` and not applied. Keep mine takes a
  put-back: an add at the tombstone's revision with the user's payload.
- Made live, a merge is applied as the server applies a live send, its fields
  over the held row with no base check, and keeps its authored base. The
  send policy picks its form as for any edit.
- Made checked, a merge whose base the held row moved past is queued as
  `ChangedSinceDrawn(fieldConflict)` and not applied. Its entry never goes
  live.
- With no `made:` an edit commits as before: a base the held row moved past
  refuses the batch.

The rest of the batch commits; an edit held this way has no `Committed`, and
its page shows the held row until the user keeps theirs, uses the cloud's, or
discards it. A live entry draws without its base until a server refuses it.

**Where revisions still meet as numbers.** Every place two rows' versions are
ordered uses `Version`: the highest version shown, which of two shown rows is
newer, whether a result has shown landed work, the queue's known row for a
target, whether a list shows this device's landed page add, and the store's
and the shadow's choice of page for a row seen on two pages. What remains
compares revisions for equality inside one row's justification (a prediction
against the revision it was made at, a whole write behind this device's own
landed work, a put-back over its own delete) or does arithmetic on one row's
own revision (a folded prediction). Those choose which revision an op names;
the op still names the life it was written over, so a match across lives is
refused by the server as `row_replaced`, never applied. Local undo compares
revisions of local rows, which have no lives. A queued edit is drawn only over its own row's life, and only in
the strategy life it was written in. What the server does not refuse: a
re-add of a purged id goes through unless the put-back is checked. The cases
in `test/server_cases.json` pin this down; `test/server_cases_test.dart` runs
them against the stand-in server and `tool/server_cases/serverCases.test.ts`
against `convex/ops.ts`.

**Landed work.** An answered op is drawn on top of the latest results until
a result shows its row at the answered revision or later. The queue keeps
the highest revision any result has shown for each row, so a page trashed and
restored in between does not change when that happens. A row no result has
shown does not count, since a result older than the answer can lack a row
the answer just added. Landed work is drawn in the order the server applied
it: by the attempt that carried it and its place in that attempt. A landed
move is drawn off its source page and on its destination in every page view,
even when the source page's result has already removed the row, and asks for
the page its row comes from. A move records the row it acts on as the device
knew it (content and sort index), so the element is drawn on its destination
from the moment of the edit, before and after its answer, until a result of
the destination replaces it; a source result removes it from the source page
and nothing else. A queued edit of a row a teammate
moved is drawn wherever the row now is.
Field merges, page adds, page reorders and page deletes land as partial (the
server may have merged or renumbered rows the device has not seen);
everything else lands whole.

**Giving up.** When the user takes the cloud's version of an entry or
discards it, every later entry for the same row, page or strategy goes with
it, because it was built on the work given up.

**Dependencies.** An entry waits behind an earlier entry on the same row,
its page's add or delete, a page delete for work on that page, and page
changes against renumbering, until that one is answered. A refused
prerequisite keeps its dependants waiting, and the sync state says so. A page
copy reaches the queue as ordinary adds under ids derived on this device,
including an element this build cannot draw whose stored payload still reads
as a payload of a kind this build knows: its add carries that payload. Any
other row it cannot send stops the copy with a `CopyStopped`
(`CopyNeedsContent`, `CopySourceUnreadable`, `CopyHasUnreadableLineupGroup`,
`CopyHasNonObjectElement`, `CopyHasUnsendableElement`) and nothing is saved. A
result saying the strategy is gone stops every claim for that strategy.

**Folding.** One rule: a field edit folds into an earlier field edit of the
same row only when the earlier one has never been claimed (no attempt on
record, so not one given back or refused whole either), both name exactly
the same fields (and both carry a field base or neither does), both were
made the same way, the later one was not held at commit, and nothing
else for that row is queued between them. The folded edit keeps the earlier
one's place, base and what it was authored against, with the later one's
values. Nothing else folds. The fold is not exact in two corners, both pinned
in `test/cloud_fold_test.dart` against `applyOp`:

- The server already holds the first edit's value (another device set it).
  Sending both would be a no-op then an applied edit; the folded edit is a
  field conflict and is held for the user with both values kept.
- The server already holds the later edit's value where the first would
  conflict. Sending both would hold the first; the folded edit lands, and the
  server ends with the user's last value for every named field.

**Attempts are numbered by the queue.** A claim is attempt N, increasing and
stored; an answer counts only from an attempt that held the op, and an empty
claim is refused. A `CloudQueue` cannot be built with two entries under one id
or an attempt number that could be issued again. Op ids are minted by the
caller (UUID v4 in the app); the queue refuses an id it holds.

**What it rules out that today's queue does not.**

- [#631](https://github.com/SunkenInTime/icarus/issues/631): an undo after a
  lost answer never removes the op that may have landed; the op is resent
  under its own id and the undo waits behind it.
- [#645](https://github.com/SunkenInTime/icarus/issues/645): an op id the
  queue holds is refused.
- [#646](https://github.com/SunkenInTime/icarus/issues/646): Use cloud removes
  the refused op and the later entries for the same row, never others.
- [#668](https://github.com/SunkenInTime/icarus/issues/668): a delete and its
  undo never tell the user a teammate deleted the item when none did, and
  never silently overwrite one who did.

**Tests.** `test/cloud_queue_test.dart` pins the rules above, including three
sequences reproduced against the server model: an old add whose answer was
lost does not come back after a teammate deleted it and the server forgot
both; an old field merge does not overwrite a teammate who put the field
back; and a stale patch rejected first never lets the delete behind it go.
`doc/cloud_transitions.md` is generated by `test/cloud_transitions_test.dart`
and lists every state against every event. `test/cloud_permutation_test.dart`
delivers every order of a run's answers, transport failures, results, removals
and clock moves (results keep their arrival order within a session, as a
subscription delivers them) and requires one final queue and the same effects.
`test/cloud_model_test.dart` runs random interleavings with restarts, lost
and late answers, teammates and the 30-day jump against the server model,
derives the views afresh after every step and requires them to equal the
carried ones, and at the end requires the server to hold the user's edits.
`test/cloud_cost_test.dart` requires the same work for an edit, a claim, an
answer and a transport failure on queues of 100, 1,000 and 3,000 entries.

**The sync state** (`Tally`, `syncStateOf`, `accountSyncState`) is derived
from the entries, the standing and who owns the work, in one order with
ownership first, whether or not anything is waiting to be sent: held work
whose owner cannot be read (`ownerUnreadable`); anything while nobody is
signed in (`signedOut`); another account's strategy, held
(`heldForAnotherAccount`) or not (`notThisAccount`); and only then the
signed-in owner's own states, from deleted on the server down to waiting for a
result, offline among them. `AllSaved` is a promise made to the owner only:
an empty queue reads as all saved only to its owner and only in good
standing. Someone else's work cannot be sent even online, so ownership
outranks the connection. Waiting for a result counts as underway, not as
unsent. `accountSyncState` is `SignedInSync` (with `mine`, the signed-in
account's strategies only) or `SignedOutSync`; both list every other account
that holds work in `others` with its own tally, and keep held work whose owner
cannot be read apart in `ownerUnreadable`.

### Measuring it

`dart build cli -t bin/engine_costs.dart -o build/engine_costs` builds the
engine cost tool ahead of time, and `build/engine_costs/bundle/bin/engine_costs
<folder>` times, on the memory engine and on SQLite in `<folder>`: opening the
store and listing a 700-strategy library, opening a 20-page strategy, a cold
read of a 300-item page, saving a moved item and a 1000-point drawing, 200
moves awaited one by one and 200 issued at once, saving a one-page strategy
of 300 items, and one engine write of a single key. `tool/engine_costs_web.sh`
does the same for the memory engine and IndexedDB in headless Chrome,
compiled with `dart compile js -O4`, and `tool/firefox_page.sh
tool/engine_costs_web.dart` in Firefox. On IndexedDB it also reports the size
of the last commit's record after that 300-item save, and how long taking
the lease takes when the last commit was that save and when it was one
row.

`dart build cli -t bin/live_result_cost.dart -o build/live_result_cost` builds
the live result benchmark ahead of time, and
`build/live_result_cost/bundle/bin/live_result_cost` times, on SQLite, the
store taking one live page result in which one item moved, on a cloud
strategy with one page of 300 items (one in ten a 250-point freehand
drawing) and of 60: how long `record` takes, the longest stretch it holds
the main isolate, and how long it waits on the SQLite isolate. It then
feeds 200 such results at 20 a second, taking every one and then only the
newest while a `record` runs, and reports the longest stall, the backlog and
how long each result took to be stored. With `own` it times an own move from
commit to applied answer instead; with `takes`, results in which 1, 10 or all
300 items changed and 1 of 60, each without and with every take checked from
scratch, and the first result after the store reopens. The measuring code is
`lib/take_cost.dart`, which the driver's `pageTakeCost` step runs too. `dart
compile exe` leaves out SQLite's native library, so the store cannot open in
that build.

`dart run tool/store_benchmark.dart` times opening the store and a
700-strategy library list, opening a 300-item page where half the items are
1000-point drawings (in a strategy not yet read, and in one already read),
and two commits on that page; `growth` times adding, moving and removing
one strategy at library sizes from 100 to 2,800, one library edit at a
time. `test/store_budget_test.dart` counts what each
of those asks the engine to read, list and write, and how many keys each
listing returns, and fails when a count grows; it includes a strategy of 20
pages with 300 items each.
