# Reopened map review, September 13

The all-map gameplay review remains incomplete. The earlier focused queue missed
Fracture interiors because it required lower floors to appear in current ground
triangles and to clear current walls. Explicit lower supports were omitted, and
an incorrect current wall could hide the problem being investigated.

## Corrections

Fracture now excludes 48 exact standing domains associated with 13 ceiling or
boundary tops and nine rooftop pipe objects over covered interiors. All 55 runtime
aliases of those domains were removed on both sides. The source decision is
`scripts/data/fracture-covered-interiors-review-2026-09-13.json`.

The production placed-agent widget reproduced the first failure before the change:
the eye was 17.9617 m instead of 8.25 m at the measured interior. The corrected
model passes all 87 independently specified floor poses on both sides, plus a
pointer drag. This establishes the selected elevations and production rendering;
the fixture has no gameplay opening targets. It does not certify roof access in
the live game or resolve every Fracture opening.

Abyss defense retained two measured aliases of previously excluded supports.
Breeze retained two such aliases on each side. All six were removed. The source
builders now remove measured aliases as well as the original physical IDs.
`scripts/standing_source_integrity.py` checks the reverse relationship: every
measured runtime alias must belong to the current reviewed source. Its certificate
pins all 26 bundled asset hashes. It verifies 24 sides; Split's two legacy sides
are explicitly outside this source-membership check. Physical aliases require
separate accounting and are not certified by this check.

Bind now excludes both runtime aliases of the 26 m upper cap of the map-wide
player kill volume. The exact source decision is
`scripts/data/bind-kill-cap-review-2026-09-13.json`. Its real sloped bridge is
preserved. A review recommendation incorrectly read that bridge's 106 m plane
intercept as a local height; evaluating the plane at the source position gives
5.596 m. The regression checks that physical floor on both sides.

These corrections change standing records only. The candidate comparisons verify
that all other model fields and all retained supports are unchanged.

## Verification

Full source-domain and automatic-floor comparisons pass on both sides:

| Map | Domain checks |
| --- | ---: |
| Fracture | 9,712 |
| Bind | 7,974 |
| Breeze | 7,916 |
| Abyss | 1,422 |
| Total | 27,024 |

The reports and exact hashes are linked by
`work/systematic-map-review/reopened/verified-installation.json`.
The Windows profile build passes. All 41 bundled regression tests pass, including
the new Fracture, Bind and reverse-source checks. The complete wall-footprint
certificate also passes for all 26 sides. Both packaging scripts include the new
tests. Targeted Dart analysis reports no issues.

Production widget evidence is under
`work/systematic-map-review/reopened/`. Fracture's `fracture-app-before.log`
preserves the failing placement, and `fracture-app-after/verification.json`
records the corrected placements, side flips and drag. The Abyss and Breeze
widget runs also pass against the built assets. Bind's two independently measured
bridge positions pass placement, side flips and pointer drag. The initial Bind
full-map widget run was interrupted and is not counted. An initial focused
fixture selected roof points outside the receiver; its failed run is retained,
and those points are not counted as app coverage.

The fresh bundle is open from `build/reopened-map-review/runner/Profile`.
`work/systematic-map-review/reopened/bundle.json` pins all 26 delivered map sides,
and `delivery.json` records the responsive application. The previous application
closed normally. No direct library edits were made.

## Remaining review

The reopened non-Fracture queue accounts for all 277 records in 119 groups,
including candidates outside the earlier priority filter. Its current
dispositions are in `work/systematic-map-review/reopened/role-dispositions.json`:

- 47 groups retain matching physical floor, ramp, prop or structural assemblies.
  Retention does not certify every ability-access rule.
- Nine groups retain earlier exclusions.
- One group is the corrected Bind kill-volume cap.
- 44 groups have unresolved gameplay eligibility, including possible arch caps,
  roofs and overhead beams. They remain in the queue and were not bulk removed.
- 18 Split groups lack the independent regional source used by this pass.

Fracture's wider mesh inventory also remains open beyond the 48 reviewed domains.
The source comparisons prove agreement with the selected source dispositions,
not that every source disposition or usable opening is correct in gameplay.

Next, resolve the remaining roof and boundary roles from player-blocking and
standing rules, then test usable openings from the corrected local floors.
Fracture opening review is still needed. Restore an independent Split source
before counting its groups as verified. A zero-navigation rule, global height
cutoff, or agreement with the current model cannot close these obligations.
