# Standing camera and player dimensions

Use **1.75 m above the selected floor** as the standing visibility build parameter.
This is an inference from version-matched game assets and Unreal's documented
coordinate convention. It is the best supported working value found in this
audit, but it is not an exact measurement of VALORANT's native camera at runtime.
Crouching, jumping, pitch and temporary camera effects are outside this model.

The release 13.05 export contains `CapsuleHalfHeight = 98` and `BaseEyeHeight = 77`
on `BasePawn`. Epic defines `BaseEyeHeight` as height above the collision center.
The nominal standing calculation is therefore `(98 + 77) / 100 = 1.75 m`.
The capsule half-height already includes its hemisphere end cap.
[Epic APawn documentation](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/APawn),
[Epic capsule documentation](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/UCapsuleComponent).

The inherited class matters. `BasePlayerCharacter` inherits `BasePawn` without a
serialized eye-height override. A scan of 32 `*_PC` assets found no serialized
eye-height, capsule-dimension or component-scale overrides in the 31 non-training
assets. This includes auxiliary player forms as well as the main characters.
It does not prove that native code never changes a property.

There are reasons not to label 1.75 m an exact runtime constant. `BasePawn` also
contains the custom field `StandingEyeOffset = -22`. `BasePlayerCharacter` has
`TargetEyeHeightProportion = 0.7`. Their names alone do not establish an equation.
`BaseShooterCamera` inherits native `ShooterCamera`; its cooked Blueprint exposes
spectator settings but no standing camera calculation. Epic's eye-height API can
also recalculate the height for the current state. Adding the -22 cm offset to
77 cm a second time would be an unsupported assumption.

Targeted internet searches did not find a Riot-published standing camera height.
The often repeated 1.96 m agent dimension is full collision height, not camera
height. Lore heights and screenshots without calibrated perspective cannot
replace that distinction.

The Split standing/crouched image pair does not settle the camera height. With
horizontal FOV fixed at 103 degrees, all ten manually selected landmarks give
1.8479 m above the floor and 3.504 px fit RMS. Omitting the right crate corner
from both images changes the fitted height to 1.7731 m and RMS to 2.765 px.
Omitting the left corner instead gives 1.8207 m and 2.067 px. The omitted points
then miss by as much as 26 px. These fits expose sensitivity to the selected
image corners; choosing the fit closest to 1.75 m would not validate that value.
All ten assigned world coordinates match exported mesh vertices within 0.072 mm,
but that does not prove the image points identify those same vertices.

A separate source-physics check rules out a 10 cm floor offset at these fitted
positions. `Bonsai_BVPawn/BP_BlockingVolume412` carries `WalkableGround` and uses
a placed box whose physical top is 3.00000036 m. The Art floor is 3.00000094 m,
less than 1 micrometre apart. Both fitted positions lie inside this box. This
checks one Split floor, not every map's agreement between rendered scenery and
pawn collision. Riot's native camera calculation and any character floor
clearance remain unmeasured.

Bind demonstrates why the chosen floor also needs source evidence. At the
audited sandbag position, the old Art floor is 3.902903 m and correcting its
mirrored winding gives 4.190770 m. A separate hidden walkable slope has a native
convex collision top at 4.050674 m. The scoped Bind correction uses that native
hull. Its render mesh is about 0.99 cm lower than the collision hull.

Surface height still differs from capsule contact height on a slope. For this
isolated plane, a 42 cm radius capsule's bottom hemisphere adds
`0.42 × (1 / normalZ - 1) = 0.0533905 m` of vertical clearance. Its geometric
bottom would therefore be 4.104065 m at the probe. This calculation excludes
engine contact offsets, other support shapes and native movement or camera
code. The visibility build retains the explicit 1.75 m above selected surface
approximation; it does not claim to simulate those effects.
The native vertices, placed transform, hashes and separate height calculations
are in `E:/IcarusWorldAudit/2026-09-06/mirrored-floor-audit/bvpawn-reference/bind-native-convex-column.json`.

Build the detailed sections at 1.75 m and compare sampled rays at 1.70 and 1.80 m.
Record places where that change crosses a cover edge. These are useful boundary
checks, not statistical confidence limits or additional player stances. The
offline height parameter and source fingerprints allow a later correction to
regenerate every map consistently.

The source and sensitivity checks are recorded in
`E:/IcarusWorldAudit/2026-09-06/camera/split-stance-floor-audit.json` and
`E:/IcarusWorldAudit/2026-09-06/camera/stance-landmark-sensitivity.json`.
`stance-landmark-check.png` in the same folder shows the image correspondences.
Keep 1.75 m as the explicit working parameter until a controlled capture with
independent, well-spaced image landmarks or a native camera equation resolves
the uncertainty. Agreement between our bake and our 3D reference tests the bake
at that parameter; it does not independently verify the parameter in the game.

The same extraction provides better pathfinding dimensions. The player class
overrides the generic pawn navigation defaults:

| Source | Radius | Full height | Step height |
| --- | ---: | ---: | ---: |
| `BasePawn.CollisionCylinder` | 42 cm | 196 cm | Not specified |
| `BasePawn.CharMoveComp.NavAgentProps` | 28 cm | 170 cm | Not specified |
| `BasePlayerCharacter.CharMoveComp.NavAgentProps` | 42 cm | 196 cm | 45 cm |

Use the player dimensions for player clearance. The shipped Recast configuration
has separate bake defaults, including a 44-degree maximum slope, a 35 cm maximum
step and 5 cm by 10 cm cells. Those defaults are not proof that the player's
movement step is 35 cm, nor that every baked map used those defaults.

Evidence lives outside the repository in
`E:/IcarusWorldAudit/2026-09-06/camera/standing-camera-evidence.json`. It records
the property values, source SHA-256 fingerprints, extraction audit fingerprints
and limitations. The two fresh extraction runs loaded 38 selected property
packages with zero errors. The six shipped configuration files were read from
the installed archives without modifying the game installation. Local settings
and unrelated configuration contents are not included in this document.
