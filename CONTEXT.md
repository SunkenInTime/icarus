# Icarus

A desktop-first app for creating and sharing Valorant map strategies:
interactive map drawing, agent and ability placement, lineups, and exports.

## Language

**Strategy**

One Valorant map plan. It is the top-level object a user creates and contains
pages, a map choice, and a theme. This is the domain object. Reserve the word
for this object in code and product copy.

Avoid: plan, document, project

**Page**

One ordered part of a strategy containing the agents, abilities, drawings,
text, images, utilities, and lineups visible at that point. In user-facing
video export copy, a page shown in sequence is called a "step."

Avoid: slide, scene, frame

**Step duration**

How long each included page stays on screen in an exported video. One global
value applies to each export.

Avoid: page duration, hold time

**Page transition**

The animated change between two pages. Widgets move, morph, appear, or
disappear. Freehand drawings and images fade in early.

Avoid: page switch animation

**Transition entry**

One widget's role in a page transition. It moves, appears, or disappears.

Avoid: transition item

**Agent path**

The curved route an agent travels along during a page transition.

Avoid: movement path, trajectory

**Video export**

Rendering a chosen subset of a strategy's pages, in order, into an `.mp4`.
Each page stays on screen for the step duration, with full-fidelity page
transitions between pages.

Avoid: video sequencing, movie export

**Lineup**

A saved ability setup with position and aim references. A lineup belongs to a
page and may contain notes, links, and images. Lineups are organized into
lineup groups in the local model.

**`.ica` file**

Icarus's zip-based strategy interchange format for importing and exporting a
whole strategy. It is unrelated to video export.

Avoid: archive, which is ambiguous with a library backup
