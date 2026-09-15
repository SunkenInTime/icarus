# Fracture visibility acceptance

Fracture passes the current visibility acceptance contract. Both measured assets
are installed and match the Windows profile bundle. Dara's approved ceiling
exclusion applies to the exact upper face, with its collision body retained.
The aggregate result is
`work/fracture-all-reviewed-v2/physical-levels/acceptance.json`.

## Source accounting

The Valorant 13.05 source inventory covers all 5,761 nonempty scene meshes.
It excludes 4,123 through resolved collision settings or explicit empty-shape
evidence. The other 1,638 meshes and 636 player-volume bodies are accounted
for in the standing audit. No influencing collision record remains unresolved.

The source is `work/fracture-all-v5`. All 15 extracted native level-property
files match the previously audited source hashes. Five referenced component
templates resolve inherited collision settings. The fresh collision export
contains 120 mesh packages, with no parser errors and unchanged property bytes.

Three vine instances request player collision but have neither aggregate shapes
nor cooked formats. The extractor now records each body's cooked-format list
explicitly. An absent sidecar alone remains insufficient evidence; malformed
indexes, mismatched source properties and changed payload bytes still fail.

The broom has both a box and a locally rotated capsule. Its complete box lies
2.566 m inside a resolved player blocker. A conservative sphere containing its
entire capsule lies 2.394 m inside that same blocker. Both parts must pass before
the body is excluded. Unknown accompanying shapes stay unresolved. A second
capsule, on source object 4714, lies 1.014 m inside another player blocker.

An independent verifier reconstructed the containing boundaries from archived
triangles and passed all three shape checks. Regression controls reject an
omitted box, changed vertices, a shrunken capsule bound, exposed shapes, sheared
placement and a kill volume used as an enclosing player blocker. The targeted
source and containment suites pass 22 tests. These checks establish source
accounting and containment, not correctness of the delivered application.

## Standing measurements and gameplay review

The whole-map audit completed all 2,274 source obligations. It found 4,903
physical standing domains across 398 source records; 1,876 records have no
clear standing domain. The two earlier gameplay corrections add two domains.
Removing the reviewed ceiling leaves 4,904 domains.

A separate B-tunnel measurement at attack SVG bounds `[146, 150, 170, 175]`
found seven physical standing domains. The earlier gameplay review adds one
domain and the ceiling decision removes one. All seven remaining source
groups match the whole-map restriction within 0.01 mm at boundaries and
0.00000001 m² in area.

Both earlier Fracture gameplay samples remain independent expectations. They
cover the B-tunnel floor and the A-site sloped metal floor. Their measured
collision heights remain separate from the rendered mesh heights.

The ceiling question concerns exactly `volume-507-0`, the upper face of
`/Canyon_BVPawn/BP_BlockingVolume242/Cube#0`. Its measured plane is 74.5399 m
above source zero and its standing domain covers 16,405.049 m². The collision
body extends from about 20.43 m to 74.54 m. This face was measured using the
same complete collider set, algorithm and region as the whole-map
audit. No global height cutoff has been applied.

The [private 3D viewer](https://bind-ceiling-inspector.daradoescode.chatgpt.site/fracture/)
shows that exact red standing domain and the cyan collision body among
1,546,899 opaque context triangles. All 18 compressed geometry payloads passed
hash and triangle-count checks. Display conversion error is below 1 mm.
The overview, side, top and cutaway views were personally inspected.

The frozen question and source measurement are in
`work/fracture-ceiling-question-v1/playable-space-question.json` and
`ceiling-measurement.json`. On September 10, Dara answered, "Yes, that upper
face is outside play." The canonical decision in
`scripts/data/fracture-playable-space-review.json` binds that answer to the
completed source. Its domain matches the displayed measurement exactly.
Applying it removes one complete domain and clips none. Both collision files
retain their original hashes.

The wall preflight passes all 3,365 records. Recovering omitted source-face
references resolved 106 local sections and four finite-prop decisions from
the frozen source. No wall footprint or height changed. This rechecks the
existing source associations and gameplay decisions; it is not a new live-game
review of those openings.

## Delivered checks

The bake places 562 measured or reviewed ordinary floor domains into ground.
Attack has 20,915 ground triangles, including 7,039 certified physical triangles.
Defense has 20,917, including 7,037 certified physical triangles. Both sides
retain 2,296 selectable supports. Preservation checks confirm the original
painted wall footprints, receiver geometry and unaffected data.

| Check | Result |
|---|---|
| Complete floor domains and defaults | 9,808 checks passed |
| Runtime cases on each side | 93,672 passed; 120,689 outside the SVG floor; 2,379 inside an active wall |
| Saved source levels on each side | 1,907 passed; 2,966 outside the SVG floor; 31 inside an active wall |
| Placed-agent integration | 13,075 checks passed, including four saved lower references, source levels, ramp paths and pointer movement |
| Native contacts | 15,272 cones; 3,503,180 intervals; no flagged contacts at 0.002 SVG units |
| Fault controls | Removed surfaces and 25 cm height errors detected on both sides; missing and unresolved inventory records rejected |

The source inventory covers the entire extracted map, including standing
domains outside the SVG floor. Those domains remain accounted for, but the
application does not draw cones outside its authored receiver area. The maximum
measured application eye-height error is 0.0499 mm.

All twelve current production painter views and all four placed-agent captures
were personally inspected. The B-tunnel pose retains its opening and neighboring
corner shadows. The A metal pose clears low interior strokes and meets the outer
edge. The ordinary ramp retains its curved edge and notch shadow. Enlarged
contacts show no visible gap. The full-map app captures face nearby walls or out
of the SVG floor, so no cone is separately visible beyond the portrait. The
first attack capture has a placeholder portrait. Image hashes and observations
are in `physical-levels/visual-inspection.json`. Raster fields labelled before
and current contain the same current cone, not different revisions.

The assets total 3,952,807 compressed bytes. The repeat timing run samples 272
source positions and 544 measured queries per side after a warmup pass. Attack
median/p95 costs are 0.875/1.804 ms, with a 3.827 ms maximum. Defense median/p95
costs are 1.744/4.218 ms, with an 8.026 ms maximum. These include automatic level
selection and the native cone query in a Flutter test process, not desktop frame
times. An earlier run overlapped multiple source workers and rendering; its
102 ms maximum did not reproduce after that contention subsided. Both runs
are retained in `physical-levels/query-cost*.json`.

The installed attack asset SHA-256 is
`69a122b677c5ccc3b94e23ea2b3ce217ba68e962e632d337aa9d3a3a560bb2dc`.
Defense is `4556cfde73d0c9b11ff3478a4495c906f94307bf37e65886629a40c16ffde890`.
The native Windows library is unchanged. No library schema, serialization or
runtime visibility implementation changed during this Fracture acceptance pass.

Recheck the aggregate result with:

```powershell
python scripts/verify_icebox_physical_delivery.py `
  --source work/fracture-all-reviewed-v2 `
  --candidate-dir work/fracture-all-reviewed-v2/physical-levels `
  --fixture test/fixtures/fracture_regional_standing.json `
  --boundaries work/fracture-all-reviewed-v2/boundaries `
  --walls work/fracture-all-reviewed-v2/regional-wall-comparison.json `
  --regional-source work/fracture-b-tunnel-reviewed-v2 `
  --app-fixture test/fixtures/fracture_vision_acceptance.json
```

Local source stations and the recorded gameplay opening decisions remain the
wall-height evidence. This is not a continuous proof of every facade point or
new live-game certification. Standing eyes use selected support plus 1.75 m;
crouching and changing map states remain outside this pass. No Fracture decision
from Dara is pending.
