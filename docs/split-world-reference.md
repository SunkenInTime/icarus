# Split world reference, September 4, 2026

Split now exports into a real, inspectable Blender scene. The independent
triangle checker and the Icarus comparison runner both work. The export does
**not** yet pass the checks needed to certify gameplay sightlines or replace
the collision boundaries on every map.

The local evidence and footage are under
`E:\IcarusWorldAudit\2026-09-04`. Exported game assets remain local. No production
map, saved strategy, library model, or Figma asset changed in this experiment.
The earlier Sunset scaling fix was already merged in PR #159.

## What was reconstructed

FModel exported `/Game/Maps/Bonsai/Bonsai` from the installed game. All 36
`LevelStreamingAlwaysLoaded` sublevels listed in the fresh root JSON are
present. The 14 missing referenced levels are all `LevelStreamingDynamic`.
They include alternate modes, spawn barriers, greybox/test levels and camera
data. This establishes persistent-level coverage, not every runtime state.

The USD has Z up and `metersPerUnit = 0.01`. FModel converts Unreal coordinates
to `(X, -Y, Z)` and Blender then converts centimetres to metres. The root USD
SHA-256 is
`affba0e92aead3f90c6b522c0a45da7c65d43b29b964d66be22e58cb1a8bde41`.

The full export contains 5,339 mesh definitions including instancer prototypes.
Those are not 5,339 placed objects. For the 21 selected Art sublevels, Blender's
evaluated scene expands to 2,649 ordinary mesh occurrences and 5,662 instance
placements, a total of **8,311 placements and 3,212,017 triangles**. Prototype
definitions are not counted again as visible objects.

Pawn/projectile blockers, navigation, callout/kill volumes, VFX and gameplay
helpers are excluded from this visual-art diagnostic. The full export is kept
unchanged alongside that derived selection. The only USD Cube is the gameplay
`CompassPOI_Base/DefaultSceneRoot/Sphere`; it is not part of the Art reference.
The exporter can emit placeholder cubes, so these must be inspected rather
than accepted as walls.

## The export's success counter is insufficient

Both FModel's August 2 release and August 30 development build report 1,973
successful exports and zero failed exports. The latest export's log interval
contains **2,499 error headers**, including repeated parse failures for 1,999
material-instance reads and 419 material reads. These counts include repeated
reads, not that many unique assets. There are also spawn-barrier and minimap
object errors. The checker rejects this export interval despite the green
queue counter.

The installed shipping executable contains `release-13.05`. The mapping service
supplied `VALORANT_13.04_zs.usmap`, dated August 20. This mismatch is a possible
cause, not a proven diagnosis of every parse error. Trying the newer exporter
did not resolve it. A compatible parser and mappings must read the affected
assets without silently returning default properties.

Only five texture images are used in the selected Art scene. Empty material
parameters and a default `BLEND_Opaque` cannot establish that a surface blocks
sight. The diagnostic treats all selected triangles as opaque and two-sided,
and labels every result provisional. The neutral Blender shading makes this
limitation visible.

## The independent tests

The Blender checker builds a BVH from evaluated mesh triangles and full instance
transforms. It samples every other navigation height point from the existing
Split asset. Those older navigation samples only seed positions. A downward
query against the new triangles must find an upward-facing floor within 0.6 m
before a sample is used. Of 286 seeds, 274 pass that geometric check.

Each accepted floor seeds 16 directions, a 25 m range and three heights above
the floor: 0.98 m, 1.5 m and 1.7 m. These are sensitivity-test values, not verified
standing/crouching camera heights. Three additional crate checks bring the
total to **13,155 rays**. Each ray records its endpoints, hit distance, normal,
blocking object and source fingerprints.

One concrete check uses
`Bonsai_Art_Mid/Crate_1_Wood_8/StaticMeshComponent0`. Its exported bounds are
approximately `[-2.106, 32.692, 3.500]` to `[-0.806, 33.992, 4.800]` metres.
The mesh is 1.30 m tall. A ray 0.98 m above its base hits the crate after
0.523 m; rays at 1.5 m and 1.7 m pass above it. These assertions pass against
the full selected Art scene, not a fabricated box. The comparison figure uses
a rectangle only to illustrate the mesh bounds.

The Flutter runner loads the same assets and provider as Icarus. It invokes the
production UV projection and `VisionPolygon.compute`, including stroke and
observer-exclusion behavior, with zero display clearance. It compares the exact
center ray at an explicit world elevation. It also records which elevation the
normal inferred-height path would select.

There are 11,470 comparison rays whose origins are inside the current footprint
and at least 0.1 m from the first reference hit. Of these, 8,010 differ by over
0.5 m and 5,395 by over 2 m. **These are investigation candidates, not an error
rate.** Registration, material opacity, navigation age, floor selection and
deliberate map-art simplification can all contribute.

The crate test's current projected origin lies outside Icarus's footprint. It
is therefore excluded from those comparison totals. Its successful 3D height
test does not yet prove a corresponding Icarus wall should be removed.

## What needs fixing next

1. Resolve the export's parser/material failures and explicitly select the
   desired gameplay state. Retain unknown objects as unknown, never empty space.
2. Register several fixed structural landmarks across Split, reserving other
   landmarks to validate that transform. The current overlay shows local
   displacement as well as deliberately simplified contours. Fitting one
   percentage to all discrepancies would hide those differences.
3. Establish camera-height semantics. The current generator derives
   `observerHeight = AgentHeight / 2` from navigation settings, giving Split
   98 cm. Half a navigation capsule is not evidence of player eye height.
   `layerForPosition` then picks the nearest source elevation. At the crate,
   the three tested world heights all select the same 500 cm layer.
4. Add verified blocker height intervals and floor/state selection where
   required. Currently admitted authored groups default to every elevation.
   A minimap outline, movement collider and visual wall cannot share that
   meaning automatically. Preserve authored appearance independently of the
   geometry used for sightline tests.
5. Validate a small set of in-game camera/target fixtures, including this low
   cover, a solid wall, a railing/window and stacked floors. Then use the
   automatic sweep to discover candidates and guard verified fixtures after
   patches. Expand to other maps after Split passes these evidence checks.

The tools reduce the amount of manual auditing substantially. They do not
eliminate the need to validate the reference itself. No all-map collision
rollout was made because Split has not passed that requirement.

## Reproduce

Use Blender 5.2.1 LTS and Python with `usd-core`. The local Python environment
uses `usd-core==26.8`; plotting also uses NumPy and Matplotlib. The Blender
scripts run with Blender's Python and its bundled NumPy.

```powershell
python scripts/audit_world_usd.py WORLD.usda inventory.json --world-json Bonsai.json
python scripts/audit_fmodel_export_log.py FModel.log --since "2026-09-04 21:28:26" --until "2026-09-04 21:28:35" --output log-audit.json
# Expected exit 1 for the current export: parser errors were found.

python scripts/prepare_world_reference.py WORLD.usda split-static-art.usda
blender --background --factory-startup --python scripts/blender_world_reference.py -- split-static-art.usda OUTPUT --name split-art
blender --background OUTPUT/split-art-reference.blend --python scripts/blender_audit_world_rays.py -- --navigation assets/maps/split_vision.json --ui-data Bonsai_UIData.json --output world-rays.json
flutter test --no-pub tool/compare_world_rays_test.dart --dart-define=WORLD_RAYS=PATH_TO_WORLD_RAYS_JSON
python scripts/plot_world_comparison.py world-rays.json build/vision-audit/split-world-comparison.json build/vision-audit/split.json comparison.png
```

The figure also needs `split.json` from `tool/audit_vision_boundaries_test.dart`.
Full source and runtime fingerprints are stored in the JSON reports. The
selection file records exactly which layers the Art scene uses.

## Footage and claims

`split/footage-final/split-blender-import-raw.mp4` is a 40-second, 1600 x 900,
30 fps capture of the actual USD import and live camera orbit. Loading time is
preserved. Windows briefly labels Blender unresponsive while the synchronous
import runs. The scene then loads successfully. Only the Blender window's
rectangle was recorded; there is no audio.

`split/footage-final/icarus-split-geometry-preview.mp4` is a 16-second annotated
excerpt of that recording after loading. It says "Testing sightlines against
extracted map geometry" and labels material/gameplay verification as in
progress. The raw recording is retained for editing and comparison. Neither
clip contains generated imagery or demonstrates a shipped accuracy fix.

The saved `.blend` scenes and their USD dependencies remain local. The original
export, the first material-depth backup, and the retry export are all retained.

## Primary references

- [FModel August world-export release](https://github.com/4sval/FModel/releases/tag/aug-2026)
- [CUE4Parse source used by the August release](https://github.com/FabianFG/CUE4Parse/tree/7afcbb323c9fd9445d5452856b18b1d732d2dccd)
- [Mapping service inspected for this run](https://uedb.dev/svc/api/v1/valorant/mappings)
- [Official Valorant 13.05 patch notes](https://playvalorant.com/en-us/news/game-updates/valorant-patch-notes-13-05/)
- [Official Blender 5.2 downloads](https://download.blender.org/release/Blender5.2/)
