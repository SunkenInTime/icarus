# Valorant world reference, updated September 5, 2026

Historical extraction and prototype results. Follow [the visibility model](vision-model.md)
for current work: SVG artwork supplies planar walls; this extraction supplies
height, opening, and support evidence.

Version-matched mappings repair the Split import. All 13 Icarus maps now have
exported 3D references. The standing-only prototype takes horizontal
cross-sections from those triangles and feeds them into Icarus's existing
visibility calculation. Riot vision tables remain comparison evidence.
Production collision assets remain unchanged. The earlier Sunset scale fix
is merged in PR #159.

Local evidence lives under `E:/IcarusWorldAudit/2026-09-04` and `2026-09-05`. Raw game assets and
settings stay outside the repository. Reports supplement the explanation in
chat, as specified in [answers.md](../answers.md).

## In-game check, September 5

Dara clarified the intended model: a horizontal sightline at the observer's
eye height is blocked when geometry intersects that height. Low cover below
that plane should not block it. The world height must include the observer's
floor elevation. Only standing visibility is in scope; crouching is not a
supported stance. This model does not simulate looking up or down. Stacked
floors still need explicit floor selection. The screenshot pair is landmark evidence, not
a substitute for testing this horizontal rule.

Dara opened a Split custom game and provided stationary standing and crouched
views beside the B-site low crate. The crate, stacked furniture, corrugated
sheet and decorative wall openings match the extracted scene. Both captures
show the wall above the crate. Fixed wall features move upward in the crouched
view, consistent with a lowered camera. The aim is slightly upward, so these
images do not independently establish eye height or reproduce the earlier
horizontal ray exactly.

The original screenshots and their fingerprints are in
`E:/IcarusWorldAudit/2026-09-05/in-game/evidence.json`. A provisional camera fit
uses manually selected landmarks and fitted intrinsics. Its reprojection error
is not sufficient evidence to adopt a standing eye height. No fitted
camera value has been copied into production.

The production comparison runner now also tests the raw game vision layers,
before SVG contours replace their segments. For recorded ray `44-1.7-9`, current
Icarus clips at 0.337 m, raw game geometry at 2.886 m, and the exported triangles
at 2.681 m. This isolates a useful distinction between the authored boundary
and the source visibility data. Those distances are from the diagnostic ray,
not measurements of the in-game screenshots.

The earlier 13,155-ray runner passed with this additional comparison. Raw geometry is
not automatically certified: 2,564 eligible diagnostic rays still differ from
the triangle reference by over 0.5 m, and the raw layers omit the low crate in
the 0.98 m sensitivity test. These counts are not gameplay error rates. The
new prototype preserves SVG appearance while testing visibility geometry
separately. A wholesale switch to raw layers has not been made.

## Standing 3D prototype

The current runtime replaces source visibility segments with authored SVG
groups. Admitted groups default to every height layer, and the outer footprint
cannot be disabled by an override. Low cover incorporated into that outline
therefore remains a blocker even when the observer's eyes are above it.
Changing the observer-height number alone cannot resolve that case.

`blender_export_visibility_slice.py` intersects the placed triangles with the
recorded observer's horizontal planes. `verify_world_slice_test.dart` loads
those segments through Icarus's coordinate decoder and `VisionPolygon.compute`.
The SVG still governs allowed observer positions; its outline is absent from
the prototype's occluders. No source visibility-table segments enter that path.
The SVG files, dimensions, scale and production provider remain unchanged.

The test covers attack and defense orientations. It compares the actual 2D
center ray against Blender's 3D hit, writes per-ray errors and fails above
5 mm. This verifies conversion of the same source geometry, not independent
gameplay accuracy. Unknown and nonopaque surfaces remain present in the
prototype, so a passing conversion test cannot certify their visibility.

At Split seed 44, the candidate floor +1.75 m ray reaches the B-site wall at
2.681 m. Current Icarus stops at 0.337 m. Across the 1.55, 1.75 and 1.95 m
standing sensitivity band, the model clears the low crate at all three heights.
The wall distance changes to 2.911 m at the highest plane because its opening
changes the section. These are height candidates, not supported stances or
certified camera defaults. The 1.75 m section contains 6,108 segments around
the fixture, so segment reduction and multi-agent performance still need work.

The expanded sweep contains 412,323 diagnostic rays across the twelve maps
with navigation seeds. Split accounts for 52,419, including three geometric
calibration rays. It annotates first hits using parsed material data. Unknown
bindings, ambiguous material identifiers and source meshes with unbound face
subsets remain unresolved. The standing triage also excludes back-facing hits,
origins near surfaces and height-sensitive results from correction candidates.
Its counts identify investigations; they are not gameplay error rates.

Summit's mesh-grid run adds 263,904 rays from 2,749 accepted candidate surfaces.
It scans a 3 m grid over source UV bounds 0..1, retains multiple heights at each
position and requires an upward opaque surface with 2 m of vertical clearance.
No column reaches the scan limit. This removes the navigation-data dependency
for diagnostics. It does not establish connected walkable floors: roof and
prop tops can pass, and a vertical clearance check is not a movement capsule.
Most generated directions fall outside the current authored footprint or need
further material/floor review. These samples have not become production data.

The first all-map slice run exposed a reference-tool precision fault on Pearl.
The old full-scene BVH used an intersection epsilon of 0.00001 m and reported
11.520234 m for ray `384-1.55-9`. A direct triangle calculation gives 11.525284 m;
the full-scene BVH with zero epsilon gives 11.525284 m too. The positive
allowance admitted a nearby triangle outside the exact ray. The generator now
uses zero epsilon and records it explicitly. Historical broad sweeps retain
their original files; the precise fixture rerun is separate.

The precise rerun passes all 13 maps, including Summit: one selected observer
per map, three standing-height candidates, 32 directions and both orientations
produce 2,496 comparisons. The largest difference is 0.004760 mm, on Icebox.
Split's largest difference is 0.002986 mm. These small values measure conversion
of the exported triangles, not the triangles' agreement with the live game.
The 5 mm failure threshold was not relaxed. Twelve unit tests for the new
Python helpers pass, as do the three existing USD material-audit tests and
Dart analysis of both diagnostic runners.

Current evidence paths under `2026-09-05`:

- `standing-visibility-audit.json` and `standing-all-maps` preserve the broad
  material-aware triage and its original references.
- `standing-precise` contains fixtures recast with zero BVH epsilon, their
  3D slices, Flutter verification reports and the all-map manifest.
- `split-standing-slice-comparison.png` compares the current clipping and
  prototype at the same map scale. It is a diagnostic illustration.

## The mapping fix

The installed desktop game is `release-13.05`. The mapping endpoint suggested
in the FModel VALORANT thread still returned 13.04. A September 1 reply by Marlon
supplied the matching static download:

- [FModel Discord reply](https://discord.com/channels/637265123144237061/1090601049909362739/1544390446464368723)
- [13.05 desktop mapping](https://media.valorant-api.com/mappings/release-13.05_br.usmap)

The downloaded file is 638,429 bytes, SHA-256
`4d03cda5e26c86b42d40a55e712afe1623cd2d71dc0596292850c0f9fb70170e`.
The previous mapping and FModel settings are backed up. FModel now uses this
explicit local mapping and exports into a separate `fmodel-13.05` directory.
Future version URLs must be checked for availability and tested against the
installed game; substituting a version string is not proof of compatibility.

With the correct mapping, FModel exports 3,023 Split items with zero failed
items and zero error/warning headers during the export. The old run reported
1,973 successful items while logging 2,499 errors. The log checker caught that
false success. A negative control against 13.04 still produces a material parse
error; the new command-line extractor returns failure for it.

The independent CLI uses the same CUE4Parse commit as FModel's August 30 build:
`91e1da69d3341f5777f2307bd712498b6bdc05dc`. Matching inherited-property lookup,
Nanite settings, material depth and streaming selection matters. With those
settings, all **3,725 Split files are byte-for-byte identical** to FModel's
export. `split-cli-13.05-verified-options/fmodel-comparison.json` records the
comparison. The parser assemblies, mapping, selection and archive tables are
fingerprinted in each extraction report. The expected parser commit is a build
requirement, not a substitute for the recorded assembly fingerprints.

## What improved and what did not

Split's selected Art scene imports into Blender with 930 images and no missing
image files. Its 8,311 evaluated mesh placements and 3,212,017 triangles are
unchanged. The root USD hash is also unchanged:
`affba0e92aead3f90c6b522c0a45da7c65d43b29b964d66be22e58cb1a8bde41`.
The mapping repair primarily restores material data, not displaced geometry.

Of 549 source materials used by the selected Split Art geometry, 462 parse as
opaque, 35 as masked and 52 as shader-dependent. Material names are not used to
infer opacity. Seventeen nonempty face subsets have no resolved binding, and
14 nonopaque material prims lack a USD preview-opacity input. Those cases remain
flagged. A Blender preview shader cannot replace the original game shader.

The fresh Split vision JSON is unchanged from the production asset. Across the
other maps, 11 more vision tables also have unchanged layer geometry. Ascent has
eight changed navigation sample triples, including one height moving by 50 cm.
Summit now supplies eight real vision layers, but no generated navigation height
samples were found in either its root world or Navmesh sublevel. Its candidate
retains absent height inference rather than inventing floor samples.

All generated candidates are in `candidate-vision-13.05`; none were copied into
production. Refreshing Split's existing table alone cannot fix the reported
collisions.

## All-map extraction and coverage

Twelve maps export without errors. Summit's remaining failed asset is
`Developers/BrunoAfonseca/Temp/Plummet/ASitePainting/RT_Plummet`, a
`TextureRenderTarget2D`. Its cooked dimensions are zero, pixel format is unknown
and first saved mip is -1: there is no baked image to decode. The failure remains
in its report. Four maps needed the parser's embedded texture decoder enabled;
the successful retries are identified by the final manifest.

Every map's selected reference passes mesh topology checks: no invalid indices,
nonfinite points, face-count mismatches or empty meshes. Material checks remain
unresolved on every map, so these are structural passes, not gameplay passes.
Across those references, 139 face subsets have no resolved material binding.
All referenced image files resolve after accounting for HDR cubemap exports
as well as PNG textures; the binding gaps remain explicit failures.

Selection by an `_Art_` name alone missed `Jam_ArtDefPathCExterior`,
`Juliett_ASite` and `Rook_Ground`. Explicit level lists now include those exported
architecture/floor levels. Fracture also requires an explicit list because it
uses different names. The selection report checks fresh streaming declarations
and inventories visible geometry in excluded exported levels. This catches
omissions while preserving intentionally excluded helper and state geometry.

Split includes all 36 persistent sublevels in the full export; its diagnostic
uses 21 Art sublevels. Fourteen dynamic levels remain outside the full default
export. Fracture's `Canyon_ASidePath` and `Canyon_APathNoMid` are likewise dynamic
and excluded from its persistent reference. Lighting levels can contain real
lamp geometry alongside sky domes; gameplay levels can contain barriers. These
require object/state classification before the references can establish complete
visibility. Persistent loading is not proof that a surface is active in a round.

The current all-map source and verification paths are recorded in
`all-map-reference-manifest-final.json`. Earlier selections and failed exports
are retained for comparison.

## Repeatable Split fixtures

The original 3D checker used evaluated triangles and instance transforms, with no SVG
input. It casts downward from navigation seeds to find an upward-facing surface
within 0.6 m before accepting a candidate floor. Of 286 seeds, 274 pass. Sixteen
directions at 25 m and three heights, plus three crate calibration rays, produce
13,155 rays. The heights 0.98, 1.5 and 1.7 m were test parameters, not established
camera heights. Every triangle was provisionally opaque and
two-sided.

The Flutter comparison uses the actual provider, coordinate projection,
`layerForPosition` and `VisionPolygon.compute`. Of 11,470 eligible rays, 8,010
differ by more than 0.5 m and 5,395 by more than 2 m. These counts are unchanged
after the mapping repair. They identify investigation candidates, not an error
rate: registration, materials, floor accessibility and active state still matter.

The candidate finder locates 28 crate rays across five object placements where
a higher ray clears low cover but Icarus still clips it nearby. Their origins
are inside the current footprint. One concrete fixture is
`Bonsai_Art_B/Prop_9_CrateB2/StaticMeshComponent0`:

- Source bounds: `[-34.951, 54.034, 3.000]` to `[-32.990, 55.498, 4.002]` metres.
- Horizontal origin: `[-32.475, 54.555]` metres, detected floor at 3.000 m.
- At floor +0.98 m, ray `44-0.98-9` hits the crate after 0.558 m.
- At floor +1.7 m, ray `44-1.7-9` clears it and hits a wall after 2.681 m.
- Icarus clips the higher ray after 0.337 m, selecting the 500 cm layer.
- The crate's resolved source material has opaque blend mode and no missing
  texture files. This narrows the shader uncertainty for this particular object.

The paired renders in `fmodel-13.05/b-site-crate-fixture` use those exact camera
positions. Neutral shading and an orange crate expose the geometry; these are
Blender test-camera renders, not in-game screenshots. The renderer refuses a
scene whose hash differs from the ray report.

The older Mid crate calibration still passes: its mesh is 1.30 m tall, blocks
at +0.98 m and clears at +1.5/+1.7 m. Its projected origin lies outside Icarus's
footprint, so it cannot independently establish a runtime collision defect.

## Next verification and implementation

1. Confirm the standing eye height and fixed sightline endpoints in a Split
   custom game. The existing standing/crouched screenshot pair established the
   landmark, not an exact horizontal camera. Reserve landmarks to check
   registration rather than fitting every point.
2. Establish floor selection and active map state.
   Current Icarus generation uses navigation `AgentHeight / 2`, or 98 cm for
   Split. Fresh character properties contain capsule and eye-offset defaults,
   but custom camera behavior prevents treating one field as the final view.
3. Resolve material binding gaps and classify state-dependent surfaces. Keep
   unknown surfaces flagged; never convert an extraction failure into empty space.
4. Reduce the 3D section's segment count without changing its measured hits.
   Benchmark multiple agents before integrating it into the production provider.
5. Add the gameplay-confirmed standing fixtures as regression checks, then
   apply the resulting collision data to the other maps. Keep movement limits,
   minimap outlines and visible occluders separate.

The source extraction and structural audits have expanded to all maps. The
collision rollout remains conditional on Split passing the gameplay checks.

## Reproduction and footage

Build `tool/valorant_export/ValorantExport.csproj` with .NET 10 and `CueRoot`
pointing to the recorded CUE4Parse source. The CLI takes local FModel settings,
a mapping, Oodle helper, selection JSON and a new empty output directory. The
selection has `worlds` and `properties` arrays of package paths. It never prints
or copies the local key into its report.

`prepare_world_reference.py` selects levels using `--world-json` and optional
`--include-levels`. Then run `audit_world_usd.py` and
`audit_world_materials.py` with Python and `usd-core==26.8`. Material-audit exit 1
means unresolved evidence, even when structural checks pass. Empty/unbound
reference and HDR-resolution tests are in `scripts/test_audit_world_materials.py`.

Use `blender_world_reference.py` to import the selection and
`blender_audit_world_rays.py` to cast rays. Supply `--eye-heights 1.55 1.75 1.95`
and `--materials` pointing at the source material audit. These values reproduce
the sensitivity band; they are not certified defaults. `--floor-grid 3` uses
mesh candidates instead of navigation. `--seed-reference` with `--sample-ids`
reuses a recorded fixture, verifies its scene fingerprint and recasts its floor.
Run
`flutter test --no-pub tool/compare_world_rays_test.dart` with a `WORLD_RAYS`
dart define pointing at the report. `find_world_height_candidates.py` accepts
the rays, comparison and output paths; `--object-name Crate` reproduces the
narrow fixture list. `blender_render_ray_fixture.py` renders selected ray IDs
from the fingerprinted scene.

For the 3D prototype, run `blender_export_visibility_slice.py` with
`--world-rays REPORT --sample ID --output SLICE`. Run
`flutter test --no-pub tool/verify_world_slice_test.dart` with `WORLD_RAYS` and
`WORLD_SLICE` dart defines. `audit_standing_visibility.py` takes world rays,
the runtime comparison and an output path; it rejects mismatched fingerprints.
The Python tests cover material ambiguity/unbound faces, uncertain-reference
classification, stale reports, incomplete height groups, and horizontal
triangle intersections. Raw game data stays outside the repository.

The existing `split/footage-final/split-blender-import-raw.mp4` preserves the
40-second actual import and orbit. Its 16-second annotated companion is labeled
as geometry testing with verification in progress. Those clips use the earlier
gray scene; neither demonstrates a shipped accuracy fix. The new 13.05 Blender
scene and paired fixture renders are preserved separately.
