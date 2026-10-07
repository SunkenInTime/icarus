# Visibility model

> The offline pipeline this document describes (`scripts/`, the review data
> under `scripts/data/`, the audit and bench harnesses under `tool/`, and the
> per-map acceptance reports) was moved out of the repository on 2026-09-19.
> It lives in the `icarus-vision-pipeline` archive, copied from commit
> `f46a4a4` of `fix/all-map-vision`, where every file keeps its history. The
> repository keeps only what the app and CI need: the bundled
> `assets/maps/*_svg_height_*.json.gz` models, `tool/check_bundled_wall_heights.dart`
> and this document.

## Blocking from VALORANT's minimap lines (2026-10-04)

The bundled models no longer carry band data measured from the 3D map. Each
wall now takes its heights from VALORANT's minimap vision lines, the 2D line
set the game uses for its own minimap cones. The sections after this one
describe the measured model these walls replace. They still explain the
file format, supports, and how the runtime casts.

**Source.** `AresWorldSettings.MinimapVisionOccluders` names a
`DataTable<VisionGeometry>` for each map. Each row is one layer. `g` holds the
line count and the layer's threshold in centimetres, `v` holds minimap uv
points, and `l` holds index pairs. The thresholds are absolute heights in
world space. Uv points convert to UE world space through the map's
`XMultiplier`/`XScalarToAdd` and `YMultiplier`/`YScalarToAdd`. They then go to
scene metres as `(X, -Y) / 100` and through the map's `nativeTo{Side}Svg`
affine.

**Layer rule.** This rule is inferred; the assets do not state it. A viewer
uses layer k when its capsule centre, floor + 0.98 m, lies in
`[th_k, th_k+1)`. The 98 cm capsule half-height is in the assets. A scan of
where each line's obstacle top falls peaks sharply at 0.98–0.99 m; feet and
eye height both score worse. Icarus casts from floor + 1.75 m, so each layer
is stored as an eye band shifted up by 0.77 m. The runtime treats a band as
closed at both ends, but a layer is open at the top. So every band edge sits
1e-6 m below its threshold, and a viewer exactly on a threshold gets the
layer above. Ascent has floors at 5.02 m, under a 6.0 m threshold.

**Walls are our art.** Riot's lines sit centimetres to a metre off the drawn
walls, which left visible gaps. So the lines decide only how tall a wall is,
and the art decides where it is:
- The wall art is each wall's footprint by its own fill rule, so a hole
  drawn inside a wall stays floor.
- Every edge of the wall-art outline, in 0.5-unit pieces, takes the union of
  layers of every Riot line running alongside it (|cos| ≥ 0.7, within 2 SVG
  units). This keeps both lines on walls that carry a ground line and an
  upper one. A short stretch with no parallel line (a bevel, a jog, a
  wall's end; at most 4 units, between edges that have one) takes the
  layers of the nearest lines, all of them where several are equally near
  (Riot often stacks a ground line and an upper line on one spot). A longer
  one takes none: a drawn ring or box that
  only touches a wall is not part of it, and borrowing the wall's line there
  cut cones beside it into slivers.
- Runs of equal layers become one-sided strips, 0.01 thick, inside the art.
  The art is closed by 0.03 first, so hairline cracks between strokes don't
  leak. Touching strips with the same heights are merged into one outline
  each, and those outlines are the model's walls (no `runtimeWalls`). With
  a wall per strip, each strip's ends were silhouettes and a cone grew to
  about 10,000 points; with strips merged only for casting, stepping an
  agent out of a wall searched every strip and took up to 1.6 s.
- A stretch of Riot line with no art beside it (glass, railings, crates the
  art doesn't draw) stays as a thin wall on Riot's own line. Where the
  stretch was cut because the art beside it takes over, its end is joined
  to the nearest art, so no ray slips between the line and the wall.
- Lines Riot lacks are added by hand in the vision-lines review data
  (`added` in `<map>.edits.json`). The only one so far is the Lotus defense
  platform wall, which the 3D map shows solid from 3.0 to 5.1 m.
- Layers Riot has where the game is open are taken off the same way
  (`cleared`: lines lying wholly inside an area lose the listed layers).
  The only one so far is the Haven C Garage window, open from the garage
  floor (layer 0) as in the 3D map; Dara ruled it open on 2026-09-19 and
  again on 2026-10-04.
- The receiver is the floor minus the wall art, so a cone never paints over
  a wall.

`sightlineFloorSupportIds` is dropped. Riot's layers already decide which
floors a viewer sees over. Each model stores the thresholds as
`riotVisionLayers`, and `test/svg_riot_vision_test.dart` checks that every
band edge is one of them.

**Built by.** `scripts/riot/build_art.py` in the icarus-vision-pipeline
archive, run on the bundled models at commit `0497bec`. The review tool and its line data are in
`tools/vision-lines`.

**Checked against the 3D map.** This used 240 standing poses per map side and
cast against the extracted geometry. Only the part of each ray that lands on
floor the app draws counts. Rays leaving the map are never drawn, and
counting them made Pearl look worse than it is. A leak is a stretch the
model sees that the 3D map says is hidden; a false shadow is the reverse.
The check is stricter than the game. Riot's minimap ignores props (crates,
poles, low walls) the 3D map has, and the cones beside them look normal.

| visible floor, both sides | measured model | art + Riot heights |
|---|---|---|
| leaked length | 1,747,007 | 2,313,132 (+32%) |
| false-shadow length | 32,714,287 | 33,816,279 (+3.4%) |

Pearl (−88% leaked), Summit (−90%), Breeze (−65%), Ascent (−63%), Corrode
(−52%) and Haven (−43%) improve. Abyss, Fracture, Icebox and Sunset leak
about twice as much or more, and Split and Bind about a quarter more, where
Riot's lines are sparse or ignore props.

Cones stay within 165 fps: on a profile-build drag across every map side,
frame build is at most 3.35 ms at p99 over two runs (budget 6.06 ms) and
no frame's build goes over budget.

Stepping an agent out of a wall (`standablePointNear`, every frame of a
drag) tests points against every wall and the floor. The floor has every
wall cut out of it, thousands of edges in one ring, and walls run along
whole outlines, so `_Footprint` now files each edge under the 1-unit rows
its height reaches and a test reads one row; the answer is unchanged
(`test/svg_footprint_contains_test.dart`). Over a grid of every 1.37 units,
in a profile build, the step plus choosing the standing level takes at most
2.0–5.6 ms on Lotus, Breeze and Summit, about what the measured model took.

Walling off everything that is neither floor nor wall was tried. Rays
leaving the map are never drawn, so it changed nothing visible on Pearl. On
Abyss and Icebox it blocked real sightlines across drops and gaps (+54% and
+34% false shadow on visible floor). It was not kept.

Riot blocks three places the measured model left open:
- the floor past the end of Bind's B container. Dara chose Riot's lines
  here (2026-10-04), and the test follows them;
- Breeze Mid's slanted-roof opening. Dara chose Riot's lines here too
  (2026-10-04), and the test follows them;
- the Haven C Garage window from the garage floor. Dara kept it open
  (2026-10-04), so its lines are cleared for layer 0 and its test checks
  the window is open.

**Rejected.**
- Riot's lines as they come: they leave gaps beside the art.
- Snapping the lines onto the art: tracing closes real openings, and
  receiver-edge snapping lands under walls.
- Our measured pieces with Riot heights.
- A measured-height fallback for edges with no Riot line: it adds 4–8% false
  shadow.

Before declaring a visibility change complete, apply the acceptance contract
(`docs/vision-acceptance-contract.md` in the archive). It defines source
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

Keep source standing-plane precision through capsule clearance. The clearance
contact tolerance is 1 mm; rounding plane coefficients to four decimals can
move a slope inside its own collider even when the height error is below the
runtime comparison tolerance. Pearl's September 18 Mid slope lost its whole
standing surface this way. The measured restoration is recorded in
`scripts/data/pearl-mid-slope-standing-2026-09-18.json` and compiled by
`scripts/apply_pearl_mid_slope_standing.py`. It adds the recovered floor without
changing wall footprints or bands.

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
The crane and construction-panel surfaces were kept automatic here; the
October 2 rule below took that back. The exact default review is `scripts/data/split-covered-interior-review-2026-09-15.json`.
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

No surface 10 m or more above the ground everywhere beneath it is a
default level (Dara, 2026-10-02). Split's crane arm over Mid stood a
dropped agent 30 m above the floor, and Lotus's B Main boundary top 14 m;
both cones saw across half the map. Decoded replays put no player above
13.6 m on Split or 9.5 m on Lotus, and no automatic surface on any map sat
between 8.2 m and 10.4 m above its ground, so the line falls in a clear gap.
Such surfaces keep their geometry and stay selectable by hand. The archive's
`scripts/demote_far_above_ground_supports.py` applies the rule, and
`test/svg_far_support_test.dart` holds every bundled model to it.

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
Before packaging modified map assets, run `svg_wall_footprint_integrity.py`
from the archive to certify all 26 sides, then update the checksums in
`test/bundled_map_models_test.dart`; the certificate lives with the archive.

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

## Wall bands re-derived by ray probing (2026-09-17)

The bundled wall bands were re-derived from the extracted 3D scene by
measuring the quantity a band encodes: the eye heights at which a horizontal
sightline crossing the painted stroke is blocked. `scripts/derive_wall_bands_by_rays.py`
probes each stroke at stations along its centreline with a 1 m horizontal
segment across the ink at every 0.1 m up to 40 m, against opaque and masked
render geometry with decor excluded. A height blocks when 60% of stations are
stopped; runs form bands relative to the wall's floor. Runs set back more than
0.3 m behind the wall's own face are dropped as neighbouring structure. A
stroke with fewer than six faces in its corridor keeps its previous bands.

Three passes then decide what may replace the reviewed data:
`scripts/protect_reviewed_walls.py` keeps every wall named in a recorded
review, fixture or partition (both sides, mirrored through the alignment);
`scripts/smooth_wall_band_neighbours.py` rejects a lowered piece whose
touching neighbours on the same stroke stayed high, so no notch is cut into a
solid wall; `scripts/cap_unsupported_raises.py` rejects a raised top that the
narrow-footprint reading from `scripts/audit_svg_wall_heights_vs_world.py`
cannot support. Split joined this pipeline on 2026-09-19; see below.

Acceptance was the per-map gameplay suite (`ICARUS_VERIFY_BUNDLED_GAMEPLAY`),
now in the archive with the pipeline. The repository pins the resulting models
by checksum in `test/bundled_map_models_test.dart`.

A wall that blocks every probed eye height up to the 40 m ceiling is recorded
with an open top (`null`) on its last band. That is a measurement, not the old
reviewed-label fallback, so `tool/check_bundled_wall_heights.dart` accepts an
open top there and nowhere else; unknown walls, non-finite floors and
unbounded lower edges still block the release.

## Split brought onto the piece model (2026-09-19)

Split was the prototype. Its wall layer stayed at 69 records, one per
painted run with a single hand-assigned band, while the other twelve maps
were compiled from reviewed decisions into pieces about a metre long with
bands measured from the 3D scene. Every rule on this branch works piece by
piece, so Split was skipped by all of them.

Rather than author the decisions review Split never had,
`scripts/partition_split_walls.py` cuts each record into pieces about two SVG
units long along its medial line (`<parent>-local-<n>`), keeping the parent's
floor and bands so the cut alone changes nothing (the ink union is asserted
unchanged). Records whose names carry a reviewed prop cut (`-low-`,
`-counter-`, `-planter-`, `vent…-opening`, …) stay whole and are protected.
The pieces then go through the same passes as the other maps: ray derivation,
reviewed-wall protection, the perimeter seal (its Split exemption removed),
the narrow-footprint audit and raise cap, the anomaly rules, box outlines and
notch closing. The neighbour-smoothing pass is skipped for Split on purpose:
its baseline bands are upper bounds rather than reviews, and smoothing would
restore three quarters of the measured lowerings.

## Stacked areas and tunnels (2026-09-19)

Dara's rule for stacked areas: the top layer is the default, and an agent
placed on a lower layer sees that layer's view. The data already carries
this: the painted ground is the lower floor, the upper floor is a standing
surface that automatic standing prefers, and explicit elevation selection
reaches the lower one. Rays never consult the ground; the layers separate
by height bands alone.

`scripts/apply_reviewed_openings.py` with
`scripts/data/reviewed-openings-2026-09-19.json` records spots Dara ruled
see-through where a protected record kept the ray derivation out: Pearl's
B Hall tunnel west mouth is a passage under a 7 m header. Walls at least
half inside the region take the derived bands; the sealed map edge beside
a mouth stays sealed.

Two further passes were built and withdrawn the same day, and stay in the
archive's `scripts/` unapplied. `remeasure_above_openings.py` replaced the tunnel
review's blanket above the ceiling with what the horizontal probe found,
which was nothing until 11 m; Dara confirmed the ramp into that tunnel is
walled on both sides, so the probe was missing a set-back wall and the
blanket was right. `seal_void_walls.py` only existed to stop the leak that
change caused. A reading of "nothing above the ceiling" on a covered
passage is not evidence without Dara.

## Windows into unplayable space (2026-10-02)

Dara's rule: a hole no player could see or shoot through is not a hole in
the tactical model. Sunset's Mid building showed why. Both long walls carry
a measured window from about 6 to 7.6 m, the building's inside is not
painted floor, and a cone from the shack roof beside it went in one window,
across the empty interior and out of the other.

A window is a gap of at most 3 m between two bands of one wall piece. Where
a piece runs along unplayable space, the archive's
`scripts/seal_windows_into_voids.py` fills its windows. It is narrower than
the withdrawn void seal and changes nothing else:
- An eye above a wall's top still sees over it.
- A passage under a wall's lowest band stays open.
- A gap taller than 3 m stays open. It is sky between a wall and something
  far overhead, not a window.
- A window with painted floor on both sides stays a window.
- A gap that holds the eye of a player standing on a surface touching the
  piece stays open, so an agent on a pillar still sees out of it.
- Openings Dara reviewed as see-through keep their gaps.

The reviewed sightline suite from the archive passes on the sealed models.
`test/svg_void_window_test.dart` pins the Sunset case.

## Bands checked from where players stand (2026-10-02)

The ray probe above looks across the ink, half a metre either side. Where the
real face sits further off the ink than that, it measured nothing and left
the piece open. Lotus's defense platform wall (`p7-stroke-3-local-1`, 34
units long) had no band below 20.75 m, so Chamber standing on the 3 m
platform saw straight through it. Bind's B container outline had no bands at
all.

The archive's `scripts/truth/` checks the bundled models from the player's
side instead. From every standable spot on an 8-unit grid, about 32,000 on
both sides of all maps, it casts 720 horizontal rays at the runtime eye. Each
ray runs twice: once against the painted walls active at that eye, once
against the 3D scene's solid, non-decor, non-floor faces sliced at the eye.

A painted piece is solid at an eye when, of the rays from that eye height
that cross it, the scene stops at least 60% within a metre of it (and at
least six). Where a piece the model leaves open is solid, its band is raised
to the height of what those rays hit, cut short at the nearest eye heights
where the scene lets most rays through. Bands only rise. Ids that record a
decision about an opening (review, report, user section, opening, door,
window, sill, jamb, header) are not changed; where the scene disagrees they
are listed in the archive for review. A piece longer than 3 units that the
scene stops only a fifth to three fifths of the rays through is a window in
a longer wall, and is first cut into one-unit pieces (`-truth-cut-N`) so the
solid part can rise without closing the window.

Result on the bundled models (spots that see through a painted piece the
scene says is solid, then rays): 11,054 to 5,905 spots and 337,158 to
104,440 rays, with false shadows (painted walls blocking where the scene is
open) up 0.7%. 1,397 pieces rose and 128 were cut into 1,910. Most of what
the check still reports is not a data error. Of the remaining leak rays,
68% cross pieces the scene leaves open at that eye, where a prop or frame
near the piece stopped a few; 20% cross short pieces that really are partly
open, such as railings. `test/svg_truth_bands_test.dart` (now `svg_riot_vision_test.dart`) pinned the Lotus wall
and the Bind container.

Dara ruled on the 119 recorded-decision pieces from in-game renders on
2026-10-03. 51 became solid at the measured heights. Most are the Abyss
atrium wall's `user-section` strips. They were never a decision: the
2026-09-12 screenshot pass (`scripts/review_reported_sightlines.py`)
measured `p7-stroke-0` in half-unit strips against four source objects that
did not include the atrium wall itself (object 4912), so every strip only it
covered measured empty and stayed open, leaving centimetre holes along a
solid wall. The 2026-09-14 pass added 4912 for eleven strips and missed the
rest. All now block at 3.96 to 8.0 m. The other closures are the two
Fracture corridor openings and Haven defense's
`p3-stroke-10-gameplay-opening-0`, Mid Window, which had lost its sill; the
attack side's `p3-stroke-12-gameplay-opening-0` gets the same measured sill. The Haven, Icebox and Pearl
door and corridor openings stay open. The rulings are in the archive as
`scripts/data/truth-bands-dara-review-2026-10-03.json`.

### Holes in walls (2026-10-03)

The Abyss strips were one case of a general fault: earlier passes measured
walls in short strips against chosen objects, and a strip that missed them
stayed open. The archive's `scripts/truth/notch.py` finds every hole
directly. A hole is a piece no longer than a metre that is open over some
height while touching pieces on both sides of it are solid there, up to
40 m over its floor. Each is checked against every solid, non-decor face
within half a metre of the piece. Where the scene is solid over at least
80% of the hole, the hole is filled; where it is open, the hole stays and
is listed for review. A piece whose top is lower than its neighbours' is a
hole only when the scene is solid up to their height. Dara's rulings are
never touched. Across both sides of all maps it found 5,343 holes and
filled 4,096. The other 463 are open in the scene but are single pieces,
a few tens of centimetres wide, between solid walls; renders from the
standing spots that see them show mostly solid wall, its face more than
half a metre off the ink. A real window or doorway spans several pieces,
so these are filled too.

### Reviewed openings put back (2026-10-03)

The archive's acceptance suite (`scripts/truth/accept_at.sh`) holds the
sightlines earlier reviews pinned. On the #240 models 7 of its tests fail
(Split's crane, which #238 reverses, and fixture hashes); after the passes
above, 26 did. Astra cast every new failure against the complete 3D scene
(`scripts/truth/ray3d.py`) rather than a chosen object list. Six were clear
in the scene: the hole fill had closed a gap at Corrode's 4801 pieces.
Others contradicted a ruling or a recorded decision. `restore_reviewed.py`
puts these pieces back to their #240 bands, uncutting any `-truth-cut-N`
pieces:
- the two Corrode pieces;
- Haven's C Garage window walls, which Dara opened from the garage floor
  on 2026-09-19;
- Haven defense `p3-stroke-9`, whose raised band stopped a Mid sightline
  where the scene is clear;
- Icebox's zipline and ramp markings, which are symbols, not walls;
- every piece named see-through.

Seven failures remain, and each is deliberate. Four are the Haven Mid
Window sill Dara ruled solid. The other three, Icebox's front window jamb
and the boost-step box, pin sightlines the scene blocks.
`test/svg_truth_bands_test.dart` (now `svg_riot_vision_test.dart`) pinned the garage window. On the 3D check's
current standing spots (`poses-240.json`), the restore takes leaks from
5,565 spots and 100,106 rays to 5,679 and 104,153, mostly where the
garage ruling opens the window.

A rebuild of each drawn wall as two or three constant-height segments was
tried and not used (`scripts/truth/segment_walls.py` records why). It
removed 35k leak rays but added 160k false-shadow rays, because it closed
pieces the scene shows mostly open. It also shut reviewed openings that the
scene confirms are clear. One band set per piece cannot hold a window in
part of a piece, and a vote across neighbours makes that worse.

### Merged runtime outlines (2026-10-03)

Each model now carries `runtimeWalls`: the touching pieces that share a
floor, bands and unknown-height flag, merged offline into one outline by
the archive's `scripts/truth/merge_runtime.py`. Cones are cast against these
outlines, with 1.6 to 4 times fewer points than the pieces. The pieces remain
the model. The loader checks that every piece is covered once and that
every member of an outline has the same heights. Where an outline does not
cover a piece's own edges (a bow tie, a sliver), those edges come along
under the piece's heights (`heightsOf`). Merging seals cracks narrower than
0.06 SVG units (under 2 cm) between pieces of one wall and changes nothing
else; the cone areas it was checked on differ by at most 0.074%.

## Drag performance on Windows (2026-09-19)

Dara's bar: dragging an agent with a cone must feel instant on Windows.
Measured before the change, with the native query at the app's usual range
(about 140 SVG units): 1.44 ms in the native query, about 0.3 ms of Dart
around it, and a profile-build frame build time of 1.9 ms at the 90th
percentile. Windows frame timings report raster time as zero, so raster
was reasoned about rather than measured.

Changes, all exact (the polygon is bitwise the same):

* `native/height/icarus_svg_height.cpp` owns a small persistent thread pool.
  The arc rays, event generation and the event rays run in chunks across
  it; the polygon is assembled serially afterwards in the original order.
  Workers spin briefly between the runs of one query and sleep between
  frames. `ICARUS_HEIGHT_THREADS` overrides the worker count for diagnosis.
  (Removed 2026-10-05: the query now files the edges near the eye by angle
  once and casts each ray against its own bin, so casting is a tenth of the
  query and runs on the calling thread.)
* Event generation culls vertices outside the aperture before any trig.
* `SvgHeightVisibility` caches the wall activity mask per eye height.
* A native result keeps its packed doubles; the cone outline path is built
  from them directly, and the `polygon` list is only materialised on demand
  (reports, tests).
* The drag preview no longer sits in an `Opacity` widget. The cone paints at
  the preview alpha and only the small agent icon takes an opacity layer, so
  the engine does not composite the whole preview offscreen every frame.
* The receiver clip path is rotated and scaled once per drag and translated
  on the canvas, so the clip path object is stable across frames.

Instruments: `tool/svg_height_drag_bench_test.dart` and
`tool/svg_height_native_phase_bench_test.dart` (set
`ICARUS_SVG_NATIVE_LIBRARY` to the built `icarus_height.dll`),
`integration_test/view_cone_drag_performance_test.dart` and
`view_cone_drag_timeline_test.dart` under `flutter drive --profile -d windows`.

## How a cone is computed (2026-10-05)

A cone's outline is a fan of rays from the eye, joined by straight lines. It
is exact when every place the visible wall changes has a ray: each corner the
eye can see (with rays 1e-8 radians either side where the wall turns away),
each crossing of two strokes, and each wall's crossing of the range circle.
Rays aimed at corners nobody can see only add points in the middle of a wall
that is already in the outline. The query's job is to cast the first kind and
skip the second, without ever skipping the first.

Every ray starts at the same eye, so the query works in angles from it, the
way a 2D renderer does:

* **Angular bins.** The edges the eye may see are filed once per query into
  bins about 2π/2048 radians wide, each bin sorted nearest first. A ray tests
  only its own bin's edges and stops at the first one that starts beyond its
  hit. Ties go to the lowest edge id.
* **Depths proven by walls.** A run of consecutive edges along a wall ring that
  crosses a bin from one boundary to the next, without leaving the bin, is an
  unbroken wall across it. Every ray in the bin stops no farther than that
  run's farthest point there, so that is the bin's depth: a one-dimensional
  depth buffer whose values are proofs rather than samples.
* **Front-to-back culling.** The map's edge tree is walked nearest node first.
  A node, an edge or a corner that begins beyond the depth of every bin it
  spans is provably hidden and skipped: no filing, no events, no rays. Depths
  are re-proven as the walk gets twice as far out (four times, after the first
  wave), so nearby walls hide most of the map before it is touched.
* **Margins.** Every proof uses a margin far larger than the rounding in it
  (1e-9 in angle and relative distance). Anything the depths cannot rule out
  is tested exactly, as before.

Dart (the web) and `native/height` (desktop) run the same algorithm; native
runs on the calling thread, the old thread pool is gone.

Checked on 2026-10-05:

* Against the previous native query on a grid over all 26 map sides, three
  apertures and two ranges: 145,872 cones, none whose outline differs by more
  than 1e-5 SVG units. The comparison skips the 1e-8 sliver beside each
  silhouette, which any ray-built outline draws as a chord.
* `test/svg_cone_exact_test.dart` checks the outline between every pair of
  points against an exact ray on two busy maps and five tight spots, and fails
  if the hidden-corner test is made even 3% too eager.
* Per cone on Lotus and Breeze: rays fall from about 690 and 1,020 on
  average to about 290 and 260, edge tests from about 17,600 and 32,300 to
  about 2,000 and 1,400.
* Web, dragging a 103° cone at full length through Lotus and Breeze in Edge:
  the query's p99 went from 11–13 ms and 18 ms to 2.5 ms and 4.4 ms, and the
  worst query from 15–18 ms and 22 ms to about 3 ms and 6 ms.
* Native, over the same grid: p99 from 3.5 ms to 1.6 ms, p50 from 0.26 ms to
  0.18 ms.

The slowest cones left were full circles in open areas such as Breeze mid,
where the visible outline itself had some 2,800 corners. Most of those
corners were on traced curves; see the next section.

## Curves drawn with the points they need (2026-10-07)

A cone pays for every corner it can see, about 1.3 µs each natively, and the
curved walls were traced with a point every 0.03 units or so: the round wall
in Breeze mid was nearly a thousand points on a circle of radius 9, all within
0.008 of it. Summit, Pearl and Breeze drew 84–89% of their wall segments
shorter than 0.1 units.

`scripts/riot/simplify_walls.py` in the archive now runs after `build_art.py`.
A wall is redrawn only when simplifying at least halves its points and saves
at least 16, which picks out the traced curves (about 20 walls on each of the
heavy maps; none on Abyss or Ascent attack). A redrawn wall is simplified to
within 0.005 units and grown by 0.005, with mitres past right angles
bevelled, so:

* it covers every edge it had, so any ray the old wall stopped, it stops: no
  new leaks, and no crack can open between two walls;
* no point of its outline is more than 0.01 units from the old wall (the
  whole outline is checked, not just its corners);
* its heights, floor and id are unchanged.

A wall that would miss one of its old edges or stray further is kept as it
was, as is a wall drawn nonzero with more than one ring (none are today).
Wall points fall from 25,563 to 5,409 on Summit attack, 17,707 to 4,024 on
Pearl attack and 13,500 to 4,273 on Breeze attack.

Checked on 2026-10-07 against the previous models, the 360° cut from every
standable spot on an 8-unit grid over all 26 map sides (33,000 spots), each
compared along 20,000 directions:

* No direction on any map sees farther than before.
* At most 0.045% of directions on any map side see less (by more than 0.25
  units). The largest change at any spot is a 4.5° sliver on Lotus attack
  that now ends 0.1 units from the eye instead of 1.1.
* Native, worst 1% of 360° cuts: Pearl attack 3.8 → 0.8 ms, Summit attack
  3.1 → 1.0 ms, Breeze defense 2.9 → 0.8 ms. Maps without traced curves are
  unchanged.
* Dart (the query the web runs, timed in the test VM), worst 1% of 103°
  cones: Pearl attack
  8.7 → 0.7 ms, Breeze defense 4.4 → 0.8 ms, Summit defense 4.4 → 0.7 ms.

## Where a dragged agent stands (2026-10-07)

A cone is cast from where its agent stands: on the floor, with ground
beneath, and not within 0.05 of the ink of a wall that blocks a standing eye
there. An agent dropped in ink is stepped out (`standablePointNear`, every
frame of a drag): across the nearest edge of the wall it is in, or back onto
the floor across the floor's nearest edge, up to four steps, the last one's
landing checked. Among thin strokes those steps can circle, or cross an edge
with no floor on either side, and the agent got no cone: 3 to 40 spots on a
4-unit grid per map side with floor within reach.

Then the agent stands at the nearest point of the model's standable floor,
within the same 2.5 reach. `scripts/riot/standable_region.py` in the archive
builds it after `simplify_walls.py`, as `standable` in each model:

* the floor, cut by the ground into layers where the same walls block a
  standing eye, less each blocking wall's ink margin shaped as
  `_Footprint._contains` tests it;
* without strips narrower than 0.2 units (Pearl has floor 0.014 wide beside
  a wall) and pieces under 40 square units: the insides of props drawn as
  outlines, like a box on Breeze mid's round wall or a walled-in square on
  Ascent defense, where a cone sees nothing;
* drawn within 0.002 and shrunk by that and 1e-5, so its edge passes the
  standing test after rounding. The app checks the point anyway.

It adds 1,100 to 25,000 points per map side, 2 to 5% to the files. The steps
still run first, so every agent they place stands where it did.

Checked on 2026-10-07, every nudge on a 2-unit grid over six map sides
against main: none lost, none moved more than 0.017 (#256's walls stand
0.01 farther out), 6 to 254 more spots per side get a cone. Of 24 failing
points an independent review traced, 21 now stand within 0.015 of the
nearest standable point, or past a sliver or a prop's inside where that was
nearest; the other 3 have their nearest floor exactly 2.5 away. Points where
no cone is correct still get none. A nudge costs 9 to 11 µs at p50 and
87 to 104 µs at p99 in the test VM; the steps alone were 6 to 8 and 49 to 70.
