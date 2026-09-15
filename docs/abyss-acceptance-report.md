# Abyss visibility acceptance

This records the September 12 baseline acceptance for the frozen Valorant
13.05 source. The subsequent user screenshot review corrected several standing
defaults and openings; see [the current correction report](reported-sightlines-2026-09-12.md).
The baseline aggregate evidence is
`work/abyss-all-reviewed-v1/physical-levels/acceptance.json`.

## Source and gameplay decisions

The source inventory accounts for 7,511 nonempty scene meshes.
Of these, 6,835 have resolved exclusions. All remaining
676 mesh obligations and 1,698 collision bodies
were measured. No influencing collision record remains unresolved.
The reviewed result retains 717 physical standing domains.

Dara approved 15 collision-volume tops and 269 scenery/cliff domains across ten scene meshes as outside play. All 284 exact standing domains were removed. Fifty measured domains on ordinary floor and slope collision assemblies supply ground presentation. The smaller-region replay exposed a subtraction sliver about 0.03 micrometres wide; using the measurement's existing 0.1 micrometre precision grid removed it. Regression controls distinguish that rounding residue from a real 10 micrometre extension.

The canonical decision is
[`abyss-playable-space-review.json`](../scripts/data/abyss-playable-space-review.json).
It binds the approved faces to source hashes. Collision bodies remain intact;
no global height cutoff or navigation-connectivity gate was added.
A separately measured smaller region, `work/abyss-floor365-region-reviewed-v2`, matches
all 1 remaining source groups against the whole-map restriction.

## Delivered behavior

The source fixture contains 72,467 cases, 508 continuous ramp paths,
and 367 joins. Both artwork sides pass their runtime and saved-level checks;
origins outside the SVG floor or inside active painted walls are reported separately.
All 1,434 complete-domain comparisons pass. Independent expectations
were frozen from source before the candidate supplied actual results.

The production provider, placed-agent widgets, cache and painter pass
1,463 recorded checks, including automatic placement, side flips,
saved levels and pointer movement. All 1,558 recorded wall associations pass.
The compiled Windows library exported 2,352 cones;
an independent GEOS audit checked 207,122 boundary intervals
with zero flagged leaks or early cutoffs at 0.002 SVG units.

I inspected eight placed-agent captures and twelve production-painter views,
covering two source poses and an ordinary ramp on both sides, at normal scale
and enlarged wall contact. The cone contacts meet the painted wall edges.
The paired raster fields both contain the current cone; these images are not
before/after evidence. Images and selection records are under `work/abyss-all-reviewed-v1`.

Controls detect a missing source record, an unresolved source record, a removed
required floor and an incorrect local floor height. Artwork, wall footprints,
coordinates and retained collision bodies pass preservation checks.
Domain comparison tolerances are 0.02 m in height and 0.001 SVG units at boundaries;
source level equivalence is 0.00005 m.

## Cost and scope

| Side | Asset bytes | Measured queries | Median | p95 |
|---|---:|---:|---:|---:|
| Attack | 595,180 | 590 | 0.343 ms | 0.839 ms |
| Defense | 664,543 | 590 | 0.644 ms | 1.693 ms |

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
