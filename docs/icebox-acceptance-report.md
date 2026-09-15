# Icebox acceptance exercise

The initial Icebox exercise passed against the asset revision recorded below.
Its source inventory was accounted for, and the app checks found and corrected
a ramp-selection error. These results establish that revision and region.
The current, larger audit is tracked in
[the expanded acceptance report](icebox-expanded-acceptance-report.md).

The [acceptance contract](vision-acceptance-contract.md) now has a practical
example of why floor availability and default selection need separate checks.
At one ramp join the correct physical level existed, but interpolated ground
took priority about 2.8 cm above it. Whole-domain availability passed; the real
pointer-drag test failed.

## What changed

The two ordinary ramps and their adjoining landings now use measured source
planes in the ground mesh. Both Icebox assets were updated, and the Windows
profile build was rebuilt. The correction replaces the affected portions of 158
old ground triangles per side. Walls, supports, receivers, artwork, and saved
strategy data retain their previous values. Ground outside the source domains
retains its interpolation within the boundary tolerance below.

The offline reader now identifies placed instances by audited face ranges,
verifies source hashes, and resolves omitted native collision settings explicitly.
The exporter can preserve cooked collision bytes and collision configuration as
separate evidence. These changes resolve the earlier lookup, inheritance, and
empty-simple-collision ambiguities.

Dara excluded the buried Cube9 collider as outside playable space. The
[canonical record](../scripts/data/icebox-playable-space-review.json) identifies
that exact source revision and object. Ability-accessible platforms and ledges
remain eligible. Walking connectivity is not required.

## Source accounting

The region is attack SVG bounds `[270,140,345,225]`, transformed into native
coordinates and checked on both artwork sides. It includes Top Screens, adjacent
pipes, ordinary ramps, and landing floors.

The final inventory includes every placed mesh whose bounds touch the region,
including meshes without a horizontally projected render face. Render geometry
cannot rule out a separate simple collider. This expanded the earlier 171-mesh
inventory to 184. All 184 mesh records and 57 player-collision bodies have a final
disposition, with no unresolved influencing collision record.

Of the mesh records, 158 are excluded by resolved collision settings or the
buried-collider review. The other 26 have resolved collision geometry but no clear
eligible standing domain within this region. Of the 57 collision bodies, 31 have
standing domains and 26 have none. The 31 bodies produce 35 planar domains.
An excluded render mesh can have a separate player-collision body supplying its
physical standing level.

The reader applies native UE 5.3 StaticMeshActor defaults only to its exact root
component. Explicit serialized overrides take precedence; Blueprint components
do not receive those defaults. The pinned engine source, game configuration,
native placement audit, extracted bytes, geometry, and gameplay decisions remain
recorded as evidence. This is extracted-source analysis, not a fresh measurement
inside the running game.

## Results

| Check | Result | What it establishes |
|---|---|---|
| Source accounting | 184 meshes and 57 collision bodies accounted for | No unknown source collision remains in the declared standing inventory. |
| Regional floor domains | 70 comparisons pass, 35 domains per side | Each applicable physical level is present across its planar domain. |
| Regional runtime positions | 2,543 applicable positions pass per side | Required levels are available; ordinary ramp joins also check default selection. |
| Authored-wall exclusions | 72 positions per side explicitly excluded | Their source eye lies inside active SVG wall ink. |
| Original reported surfaces | 210 position checks and four domain checks pass | Top Screens remains at 7.00 m; the reviewed lower pipe remains at 5.497431 m. |
| Ramp paths | Eight interior paths and six joins checked | Source-defined levels survive slopes and adjoining floors. |
| Production widget | 153 checks pass | Four defaults, two saved lower references, one Screens-to-pipe drag, 46 ramp placements, and 100 pointer updates across ordinary ramp joins. |
| Wall source associations | 173 regional fragments pass | Intervals match recorded source or gameplay decisions; both side wall arrays match the reviewed revision. |
| Native boundaries | 1,112 cones, 124,344 intervals, zero flagged mismatches | Tested cone edges meet active SVG wall footprints within tolerance. |

These counts overlap and must not be added as unique map coverage. Of 1,120
requested cone cases, eight are explicitly excluded at one source position inside
the crate wall, across two sides and four directions. The report records the
blocking wall IDs. They are not counted as successful cones.

The widget checks load delivered assets through the production provider,
placed-agent widget, cache, and painter. Side changes preserve saved placements.
The saved lower-reference check establishes compatibility; its old interpolated
value is not physical-floor evidence.

Fault controls detect removed required floors, incorrect support heights,
inflated ground overriding a ramp, missing source records, and unresolved source
records. Expected heights remain fixed from source while tested data changes.

The final targeted Flutter run passed 33 tests. Asset loading and finite-wall
preflight also passed for all 13 maps. Relevant Python suites passed 21 tests,
and the added Dart files passed analysis. Native placement fingerprints loaded
for all 13 maps. These broader checks are regressions, not acceptance
certification of those other maps.

## Tolerances and limits

Height comparisons allow 0.02 m. Regional polygon comparisons allow 0.001 SVG
units of boundary displacement, less than half a millimeter in this registration,
and at most `1e-6` square SVG units of numerical remainder. A thin missing floor
far from a matching level still fails. Samples are one micron inside source
domains to avoid zero-width Boolean seams. Whole-domain comparisons retain the
original polygons. Rounded-capsule clipping remains conservative at curved edges.

The ground-preservation audit reports boundary remainders below `1.7e-7` square
SVG units. Outside those seams, the ground-height change outside the correction
domains is below `2e-14` m. Native cone contact tolerance is 0.002 SVG units.

Wall profiles retain measured stations and recorded gameplay associations. This
pass verifies their lineage and delivery; it does not continuously remeasure
every facade or establish a new gameplay opening. Default selection is checked
at the reported poses and ordinary ramp joins. Whole-domain availability alone
does not certify the default at every possible point. Crouching, dynamic states,
the rest of Icebox, and other maps remain outside this exercise.

The next application should expand the source region, then run the same
accounting, domain, selection, and rendering gates. More hand-picked passing
poses would not establish that expanded coverage.

## Reproduction and evidence

The source readers use `E:/IcarusWorldAudit/2026-09-06` and its Python environment.
Portable fixtures and Flutter regressions are in the repository. Run in this order:

```powershell
$py = 'E:/IcarusWorldAudit/2026-09-06/venv/Scripts/python.exe'
& $py scripts/audit_icebox_acceptance.py
& $py scripts/audit_icebox_regional_floors.py
& $py scripts/build_icebox_regional_cases.py
& $py scripts/build_icebox_boundary_cases.py
& $py scripts/compile_icebox_ramp_ground.py
& $py scripts/verify_icebox_regional_floors.py
& $py scripts/verify_icebox_regional_walls.py
& $py scripts/verify_icebox_ramp_ground.py
flutter test --no-pub test/icebox_vision_acceptance_test.dart test/icebox_regional_standing_test.dart tool/verify_icebox_app_acceptance_test.dart
$env:ICARUS_BOUNDARY_AUDIT = 'work/icebox-acceptance/boundaries'
$env:ICARUS_SVG_NATIVE_LIBRARY = 'build/windows/x64/runner/Profile/icarus_height.dll'
flutter test --no-pub tool/export_svg_boundary_sweep_test.dart
& $py scripts/audit_svg_cone_boundaries.py --output work/icebox-acceptance/boundaries
& $py scripts/verify_icebox_acceptance.py
```

The compiler prepares candidates by default; `--install` copies the correction
into repository assets. Rebuild Windows profile before checking delivered assets
if they change. The aggregate verifier rejects stale fixtures, source measurements,
models, app results, and boundary exports by hash.

The [aggregate report](../work/icebox-acceptance/acceptance.json),
[source dispositions](../work/icebox-acceptance/source-dispositions.json),
[ground correction audit](../work/icebox-acceptance/ramp-ground/verification.json),
and [app trace](../work/icebox-acceptance/app/verification.json) retain the details.
