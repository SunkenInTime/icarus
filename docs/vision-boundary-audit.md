# Vision boundary audit

Historical investigation. For current implementation decisions, follow
[the visibility model](vision-model.md).

September 4, 2026. Runtime inspected at `5861ee3`, after the Sunset scale fix.

Renyxx reported choppy collisions on Split. The current implementation contains
specific approximations that can explain this class of problem, but the report
does not identify a particular in-game camera position. No individual sightline
has yet been certified against current gameplay.

The first automated audit is implemented. It loads the actual runtime provider,
including SVGs, additions, overrides, and committed manual edits, then exports
every map's boundaries and their evidence by elevation. Its output explicitly
reports `diagnostic-only` and zero independently verified sightlines. A passing
tool run means the diagnostic export succeeded, not that the geometry is right.

## What Split does today

Split has five extracted contour elevations: 0, 300, 500, 650, and 950.
Their edge counts are 289, 280, 271, 257, and 251. The runtime attack side uses
the same 426 blocking segments at every elevation. The defense side likewise
uses the same 423 segments at every elevation. These counts are before
observer-specific exclusions.

There are 64 attack-side collision groups. Eleven active, non-outer groups have
no contour match under the current projection. Another 26 block on elevations
beyond those where they have a match. Twelve groups support observer-specific
exclusions. These categories overlap and are not counts of confirmed bugs.

The reason is visible in [withSvgBoundaries](../lib/view_cone/vision_geometry.dart).
Once admitted, a group initially blocks every layer. Evidence controls admission
and diagnostics; it does not generally limit the group to its supported heights.
Map-specific overrides can narrow that mask. Split has no entries in the
committed boundary-edit or contour-override documents at this revision.

There are further sources of uncertainty:

- The outer footprint always clips sight, and base-fill contours are treated as
  walls. A map drawing does not tell us whether a ledge is opaque at eye height.
- UV projection reconstructs an independently padded width and height from the
  SVG. The diagnostic overlay visibly exposes registration differences. A
  mismatch is not grounds to delete a wall until registration is calibrated.
- The generator derives `observerHeight` from `RecastNavMesh.AgentHeight / 2`.
  Split stores 98. This is a navigation-derived proxy, not a verified camera-eye
  offset. See [the generator](../tool/generate_view_cone_geometry.dart).
- The height field uses nearby navigation-link endpoints and chooses the higher
  surface when sample positions overlap. A 2D position cannot tell us whether an
  agent is on the upper or lower floor. See [VisionHeightField](../lib/view_cone/vision_geometry.dart).

The existing geometry tests check implementation invariants, such as respecting
authored walls. They cannot establish that a wall should block sight in Valorant.

## What the local extraction can support

The source inventory reads only four named Split level files and the mesh JSONs
they reference. These selected files contain 1,651 static-mesh components and
188 unique explicit mesh references. All 188 referenced JSON files are present.

Of those mesh assets, 42 contain readable simple convex collision vertices and
106 specify `UseComplexAsSimple`. The exported render position buffers expose
`NumVertices` and `Stride`, without the actual position arrays. A convex proxy
must not stand in for the required triangle mesh.

Another 735 components require inherited mesh defaults, and one explicitly
clears its mesh. Sixty-eight component records explicitly ignore the Visibility
trace channel; the rest inherit their response. Missing overrides must not be
interpreted as either blocking or passing sight.

This is a resource inventory, not an active-world reconstruction. We still need
to resolve streamed-level membership, actor/component attachment transforms,
blueprint defaults, collision profiles, and materials. Visibility-channel
collision is also not identical to visual occlusion from the player's camera.
The extracted files have hashes. The retained FModel log records a June 20,
2026 session with FModel 4.4.4.0 and `VALORANT_12.11_zs.usmap` mappings. This
dates that extraction session, but does not independently identify the build
of every exported asset.

## Whole-map export is available

FModel's [August 2026 release](https://github.com/4sval/FModel/releases/tag/aug-2026)
adds whole-world export as `.usda`, including placed static meshes, instanced
meshes, skeletal meshes, landscapes, and streaming levels. Its Export Session
window supports batch world exports and per-session output settings. The
release notes identify socket/attachment placement as a remaining limitation.

Use that complete scene export for Split, whose package is
`/Game/Maps/Bonsai/Bonsai`, including its relevant streaming levels. Keep the
existing JSON export as complementary metadata. The missing triangle arrays
described above are a limitation of the inspected JSON files, not a claim that
FModel cannot export the full map. A fresh scene export is the direct path to
the independent reference, followed by validation of scene completeness,
transforms, units, material visibility, and camera height.

The installed game directory was found at `E:\Games\Valorant`. The subsequent
[Split world-reference experiment](split-world-reference.md) exported and loaded
the real scene, built independent triangle queries, and captured Blender footage.
It also found parser/material failures that prevent gameplay certification.

## A reliable verification path

1. Define the sightline being checked as a world-space camera position and a
   world-space target. Include floor, standing/crouching stance, and dynamic
   state. Decide whether a cone means visual coverage at eye height or whether
   any part of a target player is exposed. These are different tests.
2. Export actual mesh positions and triangle indices, then reconstruct the
   relevant active scene with resolved transforms and material/occlusion rules.
   Keep navigation, movement collision, visual occlusion, and minimap artwork
   as separate inputs. Record unresolved objects rather than declaring space
   empty. Calibrate world-to-SVG registration against fixed landmarks.
3. Sample camera/target pairs automatically near walls, low cover, railings,
   windows, stairs, and stacked floors. Compare independent 3D visibility queries
   with Icarus's prediction. Emit both endpoints, the first blocking object,
   source hashes, height/state, and an image of every disagreement. Repeat near
   each candidate with small position changes to catch abrupt cone behavior.
4. Store verified sightlines as regression fixtures with their evidence and
   patch version. Add the known manual corrections to that corpus. The checker
   should fail on a changed verified result and report missing evidence as
   unresolved. Tests generated from Icarus's own boundaries are not independent
   verification. A small initial set of gameplay checks is still needed to
   validate the reconstructed scene and its visibility semantics.

This can automate broad coverage and repeat testing after patches. It cannot
honestly certify 100% accuracy from the current incomplete JSON export alone.
The immediate next implementation is calibrated projection plus proper blocker
height semantics. Removing every unmatched contour would create new leaks.

The map UI should eventually distinguish full-height walls from low cover and
unresolved boundaries, and expose floor selection where the same 2D position
has multiple heights. Those cues should follow verified data. This audit makes
no production boundary or UI changes.

## Reproduce

```powershell
# Reads the same assets and classification path as the application.
flutter test tool/audit_vision_boundaries_test.dart

# Or inspect one map.
flutter test tool/audit_vision_boundaries_test.dart --dart-define=VISION_MAP=split

# Requires matplotlib. Produces a four-panel technical comparison.
python scripts/plot_vision_audit.py build/vision-audit/split.json

# Reads selected map levels and their explicit mesh references only.
python scripts/audit_vision_sources.py --content-root "D:\Downloads\Output\Exports\ShooterGame\Content"
```

Outputs are under `build/vision-audit`: per-map JSON with source hashes, group
IDs, paths, masks, confidence and flags; `summary.json`; `split-comparison.png`;
and `split-sources.json`. The PNG compares current blockers, projected extracted
contours, evidence candidates, and the lowest/highest source layers. The JSON
keeps the assumptions visible for subsequent investigations.
