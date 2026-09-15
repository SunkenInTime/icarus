# Whole-map Icebox acceptance

The September 9, 2026 whole-map candidate is installed on both artwork sides
and included in the Windows profile build. Its source accounting, complete floor
domains, default and saved selection, production widget, and native wall contacts
pass the recorded acceptance checks. The final binding is
`work/icebox-all-v6/physical-levels/acceptance.json`.

The scope is attack SVG `[0,0,512,512]`, with all scene colliders loaded so that
objects outside that rectangle can still block a player inside it. Measurements
use the frozen 13.05 extraction. Existing gameplay decisions remain separate
from collision measurements. No new live-game observation is claimed.

## Findings and changes

Reference ground could outrank a physical floor. Version 3 assets now identify
measured ground triangles explicitly, and the production provider accepts them.
The first covering triangle owns the ground height. A later physical triangle
cannot certify an earlier reference triangle.

Default selection compares measured ground with verified local supports. Saved
selection chooses the closest local level within the existing 2 cm source-height
tolerance. Distinct nearby levels remain available, ambiguous ties remain
unavailable, and saved numeric values are not rewritten. Compilation uses only
the 0.05 mm source-plane rounding allowance when merging equivalent records.
This preserves the separate nearby snow levels and the saved Tube interior.

The lower pipe uses BP_BlockingVolume134's 5.502050468 m player surface. Its
existing display name follows that measured level. The B bridge retains its
1 m lower floor and inclined upper floor. Kitchen's player floor is 4.7044 m.
Independent fixed-position source measurements support the B and Tube elevation
regressions. Opening, solid-base and doorway-jamb expectations remain separate.

The expanded audit exposed three geometry failures while growing to the whole
map. Subtracting rounded obstacles from an unrounded region left a microscopic
false floor along the regional boundary. A floating triangle union could discard
a complete floor triangle. A floating compiler intersection then claimed ground
coverage outside either input and omitted a small upper level. Source union and
clearance now share a 1e-7 m grid. Compiler overlays share a 1e-8 SVG-unit grid.
Frozen real polygons reproduce all three failures. The rejected candidates
remain available for diagnosis.

Four runtime join positions landed within 5.32e-9 SVG units of the rounded
support boundary. Support containment now admits the compiler's 1e-8 grid
precision. Wall containment and painted wall footprints retain their previous
boundaries. A regression verifies that support rounding does not expand walls.

At the saved ramp regression, measured 1 m ground replaces a 1.6057 m reference
height. A separate constrained-distance check found 5.65 cm of capsule clearance
from the ramp collider. The older triangle-based point checker conservatively
rejected that corner. This disagreement does not change the source floor.

## Recorded checks

| Check | Result |
|---|---|
| Source accounting | All 4,904 inventory mesh records and 751 player collision bodies have a disposition. All 1,018 required mesh measurements completed. No unresolved influencing collider remains. |
| Standing measurements | Of 1,769 source rows, 332 yielded 3,913 planar standing domains. The other 1,437 have no clear standing domain in scope. |
| Independent regional repeat | All 1,268 overlapping source domains agree between `icebox-all-v6` and `icebox-expanded-v5`, within 1e-5 m boundary tolerance and 1e-8 square metres residual area. |
| Complete domain comparison | All 7,826 side/domain comparisons pass level availability and highest eligible default. Height tolerance is 2 cm; domain boundary tolerance is 0.001 SVG units. |
| Ground preservation | 188,853 rebuilt triangles retain their recorded parent coverage and heights. Maximum vertex-height discrepancy is 1.23e-11 m. |
| Runtime positions | 125,209 source cases per side. Each side passes 92,247 applicable cases. Remaining cases are outside the SVG floor or inside an active drawn wall, with reasons recorded. |
| Saved levels | Each side passes 2,482 applicable source placements. The other 1,431 placements have recorded floor/wall exclusions. |
| Production widget | 19,033 checks through the provider, placed agent, cache and painter using Windows bundle assets, including side changes and actual pointer drags across joins. |
| Wall associations | All 3,633 wall fragments retain their source measurements or gameplay decisions. Recovered face identities match source geometry. |
| Native contacts | 20,696 cones, 3,478,012 intervals, zero flagged contacts at 0.002 SVG-unit tolerance. Of 32,144 requests, 11,336 are outside the floor/ground domain and 112 start inside an active wall. |

The combined production-widget and native-export tests pass. All 88 broader
Flutter regressions pass, as do the 42 regional, elevation and boundary-precision
tests. These counts overlap. They do not measure a percentage of map correctness.
The five floor-comparison controls detect missing required floors and incorrect
heights. Source-accounting controls reject missing and unresolved records.

Four full app renders and twelve production-painter views were inspected,
including enlarged wall contacts on both artwork sides. The painter views use
frozen polygons from this candidate's native export. They cover Top Screens,
the lower pipe and the corrected Mid floor. The image files are under
`physical-levels/app` and `physical-levels/boundaries/raster`.

The attack asset is 3,853,230 bytes; defense is 3,936,431 bytes. A query benchmark
covers 354 source placements per side with one warmup and two measured passes.
Median automatic selection plus native query cost is 0.922 ms on attack and
1.013 ms on defense; p95 is 2.349 and 2.531 ms. The largest observed query is
4.421 ms. Model decode and native setup took 430 and 454 ms in that test process.
These are test-process query measurements, not desktop frame times.

## Reproduction and identity

Source measurements and their archived algorithms are under
`work/icebox-all-v6`. Candidate files, Windows build log, verification records,
query timings and painter output are under its `physical-levels` folder.
The extraction remains under `E:/IcarusWorldAudit/2026-09-06`.

```powershell
python scripts/compile_icebox_physical_ground.py `
  --source work/icebox-all-v6 `
  --output work/icebox-all-v6/physical-levels `
  --ground-review work/icebox-all-v6/ground-selection.json `
  --baseline work/icebox-expanded-v2/physical-levels-v4
```

The baseline's `before-attack.json.gz` and `before-defense.json.gz` are the
original version 2 assets. Rebuilding uses those files, not an already compiled
candidate. Measurement and compiler archives retain their exact input hashes.

`verify_icebox_physical_ground.py` checks parent preservation.
`verify_icebox_regional_floors.py` compares source domains and defaults.
`compare_icebox_source_regions.py` checks the independent regional repeat.
`verify_icebox_physical_delivery.py` binds the source, candidate, installed assets,
Windows bundle, production widget, walls and native contacts by hash. Its final
invocation includes `--regional-source work/icebox-expanded-v5`.

| Record | SHA-256 |
|---|---|
| Attack asset | `54675ef71921791a41ce921e730e9a1f7b9ad95dc7efb1d5236aeb9936787e71` |
| Defense asset | `6824ac375f0842c707db09d46cb87e389943ba99a1fb44de9af353b7849349e5` |
| Independent source domains | `cd097400e2f86ff52f085a04a859e11f935cfe44eb8de62dd1e5d560b1588c4c` |
| Runtime source fixture | `5fa869060d6b2dd24e60b6a2bf3750376ba937cf1d4d5ed2562be9cd37d330e1` |

The resumable parallel contact checker previously reproduced the original
single-process result across all 10,928 expanded-v8 cones and detected an
intentionally shortened cone. This candidate received a fresh full contact run.

## Limits and subsequent work

Rounded capsule clipping remains conservative near curved boundaries. Wall
height evidence uses recorded local measurement stations and gameplay decisions;
it is not a continuous proof of every vertical facade point. Standing eyes use
the documented 1.75 m camera approximation, without extra rounded-capsule lift
or native camera adjustments. Crouching and changing map states remain outside
this pass.

The older expanded-v8 results are historical and were superseded after the
regional-boundary source error was found. Their passing runtime checks did not
establish correctness of the false strip. The whole-map candidate includes the
corrected source measurements and the independent regional repeat.

The same acceptance procedure is continuing on Bind. Its initial metadata scan
found missing lighting-level identities and unresolved collision defaults that
must be resolved before standing-domain compilation. Icebox's completed result
does not certify the other maps.
