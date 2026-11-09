# Save-path gauntlet

A user edits cloud strategies in the app while the network fails under it.
Every edit goes through the app's own save path: the op queue
(`strategyOpQueueProvider`), its Hive outbox, `ConvexStrategyRepository` and
the native Convex client, against a throwaway local deployment. The faults
sit below that path, where real ones happen:

- `FaultyTransport`, under the repository: an `ops:applyBatch` whose answer
  is lost after the server applied it, one lost before it arrives, one
  delivered twice, one delayed, one held while the token goes bad, and one
  whose answer never comes because the process dies.
- `SocketProxy`, under the native client: the network goes away and comes
  back.
- The native client reconnects, and is handed a token the server refuses,
  then a fresh one.
- A teammate (the same account on another device, over Convex's HTTP API)
  edits a field of items the user is moving, and deletes one the user is
  still editing.
- The process ends with a batch in flight and edits queued behind it. The
  next process opens the same Hive directory, as the app does on launch.

## What it checks

At the end of every round, offline, after the refusal and at the end of
each seed, it reads the sync chip's status (`cloudSyncStatusProvider`), the
save state, the outbox as the Hive box holds it, and then the server:

- The chip says synced only when the outbox is empty and the server holds
  everything the user drew.
- Otherwise every edit the server does not hold is in the queue state the
  chip reads, and each one is in the outbox on disk.
- The save state never says everything is saved while the outbox holds
  work.
- The server applied each op once, across resends and the restart.
- Each seed ends synced, holding the user's last edit to every item, page
  and setting, with the teammate's field kept wherever the user did not
  change it.

## What stands in for the rest of the app

- Sign-in. `GauntletAuth` reports the account signed in and ready, and the
  gauntlet gives the native client minted tokens itself, where the app
  would get them from Supabase.
- The canvas and live sync. `Editor` makes each edit an op as live sync
  does (an add, a delete, or a patch merged by field against the version it
  knows), and learns versions from the queue's answers and from the server
  when the strategy opens. It has no live read, so it never edits an item
  in the window where only that read would keep the op right: it brings an
  item back only after its delete has landed.

## Bugs it found that it steps around

Both start with a lost answer, after which the queue cannot tell its own
landed change from a teammate's. They are left for changes of their own, and
the gauntlet avoids them so the lane passes until then:

- An edit made while a failed batch waits to be resent is folded into the
  failed op under a new op id. When the lost answer was an accept, the
  server refuses the fold as a conflict with this device's own write. The
  gauntlet edits nothing until a lost batch has been resent.
- When the network drops while a page change is being sent, its resend is
  answered as a replay, which does not move other waiting strategy changes
  onto the revision it made. A strategy rename made offline is then refused
  as a conflict. The gauntlet cuts the network only when nothing is being
  sent.

## Run it

From the repository root, after `npm ci`, `flutter pub get` and a release
build of the native bridge:

```sh
cargo build --release --manifest-path third_party/convex_flutter/rust/Cargo.toml
node tool/convex_client_gauntlet/runtime/tool/run_with_local_deployment.mjs
```

The script starts a local deployment from a copy of `convex/` that trusts a
key made for the run, mints the tokens, runs `save_path_gauntlet_test.dart`,
and runs it again after its checkpoint. `GAUNTLET_SEEDS` (default 3: seed 0
refreshes the token, seed 1 restarts the process), `GAUNTLET_PORT`,
`GAUNTLET_REPORT` and `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` change
the run; the script's header lists them. CI runs it in the `gauntlet` lane.
