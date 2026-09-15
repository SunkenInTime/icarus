# Ascent source and standing acceptance

Completed and installed on September 10, 2026. Both Windows profile assets pass
the source, standing-level, placement and native contact checks. The
[acceptance record](../work/ascent-all-reviewed-v2/physical-levels/acceptance.json)
links the delivered assets to their source measurements and test results.

Ascent now uses measured ordinary floors, ramps and selectable raised surfaces.
Dara's review excludes sixty specific patches outside playable space. Saved
lower levels remain available. SVG artwork, wall footprints, receiver geometry,
map coordinates and saved positions are preserved.

## Gameplay decision

Dara confirmed that all sixty red patches shown in the
[3D inspector](https://bind-ceiling-inspector.daradoescode.chatgpt.site/ascent/)
are outside playable space, including the Tree-room upper rim. The canonical
[gameplay decision](../scripts/data/ascent-playable-space-review.json) retains
the exact domains, source faces, planes, geometry and source fingerprints.

| Group | Excluded patches | Source height |
|---|---:|---:|
| Tall boundary-volume caps | 50 | 35.65 to 61.56 m |
| Collision caps around the Tree room | 4 | 13.00 to 15.00 m |
| Bell-tower ledges | 4 | 44.39 to 55.40 m |
| Tree-room upper trim | 2 | 13.50 m |

The application removes exactly those sixty standing domains. It preserves all
4,179 other domains, the six previously reviewed positions and every raw
collision body. The excluded bodies still participate in clearance. Thirteen
metres was a diagnostic search threshold, not an eligibility limit. Other
isolated and ability-accessible surfaces retain their physical standing tests.

The exclusion tool checks source-face identities and rounded plane coefficients
against the frozen collider triangles. A smaller region can contain only a
subset of the reviewed faces; the exclusion still stays within the exact
approved footprint. Controls reject changed heights and collision geometry,
and preserve adjacent faces, higher unrelated surfaces and unapproved areas.

## Source accounting

The source revision is Valorant 13.05. The declared region covers attack SVG
`[0, 0, 512, 512]`. Every nonempty scene mesh was inventoried before opening a
candidate. All scene colliders participate in clearance, including native
instances whose physical transforms differ from their rendered transforms.

| Source obligation | Result |
|---|---:|
| Nonempty source meshes inventoried | 8,522 |
| Excluded by resolved settings or verified empty simple collision | 6,575 |
| Required mesh colliders measured | 1,947 |
| Player-volume bodies measured | 765 |
| Unresolved influencing collision records | 0 |
| Raw physical standing domains | 4,234 |
| Domains added by the six-position gameplay review | 5 |
| Domains excluded by the latest gameplay decision | 60 |
| Final measured or reviewed standing domains | 4,179 |

The raw measurement remains in `work/ascent-all-v4`. The first reviewed source
retains the September 8 gameplay application. The final source is
`work/ascent-all-reviewed-v2`; earlier measurements and candidates remain
available as evidence.

The independent smaller A-region measurement agrees with the whole-map source
after applying the same reviews separately. All 148 remaining domain groups
pass, allowing 0.00001 m at polygon boundaries and 0.00000001 square metres of
residual area. Source accounting finds no missing, duplicate or unresolved
obligations. Separate controls reject omitted and unresolved source records.

## Delivered data and checks

The compiler uses 2,446 measured domains from seven ordinary-floor and stair
assemblies. Other physical levels become selectable supports. Each candidate
was compiled from its frozen original asset, then installed with a baseline
hash check. The Windows profile build passes and contains the same asset bytes.

| Delivered data | Attack | Defense |
|---|---:|---:|
| Ground triangles | 58,106 | 58,114 |
| Certified physical ground triangles | 27,405 | 27,408 |
| Selectable supports | 3,194 | 3,193 |
| Compressed asset bytes | 2,823,940 | 2,828,650 |

All 8,358 full-domain availability and automatic-selection checks pass. Height
tolerance is 0.02 m and boundary tolerance is 0.001 SVG units. Preservation
checks confirm unchanged wall arrays, receiver records and unrelated fields.
Maximum ground vertex-height error is below 0.000000000001 m.

The source fixture contains 114,799 samples per side, including 2,247 ramp paths
and 3,746 joins. Each side passes 102,065 applicable samples; 12,331 lie outside
the SVG floor and 403 have eyes inside active walls. Saved-level checks pass at
3,649 domain placements per side, with 495 outside the floor and 35 inside
walls. These excluded cases are recorded separately from successful checks.

The production provider, placed-agent widget, cache and painter pass 26,901
checks using the Windows bundle. They include ten primary placements, one
pointer drag, 7,298 source-domain defaults, 7,298 saved source levels, 12,244
saved ramp positions and fifty pointer movements across three source-selected
joins. Maximum eye-height error is 0.00005 m. Expected levels come from source
geometry and gameplay review; the baseline supplies only SVG footprints and
previously reviewed wall intervals.

All 2,642 wall associations pass their recorded local source stations. One
coincident-station ambiguity was resolved by retaining the compiler's nearest
registered section. Equally good conflicting sections still fail the verifier.
No wall heights changed. These local stations do not constitute a continuous
measurement of every facade.

Four isolated fault copies demonstrate rejection of a removed required floor
and a 0.25 m height error on both sides. The same source expectations pass on
the unchanged candidate.

An earlier Ascent seam test exposed support-boundary rounding across two
successive compiler operations. The shared support tolerance now admits two
0.00000001 SVG-unit steps. Wall, receiver and ground containment did not change.
The focused regressions and complete Ascent runtime tests pass. Bind's full
runtime and placed-agent checks also pass, with identical inspected captures;
its [report](bind-acceptance-report.md) records that regression.

## Native contacts and visual inspection

The compiled Windows library emitted 29,240 cones from 33,480 requested cases.
It recorded 3,960 origins outside the SVG floor or ground domain and 280 inside
active walls. The independent GEOS audit checked 3,100,045 polygon intervals
and found zero flagged cones or intervals at a 0.002 SVG-unit threshold.

All twelve production painter views were personally inspected. They cover an
A-site raised position, a B-site ordinary floor and the defender A ramp, each
on both sides at normal size and enlarged wall contacts. Selected contacts meet
the painted strokes. Corner shadows begin at the wall corners, and the ramp
view continues across its floor markings and through the opening.

Four placed-agent captures were also inspected. The first attack capture has
a placeholder portrait, limiting it to placement and cone inspection. The
[visual record](../work/ascent-all-reviewed-v2/physical-levels/visual-inspection.json)
contains image hashes and observations. The raster tool's before and current
fields contain the same delivered cone; these images do not compare revisions.

## Size and query cost

The two compressed assets total 5,652,590 bytes. The query benchmark uses 526
source placements per side, one warmup pass and two measured passes. Median
selection-plus-cone cost is 0.650 ms on attack and 0.727 ms on defense. Respective
p95 costs are 1.321 ms and 1.512 ms; maxima are 1.917 ms and 3.727 ms. Loading and
native setup take about 376 ms and 277 ms. These are Flutter test-process query
costs, not desktop frame times.

## Reproduction and limits

```powershell
& E:/IcarusWorldAudit/2026-09-06/venv/Scripts/python.exe scripts/verify_icebox_physical_delivery.py `
  --source work/ascent-all-reviewed-v2 `
  --candidate-dir work/ascent-all-reviewed-v2/physical-levels `
  --fixture test/fixtures/ascent_regional_standing.json `
  --boundaries work/ascent-all-reviewed-v2/boundaries `
  --walls work/ascent-all-reviewed-v2/regional-wall-comparison.json `
  --regional-source work/ascent-a-reviewed-region-reviewed-v3 `
  --app-fixture test/fixtures/ascent_vision_acceptance.json
```

The result covers the declared static source revision, with standing eyes at
the selected surface plus 1.75 m. Rounded capsule clipping remains conservative
near curved boundaries. Crouching, changing doors and other dynamic map states,
and new live-game observations are outside scope.

Ascent has no outstanding decision from Dara within this scope. Breeze's source
collision accounting is now resolved; its full standing measurement and delivery
checks continue separately.
