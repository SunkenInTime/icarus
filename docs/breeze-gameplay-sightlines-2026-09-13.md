# Breeze gameplay corrections and release checks

Two user screenshots exposed different source-assignment errors. The canonical
record is `scripts/data/breeze-gameplay-sightlines-2026-09-13.json`.

At attack SVG [276.875, 265], the app selected the 16 m top of an overhead collision
box instead of the 4 m passage floor. `SuperGrid_Box343` spans about 8–16 m. Its
upper standing domain, volume-583-0, is excluded; its collision body is retained.
A sweep of the surrounding corridor found no other automatic supports at 10 m
or above in the inspected [256,260,295,307] region. This was a diagnostic search
bound, not a height cutoff or an exclusion rule.

At [346.25, 175.625], the observer correctly stands on the 9 m box. Nearby facade
sections had inconsistent tops near 9–21 m because local trim, cistern and facade
measurements were treated as interchangeable wall heights. From the box, low
sections became false openings. Three reviewed regions on SVG parents
p0-stroke-12 and p0-stroke-16 now use the complete structural assemblies
`OverpassExterior2DU` at 14.0823 m and `OverpassExteriorDU` at 20.1229 m.
The exact region bounds and source object IDs are in the canonical record.
This is a deliberate continuous-wall gameplay interpretation supported by those
assemblies, not a claim that every small source face has that height.

`review_breeze_gameplay_sightlines.py` preserves the painted footprints on both
sides while replacing only the reviewed local height assignments. It freezes
source geometry, metadata, alignment and standing-source hashes. A changed
source fails the build instead of silently reusing the same object indices.
The rest of the map's wall heights, ground and receiver are preserved.

## Regression evidence

The new tests failed against the original bundled Breeze data on both sides:
the passage selected 16 m, and the box could see through the reviewed facade.
They pass against the corrected candidate. They check 462 passage positions and
25 box positions per side, including three blocked targets and an open approach
from each box position. The box square lies wholly inside source volume-626-0;
the initial wider diagnostic square crossed its edge and was not a valid
constant-height expectation.

Two isolated fault controls reintroduce the overhead top and false 9 m facade
heights. The tests detect both. No production asset is altered by those controls.
The before and candidate logs are under `work/breeze-gameplay-review`.

The desktop and Store build scripts now run the reported sightline, Haven and
Breeze tests before packaging. CI already runs them as part of `flutter test`.
The release command sets `ICARUS_VERIFY_BUNDLED_GAMEPLAY=true`, so an environment
variable pointing at a different candidate cannot make bad bundled assets pass.
The old bundled assets failed this gate even with the corrected candidate set
in the diagnostic environment. The scripts' command wrapper stops on a nonzero
exit code. Their PowerShell syntax was also checked; packaging was not invoked.

## Delivery status

The final candidate is `work/breeze-gameplay-v3`. Its 7,920 complete standing-domain
checks pass with no missing or incorrect default floors. All 15 bundled gameplay
tests pass. Production widget checks pass across 63 records using the staged
bundle, including both reported poses and drag paths on both sides. All four
rendered captures were inspected. These are app checks, not live-game certification.

Both Breeze assets are installed and the updated desktop app is running.
`work/breeze-gameplay-v3/installation.json` records asset and binary hashes;
`delivery.json` records the launched process. The other 24 map height assets
are unchanged. No installer was packaged or published.

The third facade region was narrowed to x=299..312 to keep the correction local
to the affected source assembly. Regression and app checks passed after narrowing.
Source agreement and these regressions cover their stated scope; they do not
certify every unseen gameplay association on every map. Future openings and
overhead standing choices require separate gameplay classification and a
regression before acceptance.
