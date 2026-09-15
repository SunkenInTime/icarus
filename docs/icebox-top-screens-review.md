# Icebox Top Screens standing correction

Saved review `1788883963581-57243566`, cone 4, exposed a missing standing surface.
The origin is attack SVG `[295.4071895778179, 165.47969688475132]`. Automatic
standing selected the lower ground and placed the eye at 3.25672 m. The nearby
Screens structure reaches 6.97108 m, so it blocked the ray after 3.41644 SVG units.

The source provides a 7.00 m physical standing floor on
`/Port_BVPawn/BP_BlockingVolume167/Cube#0`, with matching navigation at 7.10 m and
the visible `WarehouseSignA` mesh at 6.97108 m. The navigation offset is not the
physical floor height. Standing on this surface gives an eye height of 8.75 m.
Top Screens is a named playable position, corroborated by this
[cargo-to-Screens jump demonstration](https://www.youtube.com/watch?v=vN1DKX1Fhws)
and the inspected in-game callout image in the source report.

The earlier standing audit had already measured 16 eligible positions on this
object, with clear player space. The builder left them unconfirmed because
navigation island 24 was disconnected from the main region and the source
object lacked a named gameplay role. The later finite-wall revision preserved
that incomplete support list. Verifying wall heights did not close the known
standing-surface omission.

The correction adds `icebox-a-top-screens` on attack and defense, using the exact
physical top, navigation overlap, player clearance, displayed floor and active
SVG walls to bound its standing domain. It also records the gameplay role for
future support builds. All existing supports, walls, ground and SVG artwork are
unchanged. Explicit lower-level selection remains available.

Verification covered 82 physical standing positions and 24 production cones on
both sides. Native and Dart outputs agree; independent polygon checks found no
flagged contacts in 2,801 intervals. The four production painter crops were
personally inspected. The new regression failed on both old assets and passes
on both corrected assets. All 12 standing tests pass; the 13 asset and app
integration checks also pass. The Windows profile build and all 26 built and
served asset hashes were verified. The app was left closed.

The updated backend selects the 8.75 m eye and preserves the full 56.04072 SVG
unit center sightline. The saved review remains byte-identical. The shared
[review link](https://dara-pc-duo.tailba589e.ts.net:8444/?review=1788883963581-57243566)
serves the corrected assets. Other unconfirmed standing-surface candidates
remain separate work; this correction does not certify them.

Reproduction: `scripts/review_icebox_top_screens.py`. Source evidence, immutable
before files, candidates, production exports and delivery checks are under
`E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/icebox-top-screens-v8`.
