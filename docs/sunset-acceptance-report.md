# Sunset visibility acceptance

Sunset passes the visibility acceptance contract for the frozen Valorant 13.05
source. Both measured assets are installed in the workspace and match the
Windows profile bundle. The aggregate result is
`work/sunset-all-reviewed-v1/physical-levels/acceptance.json`.

## Source and gameplay decisions

The inventory accounts for 7,764 nonempty scene meshes.
Of these, 6,661 have resolved exclusions. All
1,103 mesh obligations and
695 collision bodies were measured, with no
unresolved influencing collision records. The reviewed source retains
10,752 standing domains.

Dara approved the 190 highlighted standing domains on fourteen defender-spawn
scenery objects as outside play, even with abilities. These include sinkhole
pillars, walls, cliffs and three pipe sections. Only the exact reviewed standing
domains were excluded. All collision bodies and other measured domains remain.
The canonical record is
[`sunset-playable-space-review.json`](../scripts/data/sunset-playable-space-review.json).

The review used completed measurements for those fourteen objects while the
separate road measurement continued. The final source-equivalence check proved
that all 190 reviewed domain records match the completed whole-map measurement
exactly. The road added eight domains and introduced no new low scenery overlap
requiring gameplay review. No global height cutoff was added.

Forty-four measured domains on twenty-four player-blocking slope assemblies
supply ordinary ground. Other measured domains remain selectable supports.
A separately measured ramp region matches all five source groups against the
whole-map restriction at a 0.00001 m boundary tolerance.

## Delivered behavior and verification

The source fixture contains 177,027 cases, 4,192
continuous ramp paths and 7,320 joins. Both artwork sides pass
runtime and saved-level checks. Cases outside the SVG floor or inside active
painted walls are reported separately. All 21,504 complete-domain
comparisons pass. Expected heights come from the independent source measurements.

The production provider, placed-agent widgets, cache and painter pass
855 recorded checks, covering automatic placement, side flips,
saved levels and pointer movement across three ordinary ramp joins. All
2,379 wall associations pass. The Windows native library
exported 1,280 cones; the independent GEOS audit checked
235,478 boundary intervals with zero flagged leaks
or early cutoffs at 0.002 SVG units.

I inspected eight placed-agent captures and twelve production-painter views
covering two source poses and an ordinary ramp, on both sides, at normal scale
and enlarged contact. No contact discontinuity was found. The initial app capture
shows an agent placeholder; the other captures show the decoded agent icon.
Both raster fields contain the current cone, so these are not before/after images.
The images and their source selections are under `work/sunset-all-reviewed-v1`.

Fault controls detect missing and unresolved source records, a removed required
floor, and an incorrect local floor height. Artwork, wall footprints, coordinates
and retained collision bodies pass preservation checks. Domain comparisons use
0.02 m height and 0.001 SVG-unit boundary tolerances; source level equivalence
uses 0.00005 m.

## Cost and scope

| Side | Asset bytes | Measured queries | Median | p95 |
|---|---:|---:|---:|---:|
| Attack | 642,322 | 326 | 0.587 ms | 1.186 ms |
| Defense | 741,216 | 326 | 0.824 ms | 2.085 ms |

These timings include automatic standing selection and the Windows native cone
query in Flutter test, with one warmup pass and two measured passes at all 163
eligible source placements per side. They do not measure desktop frame times.

This establishes the stated source revision and tested application behavior,
not new live-game certification or continuous facade proof. Wall heights retain
local source stations and recorded gameplay decisions. Standing eye height is
the selected surface plus 1.75 m. Rounded capsule clipping is conservative near
curved boundaries; crouching and dynamic map states remain outside scope.
No library schema or serialization path changed.

The aggregate and query-cost records identify source, fixture, asset, algorithm
and native-library hashes. The verified Windows profile bundle is ready for
local review; this work did not publish a release.
