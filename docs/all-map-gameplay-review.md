# All-map standing and sightline revision

The [September 13 reopened review](reopened-map-review-2026-09-13.md) records
the current corrections and remaining obligations after Fracture failures.
The full gameplay review is still incomplete. Earlier scan and focused-queue
results must not be read as verification that every map is correct.

Later source-complete revisions are installed for
[Icebox](icebox-expanded-acceptance-report.md) and
[Bind](bind-acceptance-report.md), as of September 9, 2026. Their reports supersede
this page's earlier standing findings for those maps. The measurements below
describe the September 7 revision; acceptance of the remaining maps is ongoing.

The September 7, 2026 revision is bundled for all 13 maps, on attack and defense.
It contains 410 automatically selectable support records, including the seven
previously reviewed Icebox supports. Runtime selects the highest eligible local
surface and preserves explicit lower-floor selection. Inclined supports evaluate
their height at the observer's position instead of flattening the whole ramp.

This is an implemented extension with verified source-backed additions. The
complete gameplay-height audit remains unfinished. The unresolved findings below
must not be presented as confirmed game behavior.

## What changed

- Separated stacked physical floors so the default can choose an upper playable
  floor while the lower-floor command still selects the passage beneath it.
- Added flat and inclined standing domains from original navigation, serialized
  player collision, and measured floor faces. Clipped them against the player
  capsule, ceilings, competing floors, and SVG blockers.
- Measured additional prop heights on Abyss, Ascent, Breeze, Fracture, Haven,
  Icebox, and Pearl. Applied the reviewed Lotus stepwell rim and Pearl B Hall
  window intervals. These records change vertical blocking only.
- Filled the short Icebox Tube landing between its flat hallway and ramp. Its
  physical floor is 4.687214665 m, corroborated by blocking volume 166 and original
  navigation triangles 788 and 789.
- Preserved existing support records, map artwork, painted wall footprints,
  receiver geometry, map dimensions, and saved positions.

Unknown collision defaults remain exclusions rather than evidence of a playable
floor. Convex collision uses rounded capsule clearance on the local floor plane.
The complex-mesh fallback is conservative and can exclude valid edge positions.

## Verification

The final bundled geometry passed 37,366 sampled standing checks and eight Python
geometry tests. The 75 focused Flutter tests passed, including the four saved
Icebox poses, continuous ramp movement, lower floors, wall openings, and existing
visibility regressions. The Windows profile application built successfully.

The production cone exporter compared native and Dart boundaries for 1,284 poses
across all 26 map models. Independent GEOS checks found no flagged contacts in
58,432 polygon intervals. I inspected 156 production painter crops across all
maps. After adding the Tube landing, two additional native/Dart poses and painter
crops passed; their independent audit checked another 129 intervals without flags.
These checks establish agreement with the chosen SVG and height records. They do
not establish that every chosen height matches live gameplay.

The compressed map assets total 5,246,225 bytes. In the Flutter test process,
per-map median native query time including automatic standing selection ranged
from 0.122 to 0.292 ms. Breeze's p95 was 4.508 ms and the largest observed query
was 11.853 ms. These are test-process query measurements, not desktop frame times.

All 26 assets served by the review backend and included in the Windows build
matched the installed asset hashes. Saved Icebox review
`1788823493671-212d5f8` remains byte-identical. Its four poses return valid cones.
The browser displayed its annotations and automatic standing choices; explicit
lower-floor selection also worked before restoring the original saved scene.

## Remaining findings

Counts below are sampled audit positions, not distinct platforms or confirmed
bugs. The source comparison retained:

- 452 positions whose physical floor is unresolved, including 246 on Bind and
  167 on Icebox. Missing serialized collision/default information prevents
  treating the corresponding rendered floor as physical evidence.
- 263 positions with a measured physical floor but no accepted standing domain.
  Some are floor junctions or capsule edges. Others need a fuller domain review.
- 632 positions in detached navigation regions whose gameplay eligibility is
  unconfirmed. Navigation alone cannot approve roofs or reject confirmed boosts.

The later [finite wall-height revision](finite-wall-height-review.md) replaces
the 423 wall assumptions discussed below. The floor findings remain separate.

At the time of this standing review, 423 wall records used an infinite-height structural assumption,
counted once per map rather than again for defense. The raised-source ray audit
records discrepancies for follow-up. A mismatch can reflect SVG registration,
an intentional tactical blocker, or an incorrect height; it is not automatically
a reason to make a wall transparent. Summit's source comparison used current raw
triangles because its older prepared height pack did not match. Material-alpha
interpretation remains unresolved for that fallback.

Prioritize the unresolved Bind fountain and Icebox Defender A floor groups, then
the measured floors lacking standing domains. Confirm the named floor and its
usable standing extent through gameplay or additional authoritative collision
evidence. Review the remaining structural wall assumptions from those confirmed
elevations afterward. Gameplay references are needed where extraction cannot
resolve eligibility or a usable opening. Crouching and changing door states
remain outside this pass.

## Reproduction and evidence

The offline source workspace is
`E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/all-map-gameplay-v5`.
It contains immutable `before-attack.json.gz` and `before-defense.json.gz` files
per map, the candidates, measured source decisions, and validation results.

Run `scripts/build_all_map_gameplay_revision.py` with the source workspace's
Python environment to rebuild the ordered collision, wall, floor, support, and
verification stages. `scripts/install_all_map_gameplay_revision.py --install`
validates every candidate, its verification hash, and preserved geometry before
copying any of the 26 assets. It does not use raw 3D edges as runtime walls.

`final-summary.json`, `asset-integrity.json`, `delivery-verification.json`, and
each map's `support-verification.json` record the installed revision. See
`production-boundary-and-timing.json`, `production-renders-final`, and
`production-renders-tube-final` for geometry and painter checks. Per-map
`floor-findings.json` and `raised-sightlines.json` retain unresolved evidence.

The shared review URL is
<https://dara-pc-duo.tailba589e.ts.net:8444/?review=1788823493671-212d5f8>.
It uses the same native engine and bundled map assets. The desktop profile build
is `build/windows/x64/runner/Profile/icarus.exe`; the app was left closed.
