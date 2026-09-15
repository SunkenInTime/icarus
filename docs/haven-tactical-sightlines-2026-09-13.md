# Haven tactical sightlines and the Breeze diagnosis

The user asked for stable gameplay behavior over small source details. The
canonical decision is `scripts/data/haven-tactical-sightlines-2026-09-13.json`.
It replaces the earlier Haven window projection and completes the tower ceiling
exclusions. The SVG artwork, wall footprints, real floors and saved lower-level
choices remain intact.

## Causes

At Haven attack SVG [352.5, 135.625], automatic selection chose a 45 m collision
top instead of the 9 m floor. The previous patch removed adjacent ceiling pieces
but missed this narrow strip. All six ceiling-volume tops, volume-32-0 through
volume-37-0, are now excluded as standing choices. Their collision bodies remain.
The tower retains the 3 m lower passage and the 9 m upper room.

Mid Window's detached patch came from projecting wall shadows onto the room's
higher floor. This was too literal for the requested tactical behavior. Its sill
now remains visible artwork and a standing choice, but does not occlude vision.
The opening uses one normal horizontal cone below the header. Its end jamb
still blocks. The former 42 small wall sections become two gameplay sections.

The later annotated screenshot is Breeze. It matches attack SVG [276.875, 265].
The source box `/Foxtrot_BVPawn/SuperGrid_Box343/Cube#0` spans 8 to 16 m above a
4 m floor. The app selects `breeze-physical-top-6ee4ff5d7bc1` at about 16 m, so
its eye looks over the nearby walls. The 4 m level from volume-581-0 is available
underneath. This confirms a standing-choice problem at that position. Breeze
has not been changed in this update.

The source pipeline admitted clear collision tops as standing surfaces. The
highest-level rule then selected them over the intended passage. Earlier floor
comparisons checked those assignments consistently; they could not prove that
an invisible overhead box belonged in the gameplay standing choices. Local
passing poses also missed the adjacent Haven strip.

## Verification and delivery

`test/haven_tactical_sightlines_test.dart` checks 506 source-floor positions on
each artwork side across the reported strip. Every point selects 9 m and the
outer wall blocks. The grid ends inside the measured upper-floor domain; at
[358, 133] only the lower floor has measured standing clearance.

All 3,532 full-domain checks against the revised Haven source decisions pass,
with no missing floors or wrong defaults. Seven targeted regression tests pass.
The bundled-data widget test checks both sides, window visibility, saved lower
levels and a 25-position continuous drag across the strip. Its 14 captures are
under `work/haven-simple-v2/haven/app`. These are production-widget integration
checks, not live-game certification.

The review bundle is `build/haven-simple/runner/Profile`. This is a data-only
update using the exact verified executable, native DLL and app.so from the prior
build. Only its two Haven height assets changed. The other 24 map assets,
including Breeze, retain their hashes. `work/haven-simple-v2/installation.json`
records those hashes. The prior app closed normally and this bundle launched
as PID 33000 with a responsive Icarus window. Source and reproduction logs are under
`work/haven-simple-review`.

Next, recheck the two Haven locations in the app. Breeze's reported overhead
standing choice is diagnosed and remains a separate correction. Further work
should classify overhead structures explicitly rather than increase ray detail
or impose a map-wide height cutoff.
