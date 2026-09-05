# Valorant world reference, updated September 5, 2026

Version-matched mappings repair the Split import. The same extraction process
has now run across all 13 Icarus maps. This establishes usable source data and
repeatable diagnostics; it does not certify gameplay sightlines. Production
collision assets remain unchanged. The earlier Sunset scale fix is merged in
PR #159.

Local evidence lives under `E:/IcarusWorldAudit/2026-09-04`. Raw game assets and
settings stay outside the repository. Reports supplement the explanation in
chat, as specified in [answers.md](../answers.md).

## In-game check, September 5

Dara clarified the intended model: a horizontal sightline at the observer's
eye height is blocked when geometry intersects that height. Low cover below
that plane should not block it. The world height must include the observer's
floor elevation; crouching requires a separate eye offset if supported. This
model deliberately does not simulate looking up or down. Stacked floors still
need explicit floor selection. The screenshot pair is landmark evidence, not
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
is not sufficient evidence to adopt a new standing/crouching height. No fitted
camera value has been copied into production.

The production comparison runner now also tests the raw game vision layers,
before SVG contours replace their segments. For recorded ray `44-1.7-9`, current
Icarus clips at 0.337 m, raw game geometry at 2.886 m, and the exported triangles
at 2.681 m. This isolates a useful distinction between the authored boundary
and the source visibility data. Those distances are from the diagnostic ray,
not measurements of the in-game screenshots.

The 13,155-ray runner passes with this additional comparison. Raw geometry is
not automatically certified: 2,564 eligible diagnostic rays still differ from
the triangle reference by over 0.5 m, and the raw layers omit the low crate in
the 0.98 m sensitivity test. These counts are not gameplay error rates. The
next implementation should preserve SVG appearance while testing visibility
geometry separately, with confirmed camera/floor semantics and explicit
exceptions. A wholesale switch to raw layers has not been made.

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

The 3D checker uses evaluated triangles and instance transforms, with no SVG
input. It casts downward from navigation seeds to find an upward-facing surface
within 0.6 m before accepting a candidate floor. Of 286 seeds, 274 pass. Sixteen
directions at 25 m and three heights, plus three crate calibration rays, produce
13,155 rays. The heights 0.98, 1.5 and 1.7 m are test parameters, not established
standing/crouching camera heights. Every triangle is provisionally opaque and
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

1. Confirm fixed structural reference points and these camera/target fixtures
   in a Split custom game. Reserve some landmarks to check registration rather
   than fitting every point. The local Riot Client is currently at sign-in.
2. Establish actual standing/crouching camera heights and floor/state handling.
   Current Icarus generation uses navigation `AgentHeight / 2`, or 98 cm for
   Split. Fresh character properties contain capsule and eye-offset defaults,
   but custom camera behavior prevents treating one field as the final view.
3. Resolve material binding gaps and classify state-dependent surfaces. Keep
   unknown surfaces flagged; never convert an extraction failure into empty space.
4. Use verified height intervals and states for sightline blockers while keeping
   SVG appearance unchanged. Authored groups currently default to every layer;
   movement limits, minimap outlines and visible occluders need distinct meaning.
5. Add the confirmed fixtures as regression checks, then run the same validation
   and apply the resulting collision correction to the other maps.

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
`blender_audit_world_rays.py` to cast rays. Run
`flutter test --no-pub tool/compare_world_rays_test.dart` with a `WORLD_RAYS`
dart define pointing at the report. `find_world_height_candidates.py` accepts
the rays, comparison and output paths; `--object-name Crate` reproduces the
narrow fixture list. `blender_render_ray_fixture.py` renders selected ray IDs
from the fingerprinted scene.

The existing `split/footage-final/split-blender-import-raw.mp4` preserves the
40-second actual import and orbit. Its 16-second annotated companion is labeled
as geometry testing with verification in progress. Those clips use the earlier
gray scene; neither demonstrates a shipped accuracy fix. The new 13.05 Blender
scene and paired fixture renders are preserved separately.
