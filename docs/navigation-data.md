# Player navigation data

Movement uses the shipped `RecastNavMesh-BasePawn` ground polygons, independently
of the SVG artwork and horizontal vision blockers. That mesh was built for a
42 cm radius and 196 cm height. Its recorded 35 cm walkable climb differs from
the character movement component's 45 cm step setting; the bake preserves the
source navigation topology instead of connecting nearby surfaces itself.

`NavigationSidecar.cs` exports parsed Recast tile vertices and neighbors that
CUE4Parse excludes from its ordinary JSON through `JsonIgnore`. Most maps store
their populated tiles in the Navmesh sublevel's `RecastNavMeshDataChunk`, including
Summit. Corrode also has populated root-world tiles. Recast coordinates convert
to Unreal XYZ as `(-x, -z, y)`. The map UI transform then produces canonical UV.

`scripts/bake_navigation.py` preserves convex ground polygons and detail triangles.
Internal polygon neighbors come directly from the tile. External connections
require opposite native tile portals, an overlapping span and the recorded climb
limit. Every walking portal must be reciprocal. Jump, drop, fly and crouch links
are excluded; default, obstacle-cost and breakable ground areas remain walkable.
Dynamic door state is not modeled. Disconnected boxes and platforms remain
separate unless a real walking portal connects them.

The version 1 runtime JSON has a `map`, `coordinateScale`, flattened `vertices`
as UV/UV/height-cm triples, convex `polygons` containing vertex indices,
`triangles` as polygon/a/b/c quadruples, and `links` as
from/to/portal-u1/portal-v1/portal-u2/portal-v2 sextuples. `components` and
`walkable` contain one entry per polygon. The optional
`refinedFloorHeightsCm` array replaces floor heights without modifying walking
connectivity. It must match the source vertex count. Source files, UI data and
build inputs are fingerprinted outside the application assets.

The separate `floorMesh` contains its own `coordinateScale`, UV/UV/height-cm
`vertices` and parent-polygon/a/b/c `triangles`. Its UV scale is 100,000,000 to
preserve narrow stair edges. `scripts/bake_navigation_floors.py` clips actual
upward opaque or unresolved Art triangles to each nav detail triangle and its
vertical window, from 60 cm below to 30 cm above the source nav surface.
Coplanar pieces are combined and triangulated with their boundaries intact.
The runtime selects the highest admitted surface within each parent nav polygon;
different parent polygons preserve stacked floors. Missing detail falls back to
that parent's refined nav surface. This does not change the walking graph.
Both floor paths reject nonwalkable parents and stay inside the encoded convex
nav polygon used by the visibility bake. Finer floor coordinates cannot expand
the admitted observer domain.

Source materials are verified against native mesh sections and effective placed
component overrides before baking floors or visibility. The first repair matched
Blender triangles to USD subsets. That fixed Blender aliases and whole-mesh
unknown flags, but a later audit found a second exporter error: repeated native
material slots were deduplicated while section indices still addressed the
original slot list. Even a bound USD subset could therefore name the wrong
material.

`scripts/audit_native_material_slots.py` now verifies LOD0 section face ranges,
native material indices, inherited component templates and placed transforms.
The final Art audit covers 94,240 placements and 41,818,704 faces on all 13 maps
with no unresolved section-correspondence errors. It changes 39,352 face
policies. Points, faces and UV values and dtypes remain exact. Unresolved shader
behavior is recorded separately from proven native material identity. The
remaining 1,541 shader-dependent faces are outside the admitted standing-height
and map domains in this dataset.

`scripts/finalize_native_navigation_floors.py` rebuilds floors where those
policies change admission. Sunset, Bind and Haven required a rebuild; the other
ten retained identical detailed floor values. Bind also corrected eight native
fallback columns by 1.46 to 4.50 mm after removing a painted overlay. These frozen
material-corrected worlds are called v2 in the audit archive.

Only Bind and Fracture receive a further floor correction, called v3. Authored
face orientation alone is insufficient to identify player support: a decorative
mesh may ignore the Pawn while a separate blocking volume supports the player.
Unverified cases retain the v2 approximation. `scripts/derive_world_ground_facing.py`
proves per-face orientation through exact source triangle and transform
correspondence. `scripts/ground_floor_policy.py` applies it only to ranges with
confirmed native support, preserving the original float32 admission predicate
everywhere else.

Fracture has two Radianite tube placements with declared Pawn-blocking,
complex-as-simple collision. Their 384 source faces use the proven authored
orientation. Bind uses a separate native convex slope hull under one sandbag
placement. The hull replaces the old Art height only inside the implicated Art
footprint, matching native parent polygons and both source height windows.
At the investigated column, the native hull is 4.050674 m high; the old Art
selection was about 3.9029 m and the mirrored decorative top about 4.1908 m.
The final detailed meshes contain 51,636 triangles on Fracture and 82,841 on Bind.
Walking topology and visibility geometry are unchanged by these floor fixes.

`scripts/stage_verified_floor_corrections.py` writes these candidates separately.
Hashed `groundFacing` and `groundSupport` sidecars bind the exact Art geometry,
native navigation, support proof and optional convex hull. The floor report
records those same sidecar hashes. The independent ground caster replays the
native convex vertices and placement, tests the original Art footprint and
native height window, and casts source triangles without reading the baked
floor polygons.

Independent checks of the frozen v3 sources passed all 6,303 sampled columns
within 1 cm: 3,342 on Fracture and 2,961 on Bind, including 445 direct native-hull
samples. They combine random columns with floor-triangle centroids in every
affected parent polygon. The investigated support columns differ from their
source heights by less than 0.008 cm after floor encoding. These checks validate
the selective support geometry; final visibility checks use the same frozen
floor hashes when choosing standing planes.

The standing convention remains vertical support-surface height plus the nominal
standing camera offset. It does not simulate capsule contact, floor clearance,
step logic or camera code. For example, ideal 42 cm capsule tangency on Bind's
slope adds about 5.34 cm above its vertical hull column. That is a separate
geometric estimate, not a measured game-camera correction, and is not added to
the baked floor. This dataset therefore establishes a standing approximation,
not exact native Pawn physics.

The runtime caches the immutable map, indexes floor triangles spatially, and
runs A* over the precomputed polygon graph. A funnel removes unnecessary route
bends while staying inside its portal corridor. A 128-entry route cache avoids
repeating searches. Canonical attack coordinates are used throughout; the
display rotates completed paths for defense. Agent icon size does not alter
the physical clearance of the baked navigation. Unreachable endpoints produce
no invented walking segment; the agent stays at its source until the destination
page replaces it.

Reproduce from the archived version-matched source:

```powershell
python scripts/bake_navigation.py --navigation E:/IcarusWorldAudit/2026-09-06/nav/navigation --properties E:/IcarusWorldAudit/2026-09-04/all-map-properties-13.05/properties --manifest E:/IcarusWorldAudit/2026-09-04/all-map-reference-manifest-final.json --output E:/IcarusWorldAudit/2026-09-06/nav/baked
flutter test --no-pub test/navigation_geometry_test.dart test/agent_transition_path_test.dart
flutter test --no-pub tool/audit_navigation_test.dart --dart-define=NAVIGATION_ROOT=E:/IcarusWorldAudit/2026-09-06/nav/baked
python -m unittest discover -s scripts -p test_bake_navigation.py
python -m unittest discover -s scripts -p test_audit_native_material_slots.py
python -m unittest discover -s scripts -p test_derive_world_ground_facing.py
python -m unittest discover -s scripts -p test_ground_floor_policy.py
python -m unittest discover -s scripts -p test_bake_navigation_floors.py
```

The archived per-map `native-slot-audit.json` and `verified-floor-correction.json`
record source paths, hashes, repair scope and output hashes. Use fresh output
directories when rerunning those scripts; the archived v2 worlds and earlier
baselines remain available for comparison.

The floor bake uses Shapely 2.1.2 and NumPy. The material audit also uses
usd-core 26.8 and Pillow 12.3.0, installed in the September 4 audit venv.
`scripts/blender_audit_navigation_floors.py` independently casts the original
3D triangles in Blender. Its BVH includes only admitted floor faces. Advancing
past a rejected coincident decal can skip an opaque face at the same height,
which produced false differences in the earlier iterative reference.

The September 6 audit checked 3,250 routes on all 13 maps and 3,766,742 points
against the source polygons. With detailed floors enabled, per-map
95th-percentile route times were 0.237–0.423 ms in the Flutter test VM.
These checks establish source containment,
connectivity and local performance, not in-game movement equivalence. Tile
voxel heights are commonly 10 cm above the Art floor, or 5 cm on Summit.
The first Split interior check found a 13.42 cm 95th-percentile floor error after
correcting only nav vertices. The separate floor mesh resolves that smoothing
error. An earlier USD-only material repair validation compared 83,880 standing opaque
reference hits on all maps, excluding Summit's nonwalkable parent regions.
83,869 agree within 1 cm. The other eleven are Summit surface-edge positions where
moving the 3D reference point by 0.01 cm spans both reported heights. Those ties
remain explicit in the audit. Every other map's maximum measured floor residual
is below 0.015 cm. Floor lookups took 11–32 microseconds at the 95th percentile
in the test VM. Those historical counts predate the final native-slot and selective
support repairs and are not their acceptance results. Final source/ray checks
must bind the selected per-map v2 or v3 hashes. All these checks measure agreement
with exported geometry; they do not certify in-game camera or movement behavior.
