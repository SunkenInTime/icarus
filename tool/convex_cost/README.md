# Convex cost budgets

What the common cloud flows cost on a real Convex backend, checked against
`budgets.json`. CI runs it as the `cost` lane, so a change that makes a flow
read far more, re-run far more live queries, or lose write conflicts fails
its PR instead of showing up on the bill.

```sh
node tool/convex_cost/run.mjs            # check against budgets.json (about 3 minutes)
node tool/convex_cost/run.mjs --update   # write today's numbers as the new budgets
node tool/convex_cost/run.mjs --only move,agentDrag
node tool/convex_cost/run.mjs --project <another checkout>   # deploy its convex/ instead
```

`npm ci` first. The first run downloads the backend (about 60 MB) into the
Convex CLI's cache (`%LOCALAPPDATA%\convex\binaries` or
`~/.cache/convex/binaries`), where `npx convex dev --local` keeps it too.

## How it measures

The flows are modelled sequences of requests. They measure what the server charges for that sequence, and cannot see a change in how many calls the Dart code makes for the same edits: a scenario sends what it is written to send. The store's sender's call counts are guarded by the Dart tests that count them (`test/library_store/cloud_sender_test.dart`).

The run starts the open-source Convex backend on port 3310 with an empty
database, deploys `convex/` to it, and seeds two libraries at once. The first,
for the first four flows: 150 strategies (50 at the top level, 25 in each of
four folders) and one strategy to edit, with a page of 60 items and one of 20.
The second, for the everyday flows (`lib/sessions.mjs`), belongs to a coach:
150 strategies in 20 folders (five folders of three subfolders each), a
typical strategy and a session strategy of 4 pages and 60 items a page, a
large one of 20 pages and 300 items a page (one in ten a 250-point freehand
drawing), and a sketch page holding a 2,000-point drawing. A teammate owns 15
more, shares a folder and three strategies with the coach, and edits the
session strategy through a share. Payloads have the shape the desktop app
writes, from seeded generators, so every run writes rows of the same sizes and
the numbers repeat to the byte.

The deployed copy leaves out `convex/crons.ts`. With it, the
fold-content-changes job folds content-change rows on the backend's own clock,
and every read of a content version (getFullSnapshot, listContentVersions)
then varies by a few hundred bytes from run to run. Instead the run folds the
coach library's seed changes itself once they are a minute old, while the
first four flows run, so its strategies start out folded as they are in
production. `idleHour` runs each job directly. Both need a backend the run
started (they refuse `--url`), because they run maintenance jobs until those
have nothing left to do.

The run sets `PRESENCE_URL` and `PRESENCE_PASS_SECRET` on its backend, so
`presence:issueRoomPass` signs and returns a real pass. Calls send the element
field level the client sends (`currentElementFieldLevel` in
`lib/collab/collab_models.dart`). A flow that hasn't finished in five minutes,
or a page watch that gets no answer in a minute, fails the run instead of
hanging it.

Each flow runs over websocket clients acting as a signed-in user (the admin
key with an identity), with the live queries the app holds subscribed. The
backend's function log stream (`/api/stream_function_logs`, what the
dashboard and `npx convex logs --jsonl` read) reports every execution with
its `usageStats` (bytes and documents read and written), whether a query was
answered from the cache, and whether a mutation lost a write conflict and
was retried (`occInfo`). A flow's cost is every execution between two marker
calls: the mutations it sends, the queries it asks, and the live-query
re-runs those writes cause. A Convex client resolves a mutation only once its
live queries reflect it, so those re-runs finish inside the window. Crons are
left out. Where a second device is watching, the flow waits until that
device's page shows the edit.

The backend can answer a live query over the websocket a moment before it
writes that execution to the log, while the HTTP marker is logged as it
answers. So before each marker the run waits until no entry has arrived for
150 ms, leaving out the backend's own jobs. Without that wait, a live query
answered just before the window was sometimes logged after the start marker
and counted inside it, and one answered at its end was sometimes logged after
the end marker and left out
([#825](https://github.com/SunkenInTime/icarus/issues/825)).

The everyday flows also count the bytes each call's arguments take as JSON
(what the client uploads, without the websocket envelope) and the bytes each
function returned (`returnBytes` in the log: what a client downloads).

convex-test (`npm run test:convex`) runs the same functions but has no live
queries and doesn't count reads as the backend bills them, so it can't stand
in here.

## The flows

| Flow | What it does | Budgets |
|---|---|---|
| `move` | Moves 20 strategies (3 pages, 75 items each) into the library, half at the top level and half into a folder, with the folder tree and the top-level list live. Each move is the app's sequence: createWithInitialPage, getShell, pages:add twice, applyBatch twice, getFullSnapshot, finishMove. | list re-runs, bytes they read, bytes read in all |
| `agentDrag` | One element.patch of an agent's position on the 60-item page, watched in slices, with the library lists live behind the editor. | bytes applyBatch read and wrote, live-query re-runs, bytes read in all |
| `sliceEdit` | One item moved on the page the editor watches as page:getFrame plus four page:getElementSlice ranges. | page-part re-runs, bytes they read, other re-runs |
| `concurrentEdits` | Two devices each send 10 one-drag batches to the same strategy at once. | write-conflict retries (must stay 0) |
| `libraryOpen` | My Library (folder tree, top-level list, the user's Community posts and copies), then Shared. | the everyday set (below) |
| `launchUnchanged` | Desktop connects and checks its copy of 162 strategies by content version; nothing changed. The copy's versions are taken first, and only strategies whose header or version differ are read whole, as `_changedOf` decides. | the everyday set |
| `launchOneChanged` | The same with one 4-page strategy changed, which is then read whole. | the everyday set |
| `launchWeekly` | The same once every copy is a week old: every strategy read whole. | the everyday set |
| `openTypical`, `openLarge` | A cold open on desktop, copy read included. | the everyday set |
| `pageListTypical`, `pageListLarge` | One `strategy:getPageList` of the 4-page and the 20-page strategy after a change, with `strategy:getShell` on the same strategy as a note. No shipped client calls it yet. | the everyday set |
| `pageSwitchNew`, `pageSwitchBack` | Switching to a page not read yet, and back to one just read. | the everyday set |
| `reopenDesktop`, `reopenWeb` | Opening an unchanged strategy again, within seconds. | the everyday set |
| `soloSession` | 50 single moves with the editor's and library's live queries held. | the everyday set, library list re-runs |
| `drawingMove` | Moving a 2,000-point freehand drawing. | the everyday set |
| `twoPeople` | 20 moves by the owner, counting what the teammate's live queries re-run. | the everyday set |
| `editorIdleHour` | An open editor for an hour: 60 room-pass renewals. | calls, bytes read, written and sent an hour, re-runs |
| `idleHour` | Every scheduled job for an hour with nothing to do. | calls, bytes read and written an hour |

The everyday set is function calls (cached query answers included: the
backend logs and bills each as a call), bytes read, bytes written, bytes the
client sent, bytes the functions returned, and query re-runs (query
executions the flow didn't ask for).

## What the numbers are on the bill

Convex bills function calls, database I/O (bytes read and written), action
compute in GB-hours, database storage, file storage and data egress
(https://docs.convex.dev/production/state/limits).

- **Function calls** are every execution in the window, cached ones included.
  In the backend's usage tracking (`crates/usage_tracking`) a cached query is
  still a `FunctionCall` with `calls: 1`, tagged `cached_query`.
- **Database I/O** is `databaseReadBytes` and `databaseWriteBytes` from each
  execution's `usageStats`. The log's `databaseIoReadBytes` and
  `databaseIoWriteBytes` equal them in every flow here. A cached answer reads
  nothing.
- **Action compute** is the only billed dimension these flows barely touch:
  one scheduled action (sweep-deleted-image-assets). `idleHour` prints its
  memory times run time but sets no budget, since run time follows the
  machine.
- **Storage, file storage and data egress** are not measured. The log
  stream doesn't report storage, and no flow serves a file.
- **Bytes the client sent** and **bytes returned** are not billed, and are
  not bytes on the wire either: the first is the JSON of each call's
  arguments, the second the size of each returned value as the backend
  measures it, cached answers included and before compression. They show
  what a user on a slow connection waits for.

## When a budget fails

The message names the flow and the number, against the budget and today's
value. Look at the per-function table above it for the function that grew.
If the cost is what the change is for (a flow that now does more on
purpose), run `--update` and say in the PR why the flow costs more.

Budgets sit a little above today's numbers: a quarter more for bytes (row
sizes drift with harmless additions), and a fifth or at least two more for
call counts and the move flows' list re-runs. Single re-runs, write
conflicts and the everyday flows' query re-runs get no headroom. A flow's
query re-runs are what its own writes make the live queries do, so the count
is exact: a flow that has none fails on its first, and one that has some
says why in its description.

The numbers belong to the backend release in `BACKEND_RELEASE`
(`lib/backend.mjs`). Moving it means checking the numbers again.

## Checked against

- **Convex cloud.** On Nov 8 2026 the same run against a cloud dev
  deployment matched the local backend exactly: every function's runs,
  cached runs, bytes and documents read and written, and conflict retries.
- **The incident it guards.** The move run against the checkout just before
  #388 (5aca5916) made 120 list re-runs reading 9.5 MB and failed all three
  move budgets; against #388 itself (39e16bbd) it made 20 re-runs reading
  1.1 MB and passed.
- **Write conflicts.** With a write to the strategy row added to applyBatch
  (a shared row every batch writes, like the counter row of Oct 22), the
  concurrent run logged 4 conflict retries and failed.
