# Breeze visibility acceptance

Later gameplay reports exposed an overhead standing choice and false facade
openings. See [the September 13 corrections](breeze-gameplay-sightlines-2026-09-13.md).
The older source accounting below does not establish those gameplay assignments.

Completed and installed on September 10. The aggregate delivery verifier passes
for both artwork sides, including complete source accounting, domain comparison,
runtime selection, the Windows app, native contacts and negative controls.
Dara's approved ceiling exclusion removes exactly its upper standing face;
the blocking body remains. The final source has 3,961 standing domains.

The final evidence is
`work/breeze-all-reviewed-v2/physical-levels-v4/acceptance.json`.

## Source accounting

The independent inventory covers 6,795 nonempty meshes. Source settings and
verified empty collision exclude 5,079; the remaining 1,716 require physical
measurement. The full region also contains 835 volume-body obligations.

Missing native instance transforms and collision exports have been recovered
from the pinned source revision. The final source work is
`work/breeze-all-v4`; an independent smaller region around A's oxygen tanks is
`work/breeze-a-tanks-v2`.

The last four unresolved capsules now have complete geometric dispositions.
The two oxygen-tank capsules are wholly inside player-blocking volume 332, with
minimum insets of 0.109729 m and 0.085675 m. Their slightly nonuniform scaling
made the previous enclosing-sphere proof too coarse. The exact engine-scaled
capsules fit. The two ship capsules have complete bounds over 205 m outside the
full region, beyond the player's 0.42 m radius.

The capsule verifier independently reconstructs outward planes from the archived
closed convex triangles and checks the furthest capsule point against every
plane. It also checks the complete bounds of the distant capsules. Both regions
pass. The smaller region's 29 relevant colliders match the full scene exactly.
Four focused controls cover scaling, protruding capsules, curved extrema and
regional influence. Existing standing and source-accounting regressions pass.

An initial diagnostic incorrectly treated the enclosing volume only as a triangle
boundary. The subsequent solid-interior check corrected that result. Both tanks
add no collision boundary or standing floor. No curved standing approximation or
new runtime geometry was introduced.

## Wall associations

All 3,325 current wall associations pass their frozen source and gameplay
decisions. Recovered evidence identifies 238 local boundary sections and one
finite-prop decision. This establishes the recorded local measurements, not a
continuous facade measurement or new live-game observation.

The wall decision source is
`tactical-visibility-revision/breeze-svg-height-decisions-v1/breeze-svg-height-decisions-v1.json`
under the pinned source export. The baseline wall report is
`work/breeze-all-v4/wall-preflight/regional-wall-comparison.json`.

## Approved ceiling review

Volume 21, `/Foxtrot_BVPawn/BP_BlockingVolume38/Cube#0`, is a map-wide
player-blocking body from approximately 19 m to 51 m. Its completed measurement
contains one standing domain, `volume-21-0`, at 51 m with an area of
13,762.255712 square metres. Physical contact and clearance alone retain this
upper face. Dara confirmed on September 10 that it is outside playable space,
even allowing agent abilities.

The [private Breeze review view](https://bind-ceiling-inspector.daradoescode.chatgpt.site/breeze/)
shows that exact face in red, the blocking body in cyan, and opaque source map
geometry in gray. It preserves placement and scale, with display rounding below
1 mm. Overview, side, top and cutaway controls were inspected. The view has no
game textures and does not establish live-game accessibility.

The frozen question is
`work/breeze-acceptance-preflight/ceiling-review-question.json`, SHA-256
`dd8466e49b242bb1a2a99473e275e23f6d113eeb589653ec03696cca8753ea79`.
It binds the completed ceiling checkpoint, full collider inputs, inventory and
displayed scene. The final measured ceiling domain equals that frozen domain.
The canonical approved decision is `scripts/data/breeze-playable-space-review.json`.
Application removes exactly one complete domain and preserves the collision
body, every other standing domain and the recorded gameplay samples. No height
cutoff is applied.

The source contains 3,954 raw domains. The seven September 8 samples add eight
reviewed domains; the ceiling exclusion leaves 3,961. The independent tank
region agrees with the full result in all 43 comparison groups. Exact clipping
retains a regional boundary remainder of 8.55e-10 square metres, below the
comparison's 1e-8 square-metre tolerance.

## Floor boundary correction

The first candidate lost a source level at an A cave ramp join and another at
a cave floor boundary. The ground lookup returns the first covering triangle;
planned ground polygons do not establish that the baked triangles supply the
same level. Reconciliation now credits only emitted ground owned by that first
triangle and retains explicit source choices along the two-step overlay
rounding boundary. This narrows ground coverage credit without expanding any
source standing domain. Ground triangles, runtime lookup, walls and receivers
remain unchanged by this correction.

Twelve compiler checks cover omitted triangles, hidden physical ground, rounded
edges and existing floor behavior. The final candidate is
`work/breeze-all-reviewed-v2/physical-levels-v4`. Both sides run 120,619 runtime
cases. Attack has 91,737 applicable passes and defense 91,738; each has 28,794
positions outside SVG floor, with 88 and 87 positions inside active walls.
Saved-level checks pass at 2,116 applicable source placements per side; 1,844
are outside the SVG and one is inside a wall. Four isolated floor and height
faults are detected with unchanged source expectations.

## Windows app and native contact

All 7,922 whole-domain checks pass, covering availability and default selection
for each domain on both artwork sides. The preservation check binds every
ground triangle to its source parent, with maximum vertex-height error below
9.7e-14 m and parent-area error below 5.2e-8 SVG square units.

The Windows profile build succeeded and contains the exact installed candidate
bytes. The production provider, placed-agent widget, movement path, cone cache
and painter pass 16,753 checks: 14 primary placements, one pointer drag, 4,234
source-domain defaults, 4,232 saved source levels, 8,204 saved ramp levels and
68 pointer moves across ramp joins. Maximum eye-height error is 0.00005 m.

The compiled Windows library emitted 16,984 cones from 31,744 requested cases.
It recorded 14,752 origins outside the SVG floor or ground domain and eight
inside active walls. The independent GEOS audit checked 3,831,397 polygon
intervals with zero flagged cones or intervals at 0.002 SVG units. The audit
uses bounded parallel batches with source and output hashes on every checkpoint.

All twelve production painter views were personally inspected. They cover
defender spawn, the A-path cave rock and the A cave ramp on both artwork sides,
at normal size and enlarged wall contact. Selected cone edges meet the SVG ink;
the cave opening and its wall-corner shadow remain visible.

Four placed-agent captures were also inspected. The first attack capture has a
placeholder portrait and establishes placement and cone appearance only. The
other three show Jett. The attacker-spawn rock capture on the defender artwork
faces outside the SVG floor, so its cone is clipped away. Image hashes and
observations are in `physical-levels-v4/visual-inspection.json`. The raster
tool's before and current fields contain the same delivered cone.

## Size and query cost

The compressed assets total 6,768,925 bytes. Attack SHA-256 is
`e7bad6c182f1eb18a90c4863ba406cd8041e9743c56bfb4a1ae3196ef4ecb6fe`;
defense is `cb34817a9739dea6c91b50353ec25113f1b1ecde8e49850f91c12aebd23237cf`.

The benchmark uses 302 source placements per side, one warmup pass and two
measured passes. Median selection-plus-native-query cost is 0.734 ms on attack
and 0.984 ms on defense; respective p95 costs are 1.405 ms and 2.529 ms. Maxima
are 5.691 ms and 8.977 ms. Loading and native setup take about 424 ms and 417 ms.
These are Flutter test-process query costs, not desktop frame times.

## Reproduction and limits

```powershell
& E:/IcarusWorldAudit/2026-09-06/venv/Scripts/python.exe scripts/verify_icebox_physical_delivery.py `
  --source work/breeze-all-reviewed-v2 `
  --candidate-dir work/breeze-all-reviewed-v2/physical-levels-v4 `
  --fixture test/fixtures/breeze_regional_standing.json `
  --boundaries work/breeze-all-reviewed-v2/boundaries `
  --walls work/breeze-all-reviewed-v2/regional-wall-comparison.json `
  --regional-source work/breeze-a-tanks-reviewed-v2 `
  --app-fixture test/fixtures/breeze_vision_acceptance.json
```

This covers the declared static source revision with standing eyes 1.75 m above
the selected floor. Rounded capsule clipping remains conservative near curved
boundaries. Crouching, changing doors and other dynamic map states, and new
live-game observations are outside scope. Breeze has no outstanding decision
from Dara. Fracture's source accounting continues separately.
