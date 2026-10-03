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

**Replay**:
A Valorant match recording (a `.vrf` file) that Valorant downloads from a
player's career page. Icarus plays it back on the map. Replays are files, not
part of the library; decoding one only fills a rebuildable cache.
_Avoid_: demo, VOD, recording

**Perspective**:
The team a replay is watched from. Its players are allies, the other team's
are enemies, and its side each round decides which way up the map is drawn.
_Avoid_: point of view, team view

**Capture**:
Saving the replay's current moment as a page of a strategy: players, their
facing, and the utility on the map at that instant.
_Avoid_: snapshot, export
