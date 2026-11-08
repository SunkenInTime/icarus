# Convex cost budgets

What the common cloud flows cost on a real Convex backend, checked against
`budgets.json`. CI runs it as the `cost` lane, so a change that makes a flow
read far more, re-run far more live queries, or lose write conflicts fails
its PR instead of showing up on the bill.

```sh
node tool/convex_cost/run.mjs            # check against budgets.json (about 40 s)
node tool/convex_cost/run.mjs --update   # write today's numbers as the new budgets
node tool/convex_cost/run.mjs --only move,agentDrag
node tool/convex_cost/run.mjs --project <another checkout>   # deploy its convex/ instead
```

`npm ci` first. The first run downloads the backend (about 60 MB) into the
Convex CLI's cache (`%LOCALAPPDATA%\convex\binaries` or
`~/.cache/convex/binaries`), where `npx convex dev --local` keeps it too.

## How it measures

The run starts the open-source Convex backend on port 3310 with an empty
database, deploys `convex/` to it, and seeds a library: 150 strategies (50 at
the top level, 25 in each of four folders) and one strategy to edit, with a
page of 60 items and one of 20. Payloads have the shape the desktop app
writes, from a seeded generator, so every run writes rows of the same sizes
and the numbers repeat to the byte.

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
left out.

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

## When a budget fails

The message names the flow and the number, against the budget and today's
value. Look at the per-function table above it for the function that grew.
If the cost is what the change is for (a flow that now does more on
purpose), run `--update` and say in the PR why the flow costs more.

Budgets sit a little above today's numbers: a quarter more for bytes (row
sizes drift with harmless additions), a fifth or at least two more for
re-run counts in the move, none for single re-runs and write conflicts.

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
