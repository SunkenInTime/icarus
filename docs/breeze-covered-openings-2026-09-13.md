# Breeze covered openings

The follow-up screenshots expose two different errors associated with roofs.
The canonical source decisions are in
`scripts/data/breeze-covered-openings-2026-09-13.json`.

## What went wrong

The first screenshot is near attack SVG [49,314], inside the Courtyard Window
room. Two adjacent collision slabs, volume-387-0 and volume-388-0, supplied
automatic standing tops at 10.75 m above the actual 4 m interior floor. Their
bodies span 8.5 to 10.75 m. The physical-top builder established a clear collision
top, but that alone did not establish the appropriate gameplay floor inside
the room. Both connected tops are excluded; their collision bodies remain.

The second screenshot is near [193,115], inside the Mid Nest window room.
Its 9 m floor was correct. The local wall-profile compiler spread nearby roof
and frame heights across the window's SVG stroke using nearest-source cells.
The few cells assigned low cover remained transparent, producing the tiny gap.
The same parent also contains two exterior box outlines. Their roles must be
handled separately from the window and roof.

The screenshot positions are approximate registrations. The tests cover areas
and movement paths around them rather than assuming an exact cursor pixel.

## Correction and evidence

`scripts/review_breeze_covered_openings.py` measures complete local source
assemblies in sections no wider than 0.25 SVG units. It retains a single opening
between each sill and header, fills construction seams above the header, and
keeps solid end frames. Source geometry, metadata, alignment, standing input,
and baseline assets are pinned by hash.

The Courtyard opening has a source sill near 5.10 m and header near 7.90 m.
It is open across roughly x=38..59. The Nest opening has a sill near 9.03 m
and header near 14.40 m, across roughly x=184..203. These measurements are
independent of the previous wall-height assignments.

The exterior box outlines use their own complete source objects, WoodBox_9
and Prop_0_PirateCrateA. Their standing collision heights remain about 7.00 m
and 7.99 m. The taller crate blocks sight from the 6 m exterior floor and lies
below the upper room's standing eye.

Correcting these walls also restores the portions of measured standing domains
115, 307 and 656 that the old opaque assignments had clipped away. This includes
the first window sill. Existing ground triangles and floor-fill geometry remain
unchanged.

Defense-side testing exposed a second implementation issue in the review
builder: a reflected clip stopped one floating-point step short of an existing
wall fragment only about 5e-14 SVG units thick. Despite its negligible area,
that fragment still blocked runtime rays. The correction uses the declared
1e-8 source-overlay grid for classification clips and reclassifies every
positive-area intersection. Per-piece reconstruction checks allow 1e-7 SVG
square units of numerical difference; this is not a claim of byte-identical
polygon coordinates.

All eight new gameplay tests fail against the previous bundled assets. The
corrected candidate passes on both sides. The tests cover 1,591 interior floor
positions per side, 407 first-window rays, 435 second-room floor/ray positions,
both jambs on both windows, and low-cover behavior. They also retain the earlier
Breeze regressions. Both desktop and Store packaging run the new tests against
the actual bundled data, ignoring diagnostic candidate overrides.

## Broader roof diagnostic

`scripts/audit_breeze_overhead_candidates.py` discovers suspended automatic
collision tops above lower eligible floors using source geometry, player
clearance, collision classification and navigation corroboration. Known IDs
only label results after detection; they do not trigger the diagnostic.

For the frozen Breeze source it finds the previously reported volume 583, the
connected 387/388 pair, and two other ambiguous ledges, 334/335. Those last two
are thin 10.5 m ledges around attack SVG x=330..344, y=106..108 and y=121..123.
Their eligibility is unchanged because the signal does not prove they are
unusable roofs. The diagnostic is a review queue, not an automatic exclusion
rule or a complete audit of every covered structure. It currently examines
flat physical tops with the specified collision and clearance pattern.

## Delivery

The final candidate is `work/breeze-covered-v3`. All 7,916 complete source-domain
checks pass, with no missing or incorrect automatic floors. The bundled release
gate passes all 23 tests; the previous assets fail all eight new gameplay tests
even when a diagnostic environment variable points at the corrected candidate.
The production widget verification passes across 149 records, including placement,
side changes and two continuous walks. All eight rendered captures were inspected.

Both Breeze assets are installed and the updated app is running, recorded in
`work/breeze-covered-v3/delivery.json`. The staged desktop bundle uses the same native
executable and libraries; only its Breeze data changed. The other 24 map height
assets are unchanged. Installation hashes are recorded in
`work/breeze-covered-v3/installation.json`. No installer was packaged or published.
App checks establish Icarus behavior against the reported gameplay expectations.
They do not certify unseen locations in-game.
