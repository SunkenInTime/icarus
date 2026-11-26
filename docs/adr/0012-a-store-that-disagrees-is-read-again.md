# ADR 0012: A store that disagrees with its queue is read again, not repaired

**Status:** Accepted (2026-11-26)
**Feature:** The library store's cloud strategies (`packages/icarus_library/lib/src/store/cloud_store.dart`, `lib/src/cloud/shown.dart`, `lib/src/cloud/queue.dart`)

## Context

A cloud strategy's base, the rows the server last sent, is held twice on the device. The queue's record of every result it took (`Shown`) knows each row's page and version. The stored rows are what the page is drawn from. Every result changes both through one decision ([#807](https://github.com/SunkenInTime/icarus/pull/807)), so the two agree unless something went wrong: a bug, a crash mid-write, bytes gone bad, or a store written by a build that only ran on our machines.

The first answer to a disagreement repaired it row by row and kept as much of the device's copy as it could. A row the store held and the queue did not was taken into the queue. A second copy was removed. A missing or damaged row was held as "not readable here," with the read that would write it back owed. Three review rounds found faults in that design. The last found nine, almost all in the seams between the repairs and the moments they ran at: the queue's load, a page's first load, a refused write, a stale result, and what the reader and the sender then believed. Each repair is a state, and fixing the nine would have added more.

## Decision

A disagreement is a fault state. When the queue's record and the stored rows disagree about which rows exist, where, or at what version, the strategy's base is set aside and read again from the server. It uses the path a strategy's change of life already uses, without the life change.

- **What is checked, and when.** At the queue's load: the strategy, page and settings rows, and which items are stored on which page. At a page's first load, before any decision is made from it: each item's version. Two rows agree when their name, page and version match, whether or not this build can read their contents. A damaged row never agrees. Rows of a kind this build does not know are left out of the check.
- **What a set-aside does.** Every item and damaged row the base holds on the device leaves. The strategy, page and settings rows stay until the next page list replaces them. The queue's record starts again, with the page list owed and earlier reads fenced off, and every listed page is read again. The user's queued work is kept and sends under the usual rules once the page list has landed.
- **The stored state.** The strategy's base state is written with the set-aside, in one commit: it agrees, it is being read again, or it still disagrees after it was read again. Each of the last two names the reason and the build. The sender reports the state from what is stored, so the report cannot be lost.
- **One attempt per fault per build.** When the reads land and the base still disagrees, it is held: pages are not shown, results are still taken, and queued work still sends. A later build reads it again once, so a fix takes effect. No build reads the same fault again and again.

## Consequences

- While a base is being read again, its pages read as not shown yet, and they cannot be copied. Offline, the strategy stays that way until the server answers. This is accepted for a fault state, because the user's work is kept. The words and the screen for it belong to the live-results work, and the store is not switched on for users until that state has one.
- A disagreeing strategy costs one page list and one read per page, once per fault per build. A detection that fires on a state both copies legitimately hold differently would make that cost routine. So the agreement line has its own tests, and the models fail on any set-aside they did not cause.
- The device's copy of a disagreeing base is thrown away rather than corrected. Its rows are the server's, and the next read brings them back.
