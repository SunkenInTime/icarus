# Vision acceptance contract

[The visibility model](vision-model.md) defines the intended behavior. This
contract defines how to demonstrate it. A test run establishes only its stated
scope, source revision, and numerical tolerances.

## Definitions

- A **physical standing surface** has local player contact, sufficient standing
  clearance, and no applicable unwalkable or kill restriction. Recorded gameplay
  review can resolve a disagreement with extracted metadata.
  A reviewed exclusion can identify buried geometry outside playable space;
  this does not exclude isolated or ability-accessible platforms.
- A **standing level** is one such surface at a position. Several levels can
  occupy the same map position. Surface discovery and default level selection
  are separate operations.
- A **reference height** is a convenience field, including interpolation or
  extrapolation. Its existence does not establish physical player contact.
- A **source association** links a local surface or wall interval to its source
  object, faces, transform, and resolved collision settings. Preserve gameplay
  decisions separately from geometric measurements.
- An **unresolved record** has a missing or ambiguous association, behavior, or
  measurement that could change the result. It remains in the completion report.

## Required evidence

| Rule | Obligation | Evidence that can establish it |
|---|---|---|
| V1 | Preserve actual SVG wall footprints, artwork, coordinates, and saved placements. | Artwork fingerprints, footprint comparison, app coordinate checks on both sides. |
| V2 | Use the local physical floor and retain distinct levels. | Source contact measurements and full local domains; compare each level separately. |
| V3 | Admit usable isolated and ability-accessible surfaces. | Player contact and clearance, or recorded gameplay decisions. Navigation connectivity and object names are not admission gates. |
| V4 | Account for every relevant source item in the declared region. | An inventory made from source before inspecting the candidate, with represented, excluded-with-reason, or unresolved status. |
| V5 | Apply the default and saved-level selection rules through the app. | Expected levels fixed from independent evidence; real placed-agent widget, movement, side change, and explicit lower-level checks. |
| V6 | Distinguish real openings, solid bases, low cover, and annotations. | Paired pass/block expectations at independently established heights; actual SVG contact checks. |
| V7 | Preserve continuous movement across connected floors and ramps. | Source-defined paths, both sides of boundaries, overlap regions, and distinct stacked paths. |
| V8 | Test the delivered implementation and data. | Record asset and runtime hashes, provider loading, actual painter output, and the execution surface used. |

## Verification procedure

1. Fix the scope: source revision, native region, SVG region, supported gameplay
   states, units, and tolerances. Include source objects and blockers that can
   influence that scope, even when their origins lie outside it.
2. Build the source inventory independently of bundled supports. Resolve active
   instances, transforms, inherited settings, collision profiles, and local
   standing faces. Keep unresolved candidates in the inventory. A report of
   known blocking volumes alone does not cover all static-mesh collision.
3. Record expected surfaces, levels, and sightline behavior from source and
   gameplay evidence. Hash that evidence. The candidate may supply actual
   results only; it cannot generate its own expected standing height.
4. Compare complete planar domains where possible. Also exercise boundary
   offsets, holes, intersections, ramp joins, and continuous source-defined
   paths. Report numerical tolerances and any sampled-only portions explicitly.
   A region cut must not create a standing floor along its boundary. Include a
   fully blocked-region control, and compare a region against its restriction
   from a larger source measurement. Use a consistent precision grid when
   subtracting clearance geometry.
5. Exercise the production placement and rendering path. Check default standing,
   saved lower levels, both artwork sides, and moving origins. Compare rendered
   contact with SVG ink separately from source-height correctness.
6. Demonstrate that the verifier rejects a removed required surface, an
   incorrect local height, and an unaccounted source record. Apply these faults
   only to isolated copies. Expected cases remain unchanged.
7. Report each obligation as passed, failed, unresolved, or outside scope.
   Relevant unresolved records prevent a complete result. Passing regressions
   and complete source accounting are separate requirements.

Use one canonical record per source decision. Derived runtime assets may omit
verbose evidence, but their build must retain an unambiguous link to it. A
ground/support footprint percentage is not a correctness percentage. Agreement
between native and Dart implementations establishes numerical consistency.

## Counterexamples that constrain the model

| Counterexample | Required behavior | Rules | Existing evidence |
|---|---|---|---|
| Icebox Top Screens | Select the 7.00 m physical floor automatically, despite its disconnected navigation island. | V2, V3, V4, V5 | [Original finding](icebox-top-screens-review.md), saved review `1788883963581-57243566`, cone 4. |
| Icebox lower pipe step | Use the floor beneath that local position, keeping the higher pipe as a separate level. | V2, V5 | Saved review `1788823493671-212d5f8`, cone 4; `scripts/review_icebox_user_sightlines.py`. |
| Icebox B and Kitchen windows | The upper eye sees through the opening; the lower eye meets its solid base. | V2, V6 | Same review, cones 1 and 2; `test/svg_automatic_standing_test.dart`. |
| Icebox defender-mid connector | Retain both the 1.00 m lower floor and the 4.50 m upper floor; the upper doorway remains usable. | V2, V5, V6, V7 | Same review, cone 3; local source sections in `scripts/review_icebox_user_sightlines.py`. |
| Icebox raised ramp over lower floor | An interpolated height inside a wall must not hide a valid floor below it. | V2, V5, V7 | `test/svg_automatic_standing_test.dart`, physical floor at attack SVG `[192.34895359539001,238.50310458167223]`. |
| Icebox ordinary ramp join | Availability of the correct ramp level does not justify a higher interpolated default. Compare the selected eye while dragging across the join. | V2, V5, V7 | `test/icebox_regional_standing_test.dart`, `tool/verify_icebox_app_acceptance_test.dart`; source-defined ramp and landing domains. |
| Icebox large ordinary floors | Resolve missing collision inheritance; classify their physical coverage explicitly. A numerical fallback is insufficient evidence. | V2, V4 | Source objects 4567, 4170, 4171; `scripts/gameplay_source_floors.py`. |
| Icebox buried Cube9 | Exclude this reviewed collider below the playable world while retaining usable ability-accessible surfaces. | V3, V4 | `scripts/data/icebox-playable-space-review.json`, source object 3514. |
| Bind fountain | Exclude only the narrow inner ring; retain the center and outer basin. | V2, V3 | `scripts/data/gameplay-standing-review-2026-09-08.json`. |
| Painted floor/ramp and zipline marks | Keep annotations visible without introducing blocking intervals. | V1, V6, V7 | [Visibility model](vision-model.md), Icebox Tube and A-site annotation decisions. |

These examples test different failure modes. Their number does not establish
map coverage. Preserve other saved review records when defining later regions.

## First exercise

Use Icebox A Top Screens and the adjacent pipe structure. Its source-defined
standing domains and the reported poses provide expected levels independent of
the candidate. Inventory the surrounding source region as well: passing these
known surfaces does not resolve unknown neighboring static meshes.

Record the exercise results in [the Icebox acceptance report](icebox-acceptance-report.md).
The exercise evaluates the current implementation and the verifier. It does not
authorize replacing unresolved data with a guessed surface or broadening the
standing model beyond the visibility rules.

## Gameplay regression gate

The source verifier must not provide its own gameplay expectations. A measured
collision top can be an overhead boundary, and a nearby low mesh can be trim on
a tall facade. Record the named gameplay position or opening independently,
then test standing selection and blocked/open rays together around that position.

The September 13 Breeze cases are release regressions in
`test/breeze_gameplay_sightlines_test.dart`. They preserve the 4 m passage under
an 8–16 m collision box and the real 9 m box viewpoint facing continuous walls.
The old assets fail both checks on both sides. Isolated fault controls restore
the overhead standing top and false low facade heights to demonstrate detection.
`test/haven_tactical_sightlines_test.dart` checks movement across the formerly
missed ceiling strip. Both release scripts run these alongside the earlier
reported sightlines before packaging, with diagnostic asset overrides disabled.

These are gates for the recorded gameplay behavior. They are not a claim that
unseen source associations are correct. A new unreviewed opening or overhead
standing choice still requires gameplay classification before acceptance.

A retained baseline discrepancy is still a discrepancy. An earlier audit saying
that a change did not introduce a blocker does not establish that blocker's
gameplay role or height. Resolve it from independent assembly and standing-floor
evidence, or keep it explicitly unresolved. Do not use an inherited `resolved`
status as authority to skip that review.

The release gate also runs `test/svg_wall_footprint_integrity_test.dart`.
Its offline geometry certificate covers every bundled wall record. Regenerate
it with `python scripts/svg_wall_footprint_integrity.py` after asset changes;
the audit rejects footprints that collapse on the source-overlay grid.
This establishes footprint integrity only. All-map roof, opening, and mirrored
profile detections remain review candidates until independent gameplay evidence
establishes the intended behavior.
