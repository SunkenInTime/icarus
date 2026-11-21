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
- Work a shipped build queued. Its outbox records stay where they are and are
  still sent after an update, until the migration moves that strategy's work
  into the store's queue.
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
  the disk holds the rows from before the edit or after it, never half. The
  IndexedDB engine cannot keep that promise in two cases the browser causes
  (a quota abort in Firefox, and an abort that itself fails); there a commit
  can be partly applied and is reported as in doubt.
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

Cloud work an older build queued is in outbox records. The store's queue
keeps its own rows in a different format (one row per entry, attempt and
evidence group), so the migration moves a strategy's outbox into it; until
then that work is sent as before.

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
  not all or nothing. The last one decides it: the store saves an edit as
  one commit across areas and relies on the engine to apply it whole or not
  at all. Patching Hive would make us the maintainers of a storage format.
- **SQLite on the desktop and IndexedDB on the web, chosen.** Each keeps all
  of the library in one table or object store keyed by area and key, so one
  database transaction holds every change an edit makes, in any number of
  areas. That transaction is what makes a save all or nothing (with the two
  IndexedDB exceptions above), and its
  commit is what a save waits for, usually one sync: SQLite in write-ahead
  log mode with `synchronous = FULL`, IndexedDB with `durability: 'strict'`.
  What strict buys differs by browser and has not been checked by cutting
  power; the package README says what each attempts. Single
  ownership comes from the same place: SQLite's exclusive file lock, and a
  Web Lock per origin.
- **SQLite on the web, through WebAssembly.** It would give one engine
  everywhere, at the cost of a 750 KB `sqlite3.wasm` download and a file
  system emulated over IndexedDB or OPFS, which brings back the durability
  question one layer down. IndexedDB used directly already has what the store
  needs: one transaction for a whole commit, a `complete` event after it is
  stored, and strict durability.
- **A storage format of our own.** Nothing measured below needs one.

## Where the store's rows live

SQLite on Windows, macOS and Linux, and IndexedDB used directly on the web.
Both sit behind the store's engine interface, and both pass its conformance
suite. The package README says how each keeps its promises and what each
test layer can and cannot show.

What decided it:

- **Faults survived.** On a SQLite file system written for the tests, which
  loses unsynced writes, tears them in 512-byte pieces and drops directory
  changes, a crash at every step of every op type leaves the rows from before
  the edit or after it, and no saved edit is lost. Power loss on a real drive
  is not tested. Turning `synchronous` down to `NORMAL` loses 48 saved
  edits in the same tests, which is how we know the tests can see the
  difference. A writer process killed at 24 random points lost nothing.
  IndexedDB in Chrome and Firefox survives the aborts the tests start the
  same way, with one exception: Firefox can keep part of a transaction that
  aborted on quota ([bug 2080749](https://bugzilla.mozilla.org/show_bug.cgi?id=2080749),
  reproduced through the engine in 5 runs out of 5). So the web engine checks
  the room the browser reports before each commit and refuses one that would
  not fit, with nothing written, and a quota abort that still happens is a
  save in doubt, not a refused one. On this engine a commit can be partly
  applied in two cases: that quota abort, and an abort that itself fails
  after the browser has taken part of the commit. That is accepted on two
  conditions: the web build is cloud only, and the cloud store's commits are
  required to be safe when any subset of their row changes is applied
  ([#667](https://github.com/SunkenInTime/icarus/pull/667)). A local library
  on the web would need the engine to keep before-images first. A stop or a
  failed sync at any point of creating a desktop library can leave a file
  without its tables, and the next open creates the library in it. A file
  that is not provably uncreated, or that has a log or a journal holding
  pages beside an empty or missing library file, is refused untouched. The tests found engine bugs, all
  fixed: a commit that failed after its log frames were written came back on
  the next open, SQLite's quick check let a damaged file open with strategies
  missing, and two processes creating a library at once could rename an
  empty file into place (the library is now created in place, inside one
  SQLite transaction).
- **Costs**, measured through the store on release builds
  (`bin/engine_costs.dart` ahead of time, and `dart compile js -O4` in
  headless Chrome 157). The library holds 700 strategies (60 MiB on disk),
  one of them with 20 pages of 300 items whose first page is half 1000-point
  drawings. Figures are medians of three runs (each of 15 opens, 60 saves or
  200 moves) on a Ryzen 7 5700U with a Kingston NVMe drive, with other agents
  using it (load average 3 to 13); the ext4 column is one run:

  | | Memory (floor) | SQLite, XFS | SQLite, ext4 | Memory in Chrome | IndexedDB, Chrome |
  | --- | --- | --- | --- | --- | --- |
  | Cold start, list 700 strategies | 10.6 ms | 46.9 ms | 45.1 ms | 27.1 ms | 36.9 ms |
  | Open the 20-page strategy | 14.8 ms | 14.4 ms | 14.0 ms | 16.1 ms | 52.7 ms |
  | Cold read of a 300-item page | 168 ms | 179 ms | 169 ms | 193 ms | 245 ms |
  | Save one moved item: p50 / p95 | 0.36 / 0.39 ms | 6.4 / 8.1 ms | 2.2 / 3.3 ms | 1.2 / 2.5 ms | 3.8 / 9.4 ms |
  | Save one 1000-point drawing | 10.6 ms | 18.2 ms | 13.6 ms | 19.8 ms | 20.6 ms |
  | 200 moves, each awaited: p50 / p95 | 0.34 / 0.35 ms | 5.8 / 7.4 ms | 2.0 / 3.8 ms | 1.2 / 2.8 ms | 3.6 / 4.7 ms |
  | 200 moves issued at once, all saved after | 68 ms | 1.18 s | 0.46 s | 233 ms | 0.85 s |
  | Remove the 20-page, 6,000-item strategy | 12.5 ms | 43.5 ms | 31.7 ms | 23.1 ms | 142 ms |
  | List the 700 strategy areas (`areas`) | 0.18 ms | 1.05 ms | 1.28 ms | 0.4 ms | 105 ms |

  A save is one commit, usually one sync, so it costs one synced transaction, and
  saves issued faster than that queue behind each other, about 170 a second
  on the loaded XFS disk. A page read costs about the same on every engine,
  because the engine's part of it is small: reading the page's 300 rows is
  2.3 ms on SQLite and 44 ms on IndexedDB, and the rest is decoding them.
  When these figures were taken, copying the decoded values into
  unmodifiable ones was the largest part of that under JavaScript (164 to
  271 ms timed on its own, against 22 to 27 ms for `jsonDecode`); on the VM
  `jsonDecode` was (110 ms against 46 ms). The store now hands decoded rows on
  as read-only views instead of copying them (#665), so the cold-read row
  above predates that change and was not measured again here.
  Listing areas on IndexedDB walks a cursor one event per area, which is why
  it costs 105 ms; the store calls it once after open. macOS, where
  `fullfsync` makes each sync slower, is not measured.
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

A library records two format numbers: the engine's layout (SQLite's
`user_version`, IndexedDB's database version), written when the engine
creates the storage, and the store's row layout (the `format` row in the
`library` area), written with the first save into a library that lacks it.
That row is also how the store knows a library is new: a library with no
`format` row and no row in any area is created, whatever the engine did
before. Opening never commits: it decides and reports, and the marker rides
along with the first save. Both numbers start at 1. A build that finds a
higher number refuses to open the library; it writes no row and makes no
commit, though SQLite may still recover a journal or fold its log into the
file. The package README gives the rule for when each number changes, and
the full set of states a library can be in, with what is certain in each and
what the app can say.
