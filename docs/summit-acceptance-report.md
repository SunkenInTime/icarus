# Summit visibility acceptance

Summit passes the current visibility acceptance contract for the frozen
Valorant 13.05 source. Both measured assets are installed and match the Windows
profile bundle. The aggregate evidence is
`work/summit-all-reviewed-v1/physical-levels/acceptance.json`.

## Source and gameplay decisions

The source inventory accounts for 7,403 nonempty scene meshes.
Of these, 7,179 have resolved exclusions. All remaining
224 mesh obligations and 1,078 collision bodies
were measured. No influencing collision record remains unresolved.
The reviewed result retains 436 physical standing domains.

Dara confirmed that volume-0-0 at 65 m and volume-328-0 at 42.75 m are outside play even with abilities. Only these two upper faces were removed. Their collision bodies, spanning 33.25–65 m and 10–42.75 m respectively, remain intact. Forty-six measured domains on the Sage room floor and defender-spawn ramp supply the ordinary-ground classification; other measured domains remain selectable supports.

The canonical decision is
[`summit-playable-space-review.json`](../scripts/data/summit-playable-space-review.json).
It binds the approved faces to source hashes. Collision bodies remain intact;
no global height cutoff or navigation-connectivity gate was added.
A separately measured smaller region, `work/summit-ramp-region-reviewed-v1`, matches
all 3 remaining source groups against the whole-map restriction.

## Delivered behavior

The source fixture contains 31,626 cases, 29 continuous ramp paths,
and 34 joins. Both artwork sides pass their runtime and saved-level checks;
origins outside the SVG floor or inside active painted walls are reported separately.
All 872 complete-domain comparisons pass. Independent expectations
were frozen from source before the candidate supplied actual results.

The production provider, placed-agent widgets, cache and painter pass
971 recorded checks, including automatic placement, side flips,
saved levels and pointer movement. All 2,957 recorded wall associations pass.
The compiled Windows library exported 1,720 cones;
an independent GEOS audit checked 552,575 boundary intervals
with zero flagged leaks or early cutoffs at 0.002 SVG units.

I inspected eight placed-agent captures and twelve production-painter views,
covering two source poses and an ordinary ramp on both sides, at normal scale
and enlarged wall contact. The cone contacts meet the painted wall edges.
The paired raster fields both contain the current cone; these images are not
before/after evidence. Images and selection records are under `work/summit-all-reviewed-v1`.

Controls detect a missing source record, an unresolved source record, a removed
required floor and an incorrect local floor height. Artwork, wall footprints,
coordinates and retained collision bodies pass preservation checks.
Domain comparison tolerances are 0.02 m in height and 0.001 SVG units at boundaries;
source level equivalence is 0.00005 m.

## Cost and scope

| Side | Asset bytes | Measured queries | Median | p95 |
|---|---:|---:|---:|---:|
| Attack | 708,779 | 430 | 0.897 ms | 3.436 ms |
| Defense | 861,340 | 430 | 1.772 ms | 6.100 ms |

These costs include automatic standing selection and the native cone query in
Flutter test, with one warmup pass and two measured passes at every eligible
source placement. Sunset source measurements were running concurrently.
They do not measure desktop frame times.

Wall heights retain local measured stations and recorded gameplay decisions;
this is not continuous facade proof or new live-game observation. Standing eye
height remains the selected surface plus 1.75 m. Rounded capsule clipping is
conservative near curved boundaries. Crouching and dynamic map states are outside
this acceptance scope. No library schema or serialization path changed.

The aggregate and query-cost JSON files record the fixture, source, asset,
algorithm and native-library hashes needed to identify this result.
