# Assumed wall height review, September 8, 2026

The inventory and review are complete. Replacing all assumed heights is not
complete, and the candidate assets are blocked from installation and release.

There are **852 stored assumptions** in the installed map assets: 423 attack
records and 429 defense records across 13 maps. The sides sometimes partition
the same painted wall differently, so record counts are not interchangeable.
All 423 attack records have `unknownHeight: false` despite an unbounded height;
416 also trace back to an explicit `reviewed` source decision. That acceptance
loophole allowed an assumption to look like verified source data.

The complete record inventory, findings, source identifiers, candidate hashes,
and evidence locations are in
[the compact ledger](assumed-wall-height-review-2026-09-08.json).
The full measurements and images are under
`E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/all-map-height-resolution-v6`.

| Map | Original attack | Original defense | Remaining attack | Remaining defense |
| --- | ---: | ---: | ---: | ---: |
| Abyss | 43 | 43 | 43 | 43 |
| Ascent | 34 | 34 | 28 | 28 |
| Bind | 17 | 17 | 16 | 16 |
| Breeze | 44 | 44 | 44 | 44 |
| Corrode | 17 | 17 | 17 | 17 |
| Fracture | 54 | 54 | 48 | 48 |
| Haven | 15 | 15 | 15 | 15 |
| Icebox | 58 | 63 | 58 | 63 |
| Lotus | 48 | 48 | 48 | 48 |
| Pearl | 55 | 55 | 55 | 55 |
| Split | 1 | 1 | 1 | 1 |
| Summit | 26 | 27 | 26 | 25 |
| Sunset | 11 | 11 | 11 | 11 |
| Total | 423 | 429 | 410 | 414 |

## Confirmed findings and draft corrections

- Icebox's saved right Nest-end sightline was blocked by an infinite wall.
  Both ends of both Nest assemblies are now discovered together and measured
  against their named base, floor, interior, and roof objects. Three ends have
  the upper opening; the attacker right end remains solid at that eye height.
  The lower bases remain solid. The larger compound paths still contain
  unresolved sections, which is why Icebox's remaining-record count does not
  fall after correcting these sections.
- Six Ascent records now use bounded prop heights: the boat and stands, a
  planter, and four edges of the same Mid wall. Their heights come from those
  named objects rather than an overlapping building or roof.
- Bind's wine-barrel record now uses the barrel's measured top.
- Six Fracture records are zipline route/direction artwork and now have no
  blocking interval. Riot documents the opposing attacker-spawn ziplines in
  [the Episode 3 Act II map introduction](https://playvalorant.com/en-us/news/game-updates/what-s-new-in-valorant-episode-3-act-ii/).
- Two Summit defense records are thin remainders outside prop ownership masks,
  0.0001 and 0.0003 SVG units wide. Their neighboring attack-side props already
  have measured heights. The canonical box assemblies confirm the same finite
  heights for the defense strips. The painted geometry is unchanged.
- Split's remaining record is the asset gap Dara explicitly rejected as a
  usable gameplay opening. That tactical blocker must remain. Its numerical
  upper extent is unresolved; the raw mesh gap does not overturn Dara's review.

## What the complete sweep establishes

The source-profile sweep measured 68,647 local sections and produced 76 gallery
pages, all personally inspected. Each defense assumption is separately listed
and matched to its corresponding physical region. The two defense-only Summit
strips have separate source-object reviews. Small differences between the two
authored SVGs are recorded; matching tolerance does not change runtime ink.

The native source packs were checked triangle by triangle against the declared
source revision, covering 21,290,782 retained triangles. The old audits used an
older extraction folder for Bind, Fracture, and Summit. The new lookup follows
the release-input manifest and checks its geometry hash. Measurements for those
maps were rerun against the declared sources.

The expanded source comparison cast 73,521 local rays from the highest locally
eligible standing surface. It found 15,250 source/SVG disagreements. These are
review findings, not 15,250 confirmed gameplay bugs: artwork registration,
structural ownership, masked materials, and tactical meaning can affect the
comparison. Zero leak findings in this sample does not establish overall
accuracy. Infinite blockers naturally suppress many possible leaks.

There are 516 local sections without retained source geometry, and 14 attack
records have no valid automatic-standing probe. Four of those records are
confirmed Fracture annotations and do not need wall probes. The remaining ten
physical records have unresolved coverage gaps. Their skipped reasons remain
in the ledger. Missing physical-wall coverage cannot pass the acceptance gate. Long compound
building outlines, floor/ramp boundaries, and possible openings still need
local ownership and gameplay interpretation. A nearby source mesh, its global
maximum height, or a raw asset gap is insufficient evidence.

## Changes that prevent the old acceptance path

- The source compiler rejects `solid` fallback decisions and missing or
  nonfinite source tops even when their status says `reviewed`.
- The bundlers reject unknown or unbounded walls. They also preserve support
  planes and automatic-standing eligibility when packing a reviewed model.
- Candidate installation requires resolved heights and a current source
  sightline report with complete probe coverage and matching input hashes.
- CI, desktop release, and Store release run
  `tool/check_bundled_wall_heights.dart`. The current bundled assets fail this
  preflight. There is no release bypass added by this change.

## Verification and limits

Eleven Python regression tests pass for source-section clipping, paired-end
discovery, and rejection of assumed heights. Eleven Flutter tests pass for the
candidate Icebox data and existing saved poses. Three release-preflight tests
pass. Analysis of the four touched Dart files reports no issues; both edited
PowerShell release scripts parse successfully.

The production cone check covers 20 Nest cases across both sides, upper and
lower levels. The independent GEOS boundary audit checked 1,277 intervals with
zero flagged intervals. Production painter crops were inspected for the saved
right-end opening, the solid attacker end, and the lower base. These checks
establish those cases and wall contact, not approval of every map height.

All 26 candidate assets preserve the original painted wall union and all
non-wall data. The 26 installed assets still match their frozen original
hashes. The corrections remain in draft candidates; the app and shared review
site have not been rebuilt with them.

The next work is to resolve the remaining 824 stored assumptions by local
source ownership, starting with disagreements at playable heights and missing
standing coverage. Then verify named gameplay openings and both side renders,
rerun source/boundary checks, and install only the complete accepted set.
No approval decision from Dara is needed to continue that source-association
work. A gameplay question should be raised only for a specific sightline that
the available evidence cannot establish.
