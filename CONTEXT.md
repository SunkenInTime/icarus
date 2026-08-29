# Icarus

A desktop-first app for creating and sharing Valorant map strategies:
interactive map drawing, agent/ability placement, lineups, and exports.

## Language

**Strategy**:
One Valorant map plan — the top-level document a user creates, containing
pages, a map choice, and a theme. This is the domain object; do not name code
abstractions "…Strategy" (GoF sense) unless they operate on this object.
_Avoid_: plan, document, project

**Page**:
One frame of a strategy: the agents, abilities, drawings, text, images, and
utilities shown at a moment in the plan. Ordered within a strategy. In
user-facing video-export copy, a page shown in sequence is called a "step".
_Avoid_: slide, scene, frame

**Step duration**:
How long each included page is held on screen in an exported video. One
global value per export.
_Avoid_: page duration, hold time

**Page transition**:
The animated change between two pages: widgets move, morph, appear, or
disappear; freehand drawings and images fade in early.
_Avoid_: page switch animation

**Transition entry**:
One widget's role in a page transition — it moves, appears, or disappears.
_Avoid_: transition item

**Agent path**:
The curved route an agent travels along during a page transition.
_Avoid_: movement path, trajectory

**Video export**:
Rendering a chosen subset of a strategy's pages, in order, into an .mp4 —
each page held for the step duration with full-fidelity page transitions
between them.
_Avoid_: video sequencing, movie export

**Lineup**:
A saved ability setup (position/aim reference) attached to a page, grouped
into lineup groups.

**.ica file**:
Icarus's zip-based strategy interchange format for import/export of whole
strategies. Unrelated to video export.
_Avoid_: archive (ambiguous with library backups)

**Op**:
One queued change to cloud data. An op lands when the server accepts it.
Its op ID names that exact change. Changing the intended work creates a new op
with a new ID; retrying the same work keeps the existing ID.
_Avoid_: request, event

**Outbox record**:
The durable saved form of one queued op and its delivery state, used to recover
unsent cloud work after an app restart. It is not a server payload.
_Avoid_: payload, cached request
