# Pearl visibility acceptance

Pearl passes the current visibility acceptance contract for the frozen
Valorant 13.05 source. Both measured assets are installed and match the Windows
profile bundle. The aggregate evidence is
`work/pearl-all-reviewed-v1/physical-levels/acceptance.json`.

## Source and gameplay decisions

The source inventory accounts for 8,741 nonempty scene meshes.
Of these, 6,724 have resolved exclusions. All remaining
2,017 mesh obligations and 900 collision bodies
were measured. No influencing collision record remains unresolved.
The reviewed result retains 2,061 physical standing domains.

Dara approved four upper faces as outside play. The map-wide collision body spans 28.4976–48.6261 m, satisfying the approval's approximate 29–49 m condition. Only the four standing domains were removed. The two A courtyard ground assemblies and nine slope assemblies supply 55 ordinary-ground domains.

The canonical decision is
[`pearl-playable-space-review.json`](../scripts/data/pearl-playable-space-review.json).
It binds the approved faces to source hashes. Collision bodies remain intact;
no global height cutoff or navigation-connectivity gate was added.
A separately measured smaller region, `work/pearl-b-hall-reviewed-v1`, matches
all 10 remaining source groups against the whole-map restriction.

## Delivered behavior

The source fixture contains 77,855 cases, 1,327 continuous ramp paths,
and 1,340 joins. Both artwork sides pass their runtime and saved-level checks;
origins outside the SVG floor or inside active painted walls are reported separately.
All 4,122 complete-domain comparisons pass. Independent expectations
were frozen from source before the candidate supplied actual results.

The production provider, placed-agent widgets, cache and painter pass
2,269 recorded checks, including automatic placement, side flips,
saved levels and pointer movement. All 3,711 recorded wall associations pass.
The compiled Windows library exported 2,808 cones;
an independent GEOS audit checked 597,975 boundary intervals
with zero flagged leaks or early cutoffs at 0.002 SVG units.

I inspected eight placed-agent captures and twelve production-painter views,
covering two source poses and an ordinary ramp on both sides, at normal scale
and enlarged wall contact. The cone contacts meet the painted wall edges.
The paired raster fields both contain the current cone; these images are not
before/after evidence. Images and selection records are under `work/pearl-all-reviewed-v1`.

Controls detect a missing source record, an unresolved source record, a removed
required floor and an incorrect local floor height. Artwork, wall footprints,
coordinates and retained collision bodies pass preservation checks.
Domain comparison tolerances are 0.02 m in height and 0.001 SVG units at boundaries;
source level equivalence is 0.00005 m.

## Cost and scope

| Side | Asset bytes | Measured queries | Median | p95 |
|---|---:|---:|---:|---:|
| Attack | 794,690 | 712 | 0.727 ms | 1.703 ms |
| Defense | 1,064,291 | 712 | 1.508 ms | 4.119 ms |

These costs include automatic standing selection and the native cone query in
Flutter test, with one warmup pass and two measured passes at every eligible
source placement. Sunset source measurements were running concurrently.
They do not measure desktop frame times. Pearl's initial stride-seven benchmark
had too few samples; the reported run uses stride one for all three maps.

Wall heights retain local measured stations and recorded gameplay decisions;
this is not continuous facade proof or new live-game observation. Standing eye
height remains the selected surface plus 1.75 m. Rounded capsule clipping is
conservative near curved boundaries. Crouching and dynamic map states are outside
this acceptance scope. No library schema or serialization path changed.

The aggregate and query-cost JSON files record the fixture, source, asset,
algorithm and native-library hashes needed to identify this result.
