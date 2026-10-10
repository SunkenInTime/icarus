# Collaborative editing

Two people editing the same strategy should never have to pick between their
work and a teammate's while both are online. This document describes how
cloud edits merge, so they don't have to.

## Where this comes from

Until protocol 5, every edit to a canvas item sent the whole item along with
the revision the client last saw, and the server refused it if the row had
moved on. The refused edit then waited in "Sync needs attention" for the user
to choose Use cloud, Keep mine or Keep both. That happened even when the two
people touched different things, such as one moving an agent while the other
changed its side.

Mature collaborative editors don't ask. Figma, which is the closest to Icarus
(a server-owned canvas of objects), keeps the latest value of each property of
each object:

- changes to different properties of one object both land;
- of two changes to the same property, the one that reaches the server last
  wins;
- a client keeps its own unacknowledged values on screen over incoming ones,
  so nothing flickers;
- writing a property can't recreate a deleted object.

Excalidraw, tldraw and Replicache work the same way at different
granularities. Live presence shows who is touching what, so collisions are
rare and people can see them when they happen. Icarus follows that model,
with one difference that Dara chose: an edit made offline that collides with
a teammate's change to the same field still waits for the user.

## The rule

A patch from a client that merges by field carries a `merge` object (see
`convex/lib/fieldMerge.ts`):

- `fields`: what the edit changed. For an element, these are top-level keys of
  its payload's `data`. For a lineup group, they are its items:
  `origins/<id>`, `landings/<id>`, `links/<id>`.
- `base` (only for work that waited offline): the value each of those fields
  had when the client last saw the item. A missing value means the field was
  absent.

The op still carries the item's whole payload as the client has it. Keep mine,
Keep both, conflict descriptions and media recovery all read that payload. The
server writes only the named fields onto the row as it is now:

- **No revision check.** The last write to a field wins. The row's revision
  still goes up by one per write, and clients still use it to follow changes.
- **Offline collisions are refused.** If `base` is present and a named field
  now holds neither its base value nor the value the op writes, the op is
  refused with `field_conflict` and nothing is written. The item waits in
  "Sync needs attention" as before. A field that already holds the op's value
  is not a collision.
- **Some changes can't be merged.** If the stored row and the op disagree on
  payload version or on what the element is (`id`, `elementType`, `kind`,
  `type`, `data`), the op is applied as an ordinary whole-item, revision-checked
  write. Turning an agent into a view cone and the Paranoia payload migration
  (#222) both go this way. So does a lineup field that names no item.
- **Lineup groups are checked after merging.** Named items are replaced,
  appended or removed, spots no lineup uses are dropped, and the result must
  be a group that could be stored: unique ids, every lineup's spots present,
  at least one lineup. If it isn't, for example because a teammate removed the
  spot a new lineup stands on, the op is refused with `merge_invalid`. A group
  that would overlap another still fails as it always has.
- **A live delete wins.** `element.delete` and `lineup.delete` with
  `lastWriterWins: true` skip the revision check. A delete without it (work
  that waited offline) is still checked.

An edit to an item a teammate deleted is still refused as `deleted`, and Keep
mine still brings the item back.

## Which fields move together

A merge must never combine half of one edit with half of another. The client
names every field in a group whenever any one of them changes:

- drawings: their geometry and its bounding box (`listOfPoints`, `lineStart`,
  `lineEnd`, `start`, `end`, `boundingBox`);
- text: `position`, `size`, `fontSize`, `sizeVersion`;
- images: `position`, `scale`, `sizeVersion`;
- view cones, abilities and utilities: `rotation` with `length`. A custom
  rectangle also includes its `position`, `customWidth` and `customLength`.

Everything else is an independent field. A point (`position`) is one field,
not two.

## What the client promises

- **Its base after an acknowledged edit is the payload it sent, never the
  merged row.** The merged row shows up as an ordinary remote change and is
  drawn like any teammate's edit. If the client took the merged row as its
  base, the next diff would see a teammate's fields as the user's own edits
  and write them back.
- **A whole write claims only a revision whose content the client drew.**
  After its own merge lands, the row's new revision also holds a teammate's
  fields that the client has not drawn yet. So a whole write made before the
  client reads the row again claims the revision before the merge, and is
  refused rather than overwriting those fields. A base never goes back to an
  older revision when a page is read late.
- **An op sends `base` unless it is live.** Live means the user made it while
  connected, with no disconnect before the queue took it. That rules out
  three kinds of work: work queued while disconnected, work recovered after
  a restart (including a replay of an op whose answer was lost), and
  automatic retries. The server only remembers op ids for 30 days, so an
  unguarded replay after that could overwrite newer work.
- **Keep mine after `field_conflict` sends the user's fields with a base of
  what the server held when it refused.** So a teammate's change made after
  that still asks.
- **A successor that waited behind an in-flight op is recomputed when that op
  lands.** It names what it changes from what the in-flight op wrote, so a
  change the user set back in the meantime is still sent.
- **Outbox records that hold merged work are version 3.** Builds from before
  field merging leave them alone rather than send them as whole writes.
- **A pending edit's own fields stay on screen until the server's copy
  includes them.**

One known limit: if the connection drops while a live op is already on its
way, the transport can resend that op once the connection returns, as it was
made: without a base. The user made that edit while online, so it lands as
the last write instead of asking.

## Compatibility

Clients that don't send `merge` keep today's behaviour exactly, so the live
web build and any open tab keep working while a new build rolls out. The
server only returns `field_conflict` and `merge_invalid` for ops that sent
`merge`, so older clients, which can't decode those reasons, never see them.
Stored rows keep their whole payloads, so every reader works as before.
