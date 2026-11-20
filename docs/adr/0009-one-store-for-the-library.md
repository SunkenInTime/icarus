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

- A row this build cannot read is carried untouched. It is never dropped,
  rewritten or inferred as deleted, whether it failed to decode or is a kind
  from a newer build.
- The library list reads summaries, never page content. Opening a page reads
  that page's rows. Saving an edit writes the rows it changed.
- Sync status is derived from the store: synced means no pending op remains.

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
- **SQLite.** Better transactions and queries, at the cost of a new native
  dependency on three desktop platforms and WebAssembly on the web. Access
  here is by key, per strategy and page, and ops are idempotent, so the store
  does not need a transaction across keys. Hive already ships on every
  platform and holds the outbox.

## Consequences

The store changes how a local library is saved, which every earlier rule
treated as fixed. It ships behind a switch that is off by default. Turning it
on is its own change, reviewed on its own, after the store has opened real
libraries from past releases and produced the same pages the old code does.
