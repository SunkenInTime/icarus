---
status: accepted
---

# One store on the device for every strategy

Icarus kept the library in two shapes. A local strategy was one Hive object
holding every page, written whole on each save. A cloud strategy was rows on
the server, with an outbox of ops, an offline copy and a live read stitched
together in memory. The editor chose between the two at 141 places in 34
files, about 13,000 lines existed only to bridge them, and the bugs that lost
work came from that bridge: a page switch that waited on the network, a
failed save treated as saved, an unreadable row inferred as a delete.

We decided to keep every strategy, local or cloud, in one store on the device,
in the server's row shape: strategy, page, page settings, element, lineup
group, folder. The editor reads and writes only that store. An edit is an op,
and it is saved the moment the store accepts it. For a cloud strategy the
store also holds the base, which is the rows as the server last confirmed
them, and the pending ops the server has not accepted yet. What the user sees
is the base with the pending ops applied. Sending ops and reading the
server's changes is a separate job that works on the store and never on the
editor. A local strategy is the same store with nothing to send, and moving
it to the cloud turns sending on.

The store lives in `packages/icarus_library`, a pure Dart package with no
Flutter, no Riverpod and no widgets. A package boundary holds where an import
rule did not: all 19 directories under `lib/` were in one import cycle.
Element and lineup payloads stay the canonical JSON that the server and .ica
files already hold, so the package needs no drawing types, and the app
decodes a payload into a typed item at the edge of the editor.

## What stays as it is

- The wire protocol and the server. The ops are the fourteen the server
  already takes, with the same op IDs, revisions and field merge.
- The outbox record on disk. Pending ops keep that format, so work queued by
  a shipped build is still sent after an update.
- .ica files and library backups.
- The Hive boxes shipped builds wrote. A migration copies them into the store
  and leaves them in place. While older desktop builds can still be installed
  over a newer one, the app keeps writing them, so a rollback opens the
  library as it was last saved.

## Rules the store keeps

- In a cloud strategy an edit is saved as its op before anything else is
  written: the pending op is the only saved form of the edit, the rows the
  user sees are worked out by applying pending ops to the base, and the base
  changes only when the server confirms. A local strategy has no pending op.
  The store applies the op in memory and sends the engine one commit holding
  every row in `OpApplied.writes` and the strategy's summary. The engine
  contract requires a commit to apply whole or not at all, across areas and
  across a crash, and a conformance suite checks every engine against it, so
  the disk holds the rows from before the edit or after it, never half.
- A save the engine cannot answer for is in doubt, and the store that made it
  is finished: it releases its lease and refuses every later call. The caller
  reopens and reads, and what is stored is what was saved. To keep the edit
  it issues the same op again, and `applyOp`'s own rules decide: an edit that
  had landed comes back as nothing to save or a typed refusal, and one that
  had not is applied.
- The first version saved a record of each edit in a journal area, wrote
  the rows, cleared the record, and replayed any record it found at open,
  because the storage it was built on wrote one key at a time. Once the
  engine contract required one commit across areas to apply whole, the
  record only repeated that promise, at four engine calls per save instead
  of one, with a replay at open, recovery markers that needed a clock to
  expire, and an open that failed on a record this build could not read.
  It was dropped for the single commit. A slot naming the last save attempt
  replaced it for a round and was dropped too: a lost attempt's number could
  be issued again and land, and a second writer between the doubt and the
  reopen breaks any single slot, so the slot could report a lost edit as
  applied. Issuing the op again answers the same question exactly.
- A row this build cannot read is carried untouched. It is never dropped,
  rewritten or inferred as deleted, whether it failed to decode or is a kind
  from a newer build, except when the user removes the strategy that holds
  it: that is the user's own action, and it takes every row of the
  strategy.
- The library list reads summaries, never page content. Opening a page reads
  that page's rows. Saving an edit writes the rows it changed.
- Sync status is derived from the store: a cloud strategy is synced when it
  has no pending op. A local strategy has nothing to send and no sync status.

## Coming back from an older build

A user can install an older build over a newer one, edit there, and update
again. The older build writes only the Hive boxes. The store remembers, for
each local strategy, the Hive record it last wrote or read. At startup:

- Hive record unchanged: nothing to do. If the store is ahead because a
  write to Hive was cut short, Hive is written again.
- Hive record changed and the store has nothing newer: the older build's
  edits are taken into the store.
- Both changed: neither is discarded. The store keeps its strategy, the Hive
  record comes in beside it as a copy, and the user is told which is which.

Cloud work an older build queued is in outbox records, whose format the
store shares, so it is sent as before.

## Considered options

- **A CRDT.** The server already keeps the latest value of each field of each
  item, which is the result a CRDT gives for a canvas of separate objects. An
  offline edit that collides with a teammate's waits for the user by design,
  and a CRDT would resolve it in silence. The server reads rows field by
  field to check access, validate payloads and track image references, which
  an opaque document would hide. It would also mean converting every
  production library while every shipped build still speaks the current
  protocol.
- **One in-memory page model over both storage systems.** It gives the open
  page one owner and leaves the 141 branch points, the offline copy and the
  move-to-cloud copy in place.
- **Hive for the store's rows.** This was the first choice, because Hive
  already shipped on every platform. A study of `hive_ce` 2.19.3 (#643) found
  it gives none of the guarantees the store needs: a desktop write is never
  synced to disk, compaction renames an unsynced file over the box, the web
  backend reports a write done before IndexedDB commits it, recovery
  truncates every frame after a damaged one, and a write of several keys is
  not all or nothing. Patching it would make us the maintainers of a storage
  format.
- **SQLite on the web, through WebAssembly.** It would give one engine
  everywhere, at the cost of a 750 KB `sqlite3.wasm` download and a file
  system emulated over IndexedDB or OPFS, which brings back the durability
  question one layer down. IndexedDB used directly already has what the store
  needs: one transaction per write, a `complete` event after the commit, and
  strict durability.
- **A storage format of our own.** Nothing measured below needs one.

## Where the store's rows live

SQLite on Windows, macOS and Linux, and IndexedDB used directly on the web.
Both sit behind the store's engine interface, and both pass its conformance
suite. The package README says how each keeps its promises and what each
test layer can and cannot show.

What decided it:

- **Faults survived.** On a SQLite file system that loses unsynced writes,
  tears them in 512-byte pieces and drops directory changes, a crash at every
  step of every op type leaves the rows from before the edit or after it, and
  no saved edit is lost. Turning `synchronous` down to `NORMAL` loses 48 saved
  edits in the same tests, which is how we know the tests can see the
  difference. A writer process killed at 24 random points lost nothing.
  IndexedDB in Chrome survives aborted transactions and a quota error the same
  way. The tests found two engine bugs, both fixed: a commit that failed after
  its log frames were written came back on the next open, and SQLite's quick
  check let a damaged file open with strategies missing.
- **Costs**, on release builds (`bin/engine_costs.dart` ahead of time, and
  `dart compile js -O4` in headless Chrome 157), a 500-strategy library of
  85 MiB, medians of three runs of 15 or 60 on a Ryzen 7 5700U with a
  Kingston NVMe drive, under load from other agents (load average 4 to 12):

  | | Memory (floor) | SQLite, XFS | SQLite, ext4 | Memory in Chrome | IndexedDB, Chrome |
  | --- | --- | --- | --- | --- | --- |
  | Cold start, list 500 strategies | 4.9 ms | 29.5 ms | 34.5 ms | 9.4 ms | 117 ms |
  | Open a 300-item page | 153 ms | 163 ms | 187 ms | 173 ms | 214 ms |
  | Save one moved item | 0.1 ms | 21.1 ms | 6.6 ms | 0.3 ms | 8.7 ms |
  | Save a 1000-point drawing | 9.3 ms | 32.3 ms | 19.7 ms | 8.7 ms | 17.9 ms |

  Opening a page costs the same on every engine because decoding 150
  drawings dominates it. A save is the store's four engine calls (the saved
  record, two areas of rows, clearing the record), each one synced
  transaction; on SQLite the time is the syncs. Saves happen behind the
  canvas, so none of this delays an edit on screen. The ext4 numbers are one
  run; macOS, where `fullfsync` makes each sync slower, is not measured.
- **Size.** On Linux the release bundle grows by 1,801,745 bytes, the SQLite
  library itself, and the engine's Dart code adds 98,304 bytes to `libapp.so`
  once the app uses it. The Windows library is 1,709,056 bytes, and macOS
  ships the arm64 and x64 libraries (1,713,824 and 1,718,616 bytes). On the
  web the engine adds 6,133 bytes of JavaScript (1,920 gzipped) and no
  download.

## Consequences

The store changes how a local library is saved, which every earlier rule
treated as fixed. It ships behind a switch that is off by default. Turning it
on is its own change, reviewed on its own, after the store has opened real
libraries from past releases and produced the same pages the old code does.
