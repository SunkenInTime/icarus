# Abyss and Haven screenshot corrections

Haven was revised again after user feedback. Its current behavior is documented
in [the September 13 follow-up](haven-tactical-sightlines-2026-09-13.md).
The window projection described below is historical and no longer enabled for Haven.

The user's screenshots exposed incorrect standing defaults and wall intervals.
The canonical gameplay decisions are in
[`reported-sightlines-2026-09-12.json`](../scripts/data/reported-sightlines-2026-09-12.json).
They supersede the earlier source-height assumptions at these locations.

## Changes

- Abyss Mid selects its 8 m floor instead of the invisible 20 m collision top.
- The Abyss ramp follows its measured 4–6 m climb. Its side walls block, and
  the perpendicular opening retains its measured 7 m sill and 9 m header.
  The 19.5805 m and 20 m collision tops no longer override that interior.
- The 8 m Abyss ledge sees toward the site across the horizontal opening.
  Its measured standing edge is restored with the opening.
- Haven's tower retains the 3 m lower passage and 9 m upper floor. The 45 m and 62 m
  collision tops no longer override them. The lower passage wall blocks at the
  lower level and clears the upper floor. The front keeps its lower exit and
  upper window, with their solid wall sections intact.
- Haven Mid Window retains its sill, header, and end posts instead of filling
  the entire window with its overhead assembly's maximum height. Its measured
  4 m sill remains a standing choice.
- The lower courtyard can see upward through that window to a standing target
  on the room's measured 3 m floor. The calculation preserves rays blocked by
  the sill, including those that cross below the opening.

The five excluded collision faces were identified by the agent from the user's
reported interior views. They were not part of the earlier viewer approvals.
No collision bodies were removed. The source model, SVG artwork, coordinates,
saved numeric elevations, and library serialization remain intact.

## Source and runtime evidence

[`review_reported_sightlines.py`](../scripts/review_reported_sightlines.py) reads
the frozen source and baseline hashes, measures local source-face intervals,
and partitions both original artwork sides. All seven changed parent walls
preserve their literal painted footprints. It restores only measured standing
area newly exposed by those wall corrections.

The final candidates and reports are under
`work/reported-sightlines-final-v4`. Full-domain comparison passes all 1,428 Abyss checks across both artwork sides,
including defaults. All 3,540 Haven checks also pass.
There are 714 retained Abyss source domains and 1,770 retained Haven domains.
The other 22 map assets retain their pre-install hashes, including Fracture.

[`reported_sightlines_test.dart`](../test/reported_sightlines_test.dart) checks
the reported positions, the ramp climb, upper and saved lower tower levels,
ledge and sill standing choices, and paired pass/block targets on both sides.
The broader visibility regression run passed 51 tests; three native-only tests
were skipped in that run. Separate native-backed window checks compare the
rendered region with independent 3D line intersections.

The floor projection is enabled only for Haven's named window-interior support.
Its targets use that floor plus standing eye height. The native horizontal
polygon remains a diagnostic result; the production painter uses the complete
visibility path. Tests also retain solid-base, overhead-cap, and footprint-hole
controls. This does not certify full-scene 3D visibility elsewhere.

The Windows Profile bundle is `build/sightline/runner/Profile`. Its four map
assets match the verified v4 candidates. Both bundled-data app checks passed
through the production provider, placed-agent widget, cache and painter,
including side flips, a 26-position ramp drag, and the saved lower tower level.
The 22 captures in the two `app` folders show the final painted results. These
are Flutter widget integration captures; they are not live-game screenshots.

The old app closed normally. The new executable launched as PID 32080 and
reported a responsive window titled `Icarus: Valorant Strategies & Line ups 4.6.1`.
No force termination or library manipulation was used.

The final native-backed projection run passed 8,263 grid comparisons against
independent 3D segment intersections through the same assigned wall volumes.
Its warm test-process medians were 11.2 ms and 12.2 ms. Earlier isolated runs
were about 8 ms. These are test-process measurements, not an AOT frame-time
benchmark. The permanent generator is
[`verify_reported_window_projection.py`](../scripts/verify_reported_window_projection.py),
and the runtime check is
[`verify_reported_window_projection_test.dart`](../tool/verify_reported_window_projection_test.dart).
Both bind the reference grid to the final candidate hash. They establish
numerical consistency for this window, not independent gameplay correctness
of every assigned source interval.

The decision trail is `work/reported-sightlines-decisions.tsv`. Hash-checked
copies of the five input screenshots are in the final candidate's `screenshots`
folder. Rebuilding source measurements still requires the frozen external
`E:/IcarusWorldAudit/2026-09-06` source archive.

Dara's next gameplay check should revisit the annotated positions in the running
build, particularly the Abyss ledge and both directions through Haven Mid Window.
The implementation and recorded expectations pass; fresh in-game comparison
remains a human gameplay check.

The tower window regression uses its automatic 9 m floor. An earlier diagonal
ray from the reported tower position crosses a real interior wall, so it remains
blocked. A separate position immediately inside the window tests the opening.
The added position exposed the adjacent 62 m collision cap; its exact top face
is now excluded alongside the original 45 m cap.
