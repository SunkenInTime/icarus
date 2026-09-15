# Corrode visibility acceptance

Corrode passes the current visibility acceptance contract for the frozen
Valorant 13.05 source. Both measured assets are installed and match the Windows
profile bundle. The aggregate evidence is
`work/corrode-all-reviewed-v1/physical-levels/acceptance.json`.

## Source and gameplay decisions

The source inventory accounts for 7,603 nonempty scene meshes.
Of these, 7,529 have resolved exclusions. All remaining
74 mesh obligations and 1,142 collision bodies
were measured. No influencing collision record remains unresolved.
The reviewed result retains 549 physical standing domains.

Dara approved only volume-1026-0, the 43.3816 m upper face of BP_BlockingVolume692, as outside play. The defender-spawn ground assembly and 37 slope assemblies supply 52 ordinary-ground domains. Other measured domains remain selectable supports.

The canonical decision is
[`corrode-playable-space-review.json`](../scripts/data/corrode-playable-space-review.json).
It binds the approved faces to source hashes. Collision bodies remain intact;
no global height cutoff or navigation-connectivity gate was added.
A separately measured smaller region, `work/corrode-ramp-region-v1`, matches
all 5 remaining source groups against the whole-map restriction.

## Delivered behavior

The source fixture contains 38,351 cases, 84 continuous ramp paths,
and 124 joins. Both artwork sides pass their runtime and saved-level checks;
origins outside the SVG floor or inside active painted walls are reported separately.
All 1,098 complete-domain comparisons pass. Independent expectations
were frozen from source before the candidate supplied actual results.

The production provider, placed-agent widgets, cache and painter pass
1,925 recorded checks, including automatic placement, side flips,
saved levels and pointer movement. All 3,315 recorded wall associations pass.
The compiled Windows library exported 2,736 cones;
an independent GEOS audit checked 643,592 boundary intervals
with zero flagged leaks or early cutoffs at 0.002 SVG units.

I inspected eight placed-agent captures and twelve production-painter views,
covering two source poses and an ordinary ramp on both sides, at normal scale
and enlarged wall contact. The cone contacts meet the painted wall edges.
The paired raster fields both contain the current cone; these images are not
before/after evidence. Images and selection records are under `work/corrode-all-reviewed-v1`.

Controls detect a missing source record, an unresolved source record, a removed
required floor and an incorrect local floor height. Artwork, wall footprints,
coordinates and retained collision bodies pass preservation checks.
Domain comparison tolerances are 0.02 m in height and 0.001 SVG units at boundaries;
source level equivalence is 0.00005 m.

## Cost and scope

| Side | Asset bytes | Measured queries | Median | p95 |
|---|---:|---:|---:|---:|
| Attack | 567,622 | 684 | 0.775 ms | 4.298 ms |
| Defense | 625,568 | 684 | 1.162 ms | 2.531 ms |

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
