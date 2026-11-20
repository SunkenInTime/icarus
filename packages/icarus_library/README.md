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
  `TrashedPage`; an element is a `LiveElement`, a `DeletedElement` or an
  `UnreadableElement`; a lineup group is a `LiveLineupGroup` or a
  `DeletedLineupGroup`.
- **Payloads**: an element or lineup group payload stays canonical JSON
  (`{kind, payloadVersion, data}`). The app turns it into a drawn item at the
  edge of the editor.
- **Ops**: the fourteen the server takes, as the sealed `StrategyOp`, sent
  exactly as the app sends them today (`toJson`).
- **`applyOp`**: given a strategy's rows and an op, the rows the server would
  hold after accepting it, the op that undoes it, and which rows and fields
  changed.

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
  decoder decides what it can draw. It is saved back byte for
  byte. Every op aimed at it is refused with `UnreadableTarget`, including a
  delete; deleting its page keeps it, as it keeps every row on the page.
- **Applying an op predicts the server.** The meaning comes from
  `convex/ops.ts` and `convex/lib/fieldMerge.ts`: a patch with a `merge`
  writes only the named fields onto the row as it is now; a delete leaves a
  tombstone, and a deleted page keeps its content and its place; each
  accepted write raises that row's revision by one.
- **Applying an op twice gives the rows that applying it once gave.** The
  second time it is `OpUnchanged`. This is what lets the store save an edit
  as its op before anything else and apply it again after a crash.
- **An undo names only what the op changed.** Undoing an edit to an agent's
  position writes the position back and leaves a teammate's change to its
  side alone.

## Where it differs from the server on purpose

- An op aimed at an `UnreadableElement` is refused here. The server would
  accept it, since it reads every kind.
- A page added as a copy gets ids for its copied rows from `newId`. The
  server picks its own random ids, so the copies match in content but not in
  id.
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
- Undo of an edit that first set a later field (`caption`, `wallPath`) does
  not remove it: the server keeps a later field a write leaves out, and
  clearing one means writing its empty value, which only the app knows.
- Each op is applied alone. The server also lets several page ops queued from
  the same strategy revision land in one batch; that belongs to whoever sends
  batches.
