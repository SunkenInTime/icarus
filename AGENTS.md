i(Dara,me) want to write this to you(agent). Icarus is mine, and we take care of it together. This branch is where Icarus learns to live online.

Icarus is a Valorant strategy and lineup tool: a desktop Flutter app where players, igl's, and coaches draw plans on maps, place agents and abilities, and build a library of their tactical work. The shipped version keeps everything on the user's machine. This branch adds the cloud: accounts, a Convex backend, sync, and shared strategies. None of it is public yet. The goal of this branch is shape, we are finding the right shape for these features, and when it's right it ships.

Quick glossary of relevant parties in this document:

you - the agent reading this document and working on Icarus directly.
me/we/us - the humans contributing to Icarus. This is the party talking to you as we build. On this branch we are also the only accounts on the server.
users - Valorant players and coaches. They are not developers. They will never read an error log, they will only feel whether the app worked.

And the words we use when we work:

simple - how cleanly the logic breaks down. each step follows from the last, no step doing two jobs.
obvious - the next reader never asks "why is this here?". measured by the reader. not always simple; sometimes obvious has more parts.
the library - a user's saved strategies, folders, and lineups. in local mode it lives only on their machine; in cloud mode a copy lives on the server. both copies are the user's work.
round-trip - export then import with nothing lost.
local mode - the shipped behavior: signed out, library on disk, exactly what main's users have today.
cloud mode - signed in, library synced to Convex.
op - one queued change to cloud data. an op lands when the server accepts it.

The domain vocabulary (strategy, page, lineup, .ica file, and friends) lives in CONTEXT.md, use those words exactly. DESIGN.md defines how the app must look and how we build UI, read it before touching UI. PRODUCT.md holds who this is for and how it must feel.

Here's the philosophy we work by:

## The library is sacred
Corrupted or dropped library data is unrecoverable. In local mode nothing here changes: a change to the Hive models means source models, generated adapters, and a migration (`lib/migrations/`) so that data written by any past version loads in this one. In cloud mode the op queue holds work the user believes is saved. Every op either lands or the user is told, on screen, before they walk away. When a write path is uncertain, fail loudly without saving rather than save something wrong.

## Sync status is a promise
The chip that says synced is the app promising the work is on the server. A conflict resolved in silence makes the app lie. So does an op dropped after retries, and so do offline edits with no badge. A user who catches the app lying once stops trusting it with their library. Every state the user's work can be in has a face on screen, and when the true state is uncertain, show uncertainty.

## The server is still clay
No user data lives on the Convex deployment, only ours. So reshape freely: when a schema change would want a server-side migration, wipe the deployment and rebuild it in the new shape instead. Clay hardens the day this ships, which is exactly why we reshape now while it's cheap. This freedom covers server data only; the local library and round-trip keep every guarantee above.

## Everything exported must come home
Every .ica file and library backup from every version we ever shipped must round-trip. When you change what a strategy contains, export and import change with it in the same commit.

## The server is reading it now
On main we build the data layer as if a server were already reading it. Here one is. `convex/` reads every byte the client writes and has never seen our widgets, and that stays true: payloads carry a payloadVersion, rows carry a revision, JSON is canonical, and nothing under `lib/collab/` or `convex/` imports UI.

## The user is mid-thought
People use Icarus while their tactical idea is still hot, the interface must never make them wait or wonder. The network is never in that loop. Edits hit the canvas immediately and the queue catches up behind them. When a feature works but feels wrong, it is not done.

## Fight for the obvious solution
Measure twice, cut once: understand the problem fully before building, because cleverness is what gets written when you haven't. The biggest simplicity win is refusing to solve problems we don't have. Good code is the most simple thing that delivers full functionality, nothing traded away, nothing bolted on. Push back when you see a more obvious way.

## Some general rules
These steer us in the right direction. They are not hard-set, but default to following them; if you think one should be ignored, be very loud about it and get approval from us first.

- Never edit generated files (`*.g.dart`, `convex/_generated/`). Edit the source models or schema, then regenerate (`dart run build_runner build --delete-conflicting-outputs`; Convex regenerates via `npx convex dev`).
- Convex behavior is defined by the current schema, source, generated types, and tests in this repository. If an API detail is uncertain, check the current official Convex documentation before editing, then prove the change with `npx tsc --noEmit` and `npm run test:convex`.
- Keep agent instructions in this `AGENTS.md`. Do not add generated agent guidance, bundled skills, or compatibility copies for specific coding agents back to the repository.
