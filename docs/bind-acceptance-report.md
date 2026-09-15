# Bind source and standing acceptance

Completed and installed on September 9, 2026. Both Windows profile assets pass
the source, standing-level, placement and native contact checks below. The
[`acceptance record`](../work/bind-all-reviewed-v3/physical-levels/acceptance.json)
supersedes the provisional v1 and v2 candidates.

A later Ascent seam check widened support containment from one to two units of
the compiler's 0.00000001 SVG-unit rounding grid. Bind's delivered data remains
unchanged. Its full runtime cases and all 21,411 placed-agent app checks pass
again after the Windows profile rebuild. The
[rounding regression](../work/bind-all-reviewed-v3/rounding-regression/summary.json)
records this follow-up against the same source expectations. Wall and receiver
containment, and the native boundary geometry, were not changed.

Bind now uses measured ordinary floors, ramps and selectable raised surfaces.
Dara's ceiling decision prevents inaccessible overhead geometry from becoming
the automatic standing floor. Saved lower levels remain available. SVG artwork,
wall footprints, receiver geometry and map coordinates are preserved.

## Source scope and gameplay decisions

The source revision is Valorant 13.05. The declared region covers attack SVG
`[0, 0, 512, 512]`. Every nonempty scene mesh is inventoried. All scene colliders
participate in clearance, including instances whose physical transforms place
them outside their rendered bounds.

| Source obligation | Result |
|---|---:|
| Nonempty source meshes inventoried | 8,063 |
| Meshes excluded by resolved settings or empty simple collision | 6,385 |
| Required mesh colliders decoded and measured | 1,678 |
| Player-volume bodies measured in the region | 749 |
| Unresolved influencing colliders | 0 |
| Raw physical standing domains | 4,111 |
| Domains after the September 8 gameplay review | 4,125 |
| Domains excluded by the ceiling decisions | 137 |
| Final measured or reviewed domains | 3,988 |

Dara's September 8 review supplies 226 Bind positions. Its source-only
application checks object and face identities, sample heights and supplied
collision faces. It adds 15 grouped reviewed domains and removes only the
fountain's narrow inner ring. The center and outer basin remain. All 226 reviewed
positions and all 15 added domains survive the ceiling decision.

The named `CatchAllBlockingVolumeCeiling` collider has an underside at
12.9999998589 m and a top at 27.1098588291 m. Dara first excluded its own upper
face, then confirmed after inspecting the 3D source viewer that positions inside
that volume do not matter and authorized continuation. The canonical decision is
[`bind-playable-space-review-2026-09-09.json`](../scripts/data/bind-playable-space-review-2026-09-09.json).

The application excludes standing geometry at or above the measured underside
within the collider's actual footprint. It removes the ceiling domain and 136
other domains. No partial domain clipping was needed for this revision. Raw
measurements and collision inputs remain unchanged; the ceiling still participates
in clearance. Lower surfaces, positions outside that footprint, and usable
isolated or ability-accessible platforms retain their physical tests.

The independent fountain measurement covers attack SVG `[35, 260, 115, 335]`.
After applying the same reviews independently, its 336 domain groups agree with
the restriction of the whole-map source. The comparison allows 0.00001 m at
polygon boundaries and 0.00000001 m² of residual area.

The source reader resolves inherited Blueprint collision properties, native
instance transforms and supplemented Lighting components. Empty serialized
simple shapes are checked against extracted mesh packages. Custom response arrays
use the engine default when they omit Pawn, following the pinned UE 5.3
[BodyInstance.cpp](https://github.com/chenyong2github/UnrealEngine/blob/c865e168d0935b8e5f4bd865ddcc1c733c8ce7cf/Engine/Source/Runtime/Engine/Private/PhysicsEngine/BodyInstance.cpp)
and [CollisionProfile.cpp](https://github.com/chenyong2github/UnrealEngine/blob/c865e168d0935b8e5f4bd865ddcc1c733c8ce7cf/Engine/Source/Runtime/Engine/Private/Collision/CollisionProfile.cpp).
These rules resolve source settings; they do not replace gameplay review.

## Delivered data and verification

The compiler uses 2,266 designated ordinary-floor domains to replace reference
ground locally. It reconciles other physical levels as selectable supports.
Attack contains 106,176 ground triangles, including 46,531 certified physical
triangles, and 1,859 supports. Defense contains 106,167 ground triangles,
including 46,513 certified physical triangles, and 1,861 supports. The baseline
had 339 supports per side.

Preservation checks pass against the frozen original baseline. Maximum
source-plane vertex error is below 0.000000000001 m. Wall arrays, receiver
records and unrelated map fields remain unchanged. The compiled pair matches
the installed assets and the successful Windows profile build's copied assets.

| Acceptance obligation | Evidence and result |
|---|---|
| V1, preserve SVG and placements | Artwork hashes, unchanged wall and receiver records, both-side coordinates and saved-placement checks pass. |
| V2 and V3, physical and reviewed levels | All 7,976 whole-domain availability and automatic-default comparisons pass, one per domain and side. |
| V4, complete source accounting | All 8,063 mesh records, 1,678 required mesh measurements and 749 volume measurements accounted for; no missing, duplicate or unresolved records. |
| V5, app selection | 21,411 checks pass through the production provider, placed-agent widget, cache and painter using Windows bundle assets. |
| V6, walls and openings | All 3,061 existing wall associations pass their recorded source stations. Both-side wall data remains unchanged. No new live-game opening claim is made. |
| V7, continuous movement | Source fixtures include 3,078 ramp paths and 4,466 joins. Runtime samples cover these paths; the widget checks 11,498 ramp positions and 74 pointer movements across three independently selected automatic joins. |
| V8, delivered implementation | Asset, fixture, provider, widget, painter and native-library hashes link the successful build and test reports. |

The source-only regional fixture contains 194,866 cases per side. The Dart
runtime passes 114,095 applicable attack cases and 114,094 defense cases. Other
cases are recorded as outside the SVG floor or inside active walls. Saved-level
checks pass at 2,447 applicable domain placements per side, with the other
placements recorded separately. Exclusions are not counted as successful standing
checks. Full-domain height tolerance is 0.02 m, with 0.001 SVG-unit boundary
tolerance and a 0.00000001 SVG-unit overlay precision grid.

The widget integration checks include 24 primary placements, two explicit lower
references, one pointer drag, 4,918 source-domain defaults, 4,894 saved domain
levels, 11,498 saved ramp levels and 74 pointer movements across joins. Maximum
eye-height error is 0.00005 m. Expectations come from source geometry and reviewed
positions; the frozen baseline supplies only SVG footprints and existing wall
intervals. The candidate does not generate its expected floor heights.

Twenty focused Python tests pass for review application, ceiling clipping,
compilation, floor comparison and source accounting. Isolated local candidate
copies also demonstrate rejection of a removed required floor and a 0.25 m height
error on both sides. Identical source expectations pass for the baseline.
Separate controls reject missing and unresolved source records.

## Native contacts and visual inspection

The compiled Windows library exported 21,384 cones from 33,712 requested cases.
It recorded 12,088 origins outside the SVG floor or ground domain and 240 inside
active SVG walls. The independent GEOS audit checked 6,428,143 polygon intervals
and found zero flagged cones or intervals at a 0.002 SVG-unit threshold.

Twelve production painter views cover a B-site box, the fountain and a connected
ramp on both sides, each at normal scale and an enlarged contact. All twelve were
personally inspected, alongside four placed-agent captures. A narrow strip beside
the fountain's defense-side wall was traced to a radial corner shadow. Its
boundary follows the ray from the origin through SVG `[321.116, 178.028]`; it is
not a displaced wall-contact edge.

The inspected raster records and image hashes are in
[`visual-inspection.json`](../work/bind-all-reviewed-v3/physical-levels/visual-inspection.json).
The first primary attack capture contains a placeholder agent portrait, limiting
it to placement and cone inspection. The raster tool's before and current fields
contain the same delivered cone; they do not compare revisions.

## Size and query cost

The compressed attack asset is 4,008,256 bytes and defense is 4,123,873 bytes,
8,132,129 bytes combined. The native-query benchmark uses 352 source placements
per side, one warmup pass and two measured passes. Selection plus cone generation
has median costs of 0.849 ms on attack and 1.507 ms on defense. The respective
p95 costs are 1.713 ms and 4.099 ms; maxima are 3.843 ms and 8.970 ms. Model loading
and native setup take about 466 ms and 461 ms. These measurements come from a
Flutter test process, not desktop frame timing.

## Evidence and reproduction

| Evidence | Location or SHA-256 |
|---|---|
| Final source | `work/bind-all-reviewed-v3/regional-floors.json`, `0303e80ee6e20b359643931b523f0b47a7ea200d72ec65186a8159506fe56988` |
| Attack asset | `b6b0fbe25bf74b6ddf213285822a30ed2332e46df11da9bb5f7968a255b6d673` |
| Defense asset | `15ae039cdd5caff2bb420e38da2da051e1f18567d51c163f1264724b144c72fc` |
| Regional fixture | `test/fixtures/bind_regional_standing.json`, `9b9eaff5e08a1685df940711eb03b6521d5a535cfc8bb7b5513a34bab75c8d55` |
| Primary app fixture | `test/fixtures/bind_vision_acceptance.json`, `ef01c7a174e47380efbd0e056171784c515225c3853a4c0895e549b6ecf02b20` |
| App verification | `work/bind-all-reviewed-v3/physical-levels/app/verification.json`, `544db83d30d4b47fd173344f96ab8bc311f985c550649b0978f18d4c41383475` |
| Native library | `f50ce4996e030a3d2b78075dfc76a726ffffbb79d1e6fcd42018ab091b09cf0a` |
| Native cones | `work/bind-all-reviewed-v3/boundaries/cones.jsonl`, `6fff09803f651bfdbb47f52042e7a08be3c64ad903a0c1921fed696653dc6f3d` |

Source algorithms, inputs, raw measurements, review applications and original
candidate baselines are archived in the corresponding work directories. No game
package was modified. The final aggregate check is:

```powershell
& E:/IcarusWorldAudit/2026-09-06/venv/Scripts/python.exe scripts/verify_icebox_physical_delivery.py `
  --source work/bind-all-reviewed-v3 `
  --candidate-dir work/bind-all-reviewed-v3/physical-levels `
  --fixture test/fixtures/bind_regional_standing.json `
  --boundaries work/bind-all-reviewed-v3/boundaries `
  --walls work/bind-all-reviewed-v3/regional-wall-comparison.json `
  --regional-source work/bind-fountain-reviewed-v3 `
  --app-fixture test/fixtures/bind_vision_acceptance.json
```

## Limits and next work

The result covers the declared source revision and static standing model, using
a selected floor plus 1.75 m camera offset. Rounded capsule clipping remains
conservative near curved boundaries. Wall evidence retains existing local source
stations and gameplay decisions; this is not a continuous facade proof.
Crouching, changing map states and new live-game observations are outside scope.

Bind has no outstanding decision from Dara within this scope. Continue the same
source-first acceptance process on Ascent, resolving its inherited collision
settings before compiling or installing new standing data.
