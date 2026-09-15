# Finite wall heights across all maps

This revision replaces all 423 structural height assumptions in the earlier
all-map assets. All 13 maps, on attack and defense, have finite wall intervals
and no unknown-height records. The SVG still defines the exact painted wall
footprints. The source mesh supplies local heights and openings.

The review corrected the missing opposite Icebox Nest end, separated lower
passages from upper structures on Fracture and Corrode, and resolved further
openings on Abyss, Ascent, Breeze, Haven, Lotus, and Summit. Local source checks
also corrected furniture and floor edges that had inherited nearby building,
ceiling, or scenery heights. Shared edges between boxes and taller walls retain
the taller wall's measured interval.

Source evidence and production rendering are separate acceptance checks. The
source audit covers all 423 original records with 86,263 rays. Its 1,956 raw
source/SVG differences remain recorded, with separate decisions explaining
authored corner registration, scenery absent from the artwork, previously
reviewed finite cover, and unconfirmed asset gaps. An extracted asset gap alone
does not authorize a gameplay opening. These decisions follow
[the visibility model](vision-model.md).

The final production exports contain 3,042 valid cones and 586 painter images
across both sides of every map. Native and Dart boundaries agree within
0.000001 SVG units, and the tested standing eye elevations match their fixtures.
Independent GEOS audits found no polygon-contact errors above 0.002 SVG units.
The original audit checked 463,583 intervals; a replacement Fracture export
checked 59,600 intervals. These counts overlap and must not be added as unique
coverage. Two original Fracture fixtures were inside authored wall ink and were
replaced with legal source-backed origins. Sixteen inspection sheets containing
186 selected images and the two replacement crops were personally inspected.

All 26 compressed assets total 10,285,672 bytes. Test-process median native query
time including automatic standing selection ranged from 0.121 to 1.279 ms per
map. The highest per-map p95 was 5.928 ms, and the largest observed query was
18.605 ms. These are query measurements, not desktop frame-time measurements.
Supports and ground are byte-for-byte equivalent as decoded records to the
previous verified revision, preserving its 410 automatic supports and evidence
from 37,366 sampled standing positions. That evidence was reused, not resampled.

The source workspace is
`E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/all-map-finite-heights-v7`.
Per-map source profiles retain face and object identities. Raw sightline reports
are intentionally preserved separately from `source-height-semantic-review.json`.
`production-verification.json` binds the candidates, fixtures, exports, and
boundary audits by file hash. `asset-integrity.json` records installation.

The installer checks finite positive intervals, source-review coverage and
freshness, standing evidence, unchanged artwork geometry, and both side models
before copying any asset. The release preflight also rejects unknown, infinite,
reversed, and zero-width intervals. A `reviewed` label cannot bypass these checks.

Delivery passed 21 Python regression tests and 48 targeted Flutter tests. The
Windows profile build completed, and all 26 built and served asset hashes match
the reviewed candidates. The shared review URL now serves this revision. Both
saved Icebox review files remain byte-identical and all eight saved poses return
valid cones. The desktop app was left closed.

This closes the assumed-wall-height inventory. It does not establish every live
game sightline exhaustively, or resolve the separate physical-floor eligibility
findings retained in [the earlier standing review](all-map-gameplay-review.md).
Crouching and changing door states remain outside this pass.
