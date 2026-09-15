# Visibility model

Before declaring a visibility change complete, apply
[the acceptance contract](vision-acceptance-contract.md). It defines source
accounting, independent expectations, and the evidence required for completion.

## Authority

The SVG artwork defines wall positions, endpoints, and thickness in the map plane.
Extract those from the actual paths, transforms, stroke widths, caps, and joins.
Some strokes are already expanded into filled paths; use their painted footprint.
Cones meet the observer-facing edge of that footprint, with no arbitrary gap or
global thickness adjustment. Preserve the artwork, map size, and saved positions.

The extracted 3D map supplies support elevations and vertical information for
those SVG walls: solid height intervals, low cover, and openings. Associate that
information with SVG geometry offline. Ambiguous associations stay explicit and
reviewable. Exported mesh edges are not additional runtime walls.

An opening must provide a usable gameplay sightline before it makes an SVG wall
see-through. A gap in an extracted asset alone is insufficient. Ignore cosmetic,
inaccessible, or otherwise nonfunctional gaps and retain the drawn wall as a
tactical blocker. Record gameplay review separately from measured source heights;
an explicit gameplay decision takes precedence over an asset-only inference.

Some openings connect different floor heights. A horizontal slice through the
observer's eye cannot establish visibility through such an opening. Version 3
data may name `sightlineFloorSupportIds` for reviewed, horizontal destination
floors. Inside those exact support footprints, cast visibility to a standing
target on the destination floor. Project the existing SVG wall volumes onto
that target-eye plane, retaining their solid bases, frames, and overhead caps.
The destination floor does not create additional runtime walls.

Fracture's September 14 corridor follow-up restores the opening in
`p13-stroke-3`, reflected as `p13-stroke-4`. The user identified the free cone
beside the corridor. Complete source rays from its 8.91172 m floor to the
5.5 m A-side floor clear the lower wall and overhead structure. Subtract only
the measured opening from each existing wall band, preserving the varying
upper heights and conservative end frames. The nearby A tunnel perimeter
remains solid. The decision is recorded in
`scripts/data/fracture-reported-walls-2026-09-14.json`.

The September 15 follow-up separates Fracture's bare A-platform endpoint from
its taller barrier. Use the complete platform's conservative 9.0677929 m cap
only at the reviewed endpoint, including the defense artwork's duplicate ink.
Keep the column base and adjoining platform barriers solid. The exact review
is `scripts/data/fracture-platform-end-review-2026-09-15.json`.

The same follow-up corrects Bind's balcony frontage, Haven's low shrine and
separate framed window, Summit's tower frontage, and Pearl's Mid-to-B step.
Use the complete local assembly and both sides' actual artwork boundaries.
The decisions are recorded in `scripts/data/remaining-bind-source-ownership-review-2026-09-15.json`,
`scripts/data/remaining-haven-source-ownership-review-2026-09-15.json`,
`scripts/data/remaining-summit-source-ownership-review-2026-09-15.json`, and
`scripts/data/pearl-mid-step-review-2026-09-15.json`.

Lotus's small crate and stepped crate require separate local tier heights.
Keep the shared higher-crate edge; cap only the complete lower tier and small
crate outline. The stepped crate has no authored internal tier wall. Rendered
standing-target expectations therefore use the measured lower courtyard and
upper tier destination floors, preserving downward obstruction by the base.
Do not treat a horizontal target buried inside the upper crate body as a
standing player. The exact reviews are
`scripts/data/lotus-small-crate-outline-review-2026-09-15.json`,
`scripts/data/lotus-stepped-crate-review-2026-09-15.json`, and
`scripts/data/lotus-lower-courtyard-projection-review-2026-09-15.json`.

Haven's September 13 gameplay review supersedes its Mid Window floor projection.
The window is now a single tactical opening below its header, with its solid
end jamb retained. The sill remains a standing surface but does not block the
cone. No bundled Haven destination requests floor projection. This deliberately
omits sill detail to keep the view continuous as the observer moves. The user
explicitly requested this simplification after the projected floor produced a
detached patch. See `scripts/data/haven-tactical-sightlines-2026-09-13.json`.

The SVG floor fill limits where visibility is displayed. Its perimeter is not
automatically an opaque wall. Height and opening information decides which
authored boundaries block a sightline. Ignore decorative foliage absent from
the SVG; retain represented structural obstacles such as fences and grates.

Classify each painted element before assigning a height. Zipline symbols and
ramp/floor markings remain visible artwork with no blocking interval. For
example, Icebox's A Site dashed zipline and the cross-hall Tube ramp marks are
annotations. Stroke color, opacity, or a nearby mesh alone cannot identify a wall.

Verify the source object's role and local extent before assigning a wall height.
A nearby monitor, decal, or snow cap does not describe a complete ramp or building.
For stacked structures, test a named gameplay opening from its upper floor and
test the solid base separately from below. Compare against gameplay images or
Riot's documented map changes; agreement between two implementations of the same
height assignment cannot establish that assignment is correct.

## Elevation

Standing eye height is the selected support surface plus standing camera height.
On a box, use the box top as support; its sides are below that viewpoint and do
not block sight as though the agent were standing beside it. By default choose
the highest locally applicable surface on which a player can stand. Abilities
can provide access: ordinary walking reachability, navigation connectivity, a
named callout, and a recorded jump route are not eligibility requirements.
Include isolated platforms, props, ledges and roofs when their local physical
surface supports the standing player and clears the player capsule. Apply actual
unwalkable, player-blocking and kill-volume rules. Interiors retain their usable
floors, and explicit lower-floor selections remain available at stacked passages.

The September 14 covered-interior review gives the represented corridor or room
priority at the reviewed exterior roof and ceiling projections. This is a
recorded default-placement decision, not a finding that the roof lacks physical
collision. Keep those supports and their heights, set only
`automaticStandingAllowed: false`, and retain explicit saved roof selections.
The exact domains and assembly evidence are in
`scripts/data/covered-interior-gameplay-review-2026-09-14.json`. Offline source
records move from `domains` to `manualDomains` without changing their measured
geometry. This exception does not exclude unrelated ability-accessible props,
ledges or platforms.

The collision-body addendum applies the same default rule to the reviewed
covered interiors in Abyss, Corrode, and Summit. A collision volume can describe
an exterior ceiling just as a mesh can. Its physical upper level remains
selectable; only automatic placement prefers the represented room below.
The exact domains are recorded separately in
`scripts/data/collision-covered-interior-review-2026-09-14.json`.

Split's September 15 source completion replaces its legacy standing data with
measured version 3 floors. All 8,335 scene objects have a resolved collision
disposition, including 24 analytic capsules. Keep the 849 physical standing
domains, with 206 exact exterior roof, roof-fixture and overhead-boundary
domains reserved for explicit selection under the represented-interior rule.
The independent crane and construction-panel standing surfaces remain automatic.
The exact default review is `scripts/data/split-covered-interior-review-2026-09-15.json`.
The source manifest and release certificate now require an independent source
for Split as they do for every other map. No legacy source exemption remains.

Floor projection subtracts each projected wall face separately. This has the
same result as subtracting their union, while avoiding overlapping thin path
contours that can make Skia fail beside a wall endpoint. Keep the sill, header,
and hole checks when changing this calculation.

Interpolated ground can pass through a raised wall at a stacked passage. If its
standing eye is inside an active SVG wall, it cannot take priority over a verified
physical floor below it. Choose the highest eligible surface whose standing eye
clears the local walls. Preserve explicit saved elevations, including ground.

Reference interpolation also cannot outrank a verified physical floor when both
eyes clear the SVG walls. Version 3 height data records measured ground through
`ground.standingTriangles`, an explicit list of triangle indices. Only the first
covering ground triangle supplies the local ground height; a physical triangle
hidden behind an earlier reference triangle cannot certify that reference.
Unmarked triangles still supply reference heights and saved-ground matching.
Version 2 data keeps its existing selection behavior until its ground has been
measured and the version 3 data passes the acceptance checks.

For version 3 data, resolve a saved eye to the closest local level, including
ground, within the 2 cm source-height tolerance. This accommodates corrected
collision heights and rounded source planes without jumping from a saved lower
passage to the roof. Exact nearby levels remain separate choices. Equally close
different levels remain unavailable; the UI reports the automatic fallback.
The saved numeric value is not rewritten. Earlier data keeps its existing
matching behavior.

Geometric height confidence does not establish gameplay eligibility. A bundled
support must have `automaticStandingAllowed: true` before the default can select
it. Record the local physical collision surface and standing clearance in the
offline source decisions; navigation and gameplay references can corroborate
those measurements. Evaluate physical standing tops independently of navigation.
Previously unnamed or disconnected surfaces must receive this same physical
test, rather than remain excluded for lacking a gameplay role. A rendered
horizontal mesh face alone does not establish a physical standing floor.

A collision body wholly enclosed by resolved player collision adds no standing
surface. For curved shapes, prove containment of the complete boundary using
the actual scaled shape. Distance to the enclosing body's triangles alone does
not establish clearance inside its solid interior. Excluding distant collision
requires its complete bounds, including the player radius, to miss the declared
region.

Dara's gameplay review can establish eligibility when extracted collision
metadata is incomplete or its clearance prediction disagrees with the observed
position. Keep that review separate from the measured floor height and the
original collision evidence. The September 8 review is recorded in
`scripts/data/gameplay-standing-review-2026-09-08.json`, with exact sample
identities and source fingerprints. It covers 454 positions across seven maps.
On Bind's fountain, exclude only the narrow inner ring; retain the center and
the outer basin. Bake the measured ring footprint, not a filled center exclusion.
Use a matched player-collision floor where available; otherwise retain the
reviewed local source face as the geometric height reference. This review does
not authorize unrelated faces elsewhere on the same source object.

Ascent's later review excludes sixty exact standing domains on boundary-volume
caps, bell-tower ledges and the Tree-room upper trim. The canonical decision is
`scripts/data/ascent-playable-space-review.json`. Preserve the collision bodies
and all other standing domains. The diagnostic 13 m threshold is not a gameplay
height limit; apply only the recorded domain footprints and source faces.

Breeze's ceiling review excludes exactly `volume-21-0`, the upper face at 51 m
shown in the review viewer. Dara confirmed it is outside playable space even
allowing agent abilities. The canonical decision is
`scripts/data/breeze-playable-space-review.json`. Retain the player-blocking
body from 19 m to 51 m and every other measured or reviewed standing domain.

Fracture's ceiling review excludes exactly `volume-507-0`, the upper face at
74.5399 m shown in the review viewer. Dara confirmed it is outside playable
space even allowing agent abilities. The canonical decision is
`scripts/data/fracture-playable-space-review.json`. Retain its player-blocking
body from about 20.43 m to 74.54 m and every other standing domain.

Pearl's review excludes four exact upper faces recorded in
`scripts/data/pearl-playable-space-review.json`. Its map-wide collision body
spans 28.4976–48.6261 m, matching Dara's approximate 29–49 m approval condition.
Retain all four collision bodies and all other measured standing domains.

Abyss's review excludes 284 exact standing domains: 15 collision-volume tops
and 269 scenery/cliff domains across ten scene meshes. Dara approved both
groups. Apply `scripts/data/abyss-playable-space-review.json` without removing
their collision bodies or other surfaces on those objects.

The September 12 screenshot review additionally excludes Abyss's exact upper
faces `volume-132-0`, `volume-141-0`, and `volume-142-0`, and Haven's
`volume-34-0` and `volume-35-0`. These collision-volume tops were selecting eyes above the reported
Mid, ramp, and tower interiors. The agent matched the user's gameplay reports
to these source faces; this is separate from the earlier viewer approvals.
The canonical record is `scripts/data/reported-sightlines-2026-09-12.json`.
Retain the collision bodies and the usable floors beneath them. Corrected
openings must also restore any measured ledge or sill standing area previously
clipped away by an incorrect opaque SVG wall.

Corrode's review excludes only `volume-1026-0`, the upper face at 43.3816 m
on `BP_BlockingVolume692`. Dara confirmed it is outside play. Apply
`scripts/data/corrode-playable-space-review.json` and retain the collision body.
These reviews define no global height cutoff.

Summit's review excludes exactly `volume-0-0` at 65 m and `volume-328-0`
at 42.75 m. Dara confirmed both upper faces are outside play even with
abilities. Apply `scripts/data/summit-playable-space-review.json`; retain
both collision bodies and every other measured standing domain.

Sunset's review excludes 190 exact standing domains on fourteen defender-spawn
scenery objects, including sinkhole pillars, cliffs and pipe sections. Dara
confirmed all highlighted domains are outside play even with abilities. Apply
`scripts/data/sunset-playable-space-review.json`; retain all collision bodies
and every other measured domain. The review records the exact match between
the completed scenery measurements shown to Dara and the final whole-map source.

At stacked passages, verify a continuous walk on each level against its named
source floor. A ground interpolation that switches between an upper hallway and
the floor beneath it needs separate surfaces. Confirm a usable standing domain
after clipping each support against the SVG and higher walls; a tiny residual
polygon or a horizontal face on a wall is insufficient evidence of a platform.
When one source object contains several levels, record the selected floor faces
and audit those faces; an overhead beam is not the height of the floor beneath it.

Only emitted, first-covering physical ground can replace an explicit source
level. Planned polygons and triangles hidden behind earlier ground cannot
supply that level at runtime. Keep source choices along the two overlay-grid
steps affected by projection and partitioning rounding; this reduces coverage
credit without expanding the measured standing domain.

A lower box's exposed mesh rim is not automatically a standing position. Check
whether a box resting on it leaves clearance for the extracted player capsule.
Record the covering object and capsule source when rejecting a covered level.
Do not remove a platform solely because its area is small. Do not make the SVG
perimeter transparent to recover sightlines that exist only outside the drawn map.

Treat connected ramps and slopes as continuous tactical ground. Changes in floor
height do not create extra wall edges or hide the connected downhill floor by
themselves. Retain real intervening obstacles and meaningful separate levels.
Crouching and changing door states are outside the current pass.

## Implementation and acceptance

Bake compact SVG wall geometry, vertical intervals, and support information
offline. Runtime visibility uses those records, rather than the extracted or
warped 3D triangle scene. Earlier mesh-normalization candidates are reference
experiments, not the implementation to extend.

First deliver Split for Dara's feedback before extending this model to other maps.
Personally inspect the actual SVG and cone renders at normal size and enlarged
wall edges. Check solid wall contact, corners with different stroke widths,
preserved openings, low cover, standing on a box, and a connected ramp. Report
unknown source associations, data size, and measured query cost. A passing
synthetic test is not evidence that an unreviewed game sightline is accurate.

Validate the segments between cone vertices, not only the sampled ray endpoints.
Two overlapping painted wall strokes can create a visibility corner at their
intersection. A wall can also cross the cone's range circle while both endpoints
lie outside it. Preserve these events or the polygon can cut diagonally short of
correctly placed SVG ink. Neither event adds a new wall or changes its height.

Use `scripts/audit_svg_cone_boundaries.py` with the production polygon export in
`tool/export_svg_boundary_sweep_test.dart` to check these contacts independently.
The audit separates range-arc chords and radial corner shadows from wall contacts.
Also inspect production painter crops; matching geometry does not alone verify
pixel coverage, the selected elevation, or the gameplay meaning of an opening.

The four saved Icebox poses in review `1788823493671-212d5f8` are regression
fixtures in `test/svg_automatic_standing_test.dart`. Their source measurements
come from `scripts/review_icebox_user_sightlines.py`. Test the windows from above
and their bases from below, the connector doorway and its solid jamb, and the
local lower pipe step separately from the higher pipe on the same assembly.
Resolve missing-floor findings before calling a gameplay-height review complete.
An infinite structural-outline fallback is an assumption, not a reviewed height.

Haven's same follow-up excludes the six connected tower ceiling-volume tops,
`volume-32-0` through `volume-37-0`. The earlier review excluded only two and
missed a narrow 45 m strip above the 9 m upper room. Retain all six collision
bodies and the real upper and lower floors. The source classification must
separate an overhead collision box from a usable standing platform before the
highest-floor selection runs. A clear top face alone can still be an invisible
level boundary rather than a playable surface.

The September 13 Breeze review excludes the exact upper standing face
`volume-583-0` on `SuperGrid_Box343`. The collision box spans 8 to 16 m above the
4 m passage floor; its clear top is not that passage's gameplay standing surface.
The nearby box at the second reported position retains its real 9 m top.
`scripts/data/breeze-gameplay-sightlines-2026-09-13.json` also records three
continuous facade regions. Their complete structural assemblies supply heights;
isolated trim and cistern tops do not create openings in those SVG outlines.
Source hashes are pinned so changed geometry requires renewed review.

Run the gameplay regressions before packaging. The desktop and Store release
scripts run the reported sightline, Haven movement, and Breeze gameplay tests
against the actual bundled assets. Their release flag ignores diagnostic model
folder overrides. Source-height agreement alone cannot replace these behavioral
checks. Preserve a before-fix failure and test deliberate bad standing and wall
assignments on isolated data copies when adding another regression.

Breeze's covered-opening follow-up excludes both connected Courtyard ceiling
tops, volumes 387 and 388, while retaining the 4 m room floor. Its Mid Nest
room retains the 9 m floor. Measure complete window sill/header assemblies;
nearest-source height cells must not turn a roof above an opening into a solid
wall. A single SVG parent can contain both a window and exterior box outlines,
so classify those portions separately. The canonical decisions are in
`scripts/data/breeze-covered-openings-2026-09-13.json`.

Check both end frames and the entire usable opening from moving origins on both
sides. Numerical fragments can block runtime rays despite negligible polygon
area. Classification clips use the 1e-8 source-overlay grid and cannot leave
old-height fragments at reflected boundaries. The roof diagnostic in
`scripts/audit_breeze_overhead_candidates.py` flags suspended collision tops
above lower floors for review; it does not make roofs or isolated ledges
ineligible automatically.

Run the cross-map detectors after fixing a recurring source-association problem.
`scripts/audit_all_map_overhead_candidates.py` inventories suspended tops;
`scripts/audit_all_map_opening_assignments.py` checks measured gaps against both
wall assets and nearby retained standing floors. Their candidates require role
review. Missing navigation, collision channels, and source gaps alone do not
establish gameplay behavior. Keep weak source overlaps separate from positions
inside the receiver with a wall-clear standing eye.

`scripts/audit_all_map_wall_residue.py` checks every wall footprint and samples
mirrored vertical profiles. The compiler removes whole wall records that
collapse on the 1e-8 source-overlay grid. It preserves every remaining record.
Before packaging modified map assets, run
`python scripts/svg_wall_footprint_integrity.py` to certify all 26 sides.
The release regression verifies the certificate against the exact asset bytes
and audit source, so an older certificate cannot cover changed map data.

The focused September 13 review excludes Abyss standing domains
`volume-145-0`, `volume-146-0`, and `volume-1603-0`, and Haven
`volume-215-0`. Complete neighboring assemblies identify these as overhead
collision or invisible boundary tops. Retain their collision bodies and every
other measured floor. Both physical and measured support aliases must receive
the same exclusion. The canonical record is
`scripts/data/systematic-roof-review-2026-09-13.json`. Breeze bridge parapets
334/335 and Icebox connector railing 496 remain eligible.

Pearl's lower B Hall tunnel retains its 2.5 m floor beneath a continuous
6.175 m ceiling. Use the complete tunnel shell, including its end frame,
from `scripts/data/pearl-lower-tunnel-review-2026-09-13.json`. Classify each
side's actual painted mouth separately: the authored reflection differs by
0.0003 SVG units and otherwise leaves a thin old-height blocker. Restore
only source standing area released by the corrected wall intervals.

The twenty focused opening families have no supported opening changes.
Their decisions are recorded in
`scripts/data/systematic-opening-review-2026-09-13.json`. In particular,
Icebox ramp parents p7-stroke-10 and p7-stroke-18 have front railings above
their facade tops. A cap measured from the ramp skin alone removes real
represented structure. Preserve the railings as tactical blockers rather
than treating spaces between their bars as windows.

`test/systematic_map_gameplay_test.dart` checks these reviewed roof decisions,
retained physical parapets and railings, and Pearl's moving lower tunnel
sightline with overhead and end-frame controls on both sides. Both packaging
scripts include these checks against the exact bundled assets.
