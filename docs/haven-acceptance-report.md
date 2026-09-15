# Haven visibility acceptance

The user screenshot review supersedes this baseline's tower standing default
and Mid Window height assignment. See
[the current correction report](reported-sightlines-2026-09-12.md) for those changes
and their source, runtime, and delivery checks.

Haven passes the current visibility acceptance contract. Both measured height
assets are installed in the workspace and match the Windows profile bundle.
The aggregate result is `work/haven-all-reviewed-v1/physical-levels/acceptance.json`.
The checks establish source accounting, application selection and rendering
within the stated scope. They do not establish new live-game observations.

The source inventory accounts for all 7,953 nonempty scene meshes. It requires
measurements for 2,656 meshes and 558 volume bodies, all completed with no
unresolved influencing collision. The raw measurement produced 1,765 standing
domains. Applying Dara's September 8 review adds seven local domains, giving
1,772. Those gameplay decisions remain separate from collision measurements.
No additional playable-space exclusion was needed.

The independent B/Mid source measurement has 30 domain groups. All match the
whole-map restriction within 0.01 mm at boundaries and 0.00000001 m² in area.
The bake places 785 measured or reviewed floor domains into ground. Attack has
27,982 ground triangles, including 11,338 certified physical triangles, and
1,766 selectable supports. Defense has 27,970 ground triangles, including
11,323 certified physical triangles, and 1,764 supports. The original SVG
artwork, painted wall footprints and receiver geometry are preserved.

| Check | Result |
|---|---|
| Complete source floor domains and defaults | 3,544 checks passed |
| Wall source associations | 3,615 checks passed |
| Runtime cases on each side | 55,287 passed; 6,275 outside the SVG floor; 211 inside an active wall |
| Saved source levels on each side | 1,584 passed; 179 outside the SVG floor; nine inside an active wall |
| Production placed-agent integration | 10,101 checks passed, including source defaults, saved levels and pointer movement |
| Native cone contacts | 12,752 cones; 2,357,570 intervals; no flagged contacts at 0.002 SVG units |
| Fault controls | Removed surfaces and 25 cm height errors detected on both sides; missing and unresolved inventory records rejected |

The app fixture uses seven distinct positions from Dara's reviewed Mid floor
samples. The wider source fixture contains 1,772 default placements, 765 ramp
paths and 1,049 joins. The application checks include 3,170 source defaults,
3,168 saved source levels, 3,712 saved ramp levels and 36 pointer-join checks.
The maximum measured eye-height error is 0.0457 mm.

All twelve current production painter views were personally inspected, along
with four of the fourteen placed-agent captures. The reviewed Mid poses meet
the facing vertical wall edge on both artwork sides. The Mid ramp view meets
the horizontal stroke and retains the protruding obstacle's corner shadow.
The enlarged contacts show no visible gap. The short cone at the first pose
is obscured by the portrait at full-map scale and is visible in the enlarged
painter view. The first attack capture has a placeholder portrait. Exact image
hashes and the inspected subset are in `physical-levels/visual-inspection.json`.
The raster inputs labelled before and current contain the same current cone;
they are contact inspections, not a revision comparison.

The compressed assets total 3,534,284 bytes. Sampling every seventh source
placement provides 231 positions and 462 measured queries per side after one
warmup pass. Attack median/p95 costs are 0.745/1.606 ms, with a 4.778 ms maximum.
Defense median/p95 costs are 1.060/2.449 ms, with a 3.305 ms maximum. These include
automatic standing selection and the compiled Windows native query in a Flutter
test process. They are not desktop frame timings.

The installed attack asset SHA-256 is
`44f89047d6fbb3bce1556c5dbc8573e539eefecd5fc7872f5d6ffe043151a259`.
Defense is `bc64771fc956c14ac61ec2fad9ef928ddc353855b2a05dce0f00f3aba4dc64d2`.
The Windows native library is unchanged. This Haven acceptance pass changes
height assets and offline evidence, with no library schema or serialization change.

Recheck the aggregate result with:

```powershell
python scripts/verify_icebox_physical_delivery.py `
  --source work/haven-all-reviewed-v1 `
  --candidate-dir work/haven-all-reviewed-v1/physical-levels `
  --fixture test/fixtures/haven_regional_standing.json `
  --boundaries work/haven-all-reviewed-v1/boundaries `
  --walls work/haven-all-reviewed-v1/regional-wall-comparison.json `
  --regional-source work/haven-b-mid-reviewed-v1 `
  --app-fixture test/fixtures/haven_vision_acceptance.json
```

Wall heights retain local source stations and existing gameplay decisions;
this is not a continuous proof of every facade point. Standing eyes use the
selected surface plus 1.75 m approximation. Crouching, changing map states and
new live-game certification remain outside this pass. No decision from Dara
is pending for Haven.
