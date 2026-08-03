i(Dara,me) want to write this to you(agent). Icarus is mine, and we take care of it together.

Icarus is a Valorant strategy and lineup tool: a desktop Flutter app where players, igl's, and coaches draw plans on maps, place agents and abilities, and build a library of their tactical work. It ships as an installer with an auto-updater and has over a thousand users.

Quick glossary of relevant parties in this document:

you - the agent reading this document and working on Icarus directly.
me/we/us - the humans contributing to Icarus. This is the party talking to you as we build.
users - Valorant players and coaches. They are not developers. They will never read an error log, they will only feel whether the app worked.

And the words we use when we work:

simple - how cleanly the logic breaks down. each step follows from the last, no step doing two jobs.
obvious - the next reader never asks "why is this here?". measured by the reader. not always simple; sometimes obvious has more parts.
the library - a user's saved strategies, folders, and lineups. stored only on their machine, no copy exists anywhere else.
round-trip - export then import with nothing lost.

The domain vocabulary (strategy, page, lineup, .ica file, and friends) lives in CONTEXT.md, use those words exactly. DESIGN.md defines how the app must look and how we build UI, read it before touching UI.

Here's the philosophy we work by:

## The library is sacred
Corrupted or dropped library data is unrecoverable. Schema changes are the dangerous moment: a change to the Hive models means source models, generated adapters, and a migration (`lib/migrations/`) so that data written by any past version loads in this one. When a write path is uncertain, fail loudly without saving rather than save something wrong.

## Everything exported must come home
Every .ica file and library backup from every version we ever shipped must round-trip. When you change what a strategy contains, export and import change with it in the same commit.

## Build the data layer like the server is already reading it
An online version is in the works. We are not building it here, but nothing we write should make it harder. Keep serialization versioned and free of UI entanglement. Think "could this format cross a network and be read by code that has never seen our widgets?"

## The user is mid-thought
People use Icarus while their tactical idea is still hot, the interface must never make them wait or wonder. So when a feature works but feels wrong, it is not done.

## Fight for the obvious solution
Measure twice, cut once: understand the problem fully before building, because cleverness is what gets written when you haven't. The biggest simplicity win is refusing to solve problems we don't have. Good code is the most simple thing that delivers full functionality, nothing traded away, nothing bolted on. Push back when you see a more obvious way.

## Some general rules
These steer us in the right direction. They are not hard-set, but default to following them; if you think one should be ignored, be very loud about it and get approval from us first.

- Never edit `*.g.dart` files. Edit the source models, then run `dart run build_runner build --delete-conflicting-outputs`.
