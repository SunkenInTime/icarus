# Lotus visibility acceptance

Lotus passes the current visibility acceptance contract. Both measured height
assets are installed in the workspace and match the Windows profile bundle.
The aggregate result is `work/lotus-all-v2/physical-levels/acceptance.json`.
This establishes the stated source, app and rendering checks, not new live-game
certification.

## Source and standing levels

The Valorant 13.05 inventory accounts for all 5,591 nonempty scene meshes.
Resolved collision settings and explicit empty-shape evidence exclude 5,012.
The standing measurement covers the remaining 579 meshes and 729 volume bodies.
No influencing collision record is unresolved.

All 21 freshly extracted native level-property files match the original source.
Six referenced component templates resolve inherited settings. The collision
export covers 81 mesh packages, with unchanged property bytes and no parser
errors. These records are in `work/lotus-acceptance-preflight`.

All 1,308 standing obligations completed. There are 607 standing domains across
192 source records; 1,116 records have no clear standing domain. Admission uses
local player contact, standing clearance and collision restrictions. Navigation
connectivity is not an admission requirement. No additional gameplay exclusion
was applied. The isolated 31.2839 m cap has no overlap with the SVG floor.

An independent B-site measurement at attack SVG bounds `[225, 180, 278, 232]`
produced 39 domains. All 39 groups match the whole-map restriction within
0.01 mm at boundaries and 0.00000001 m² in area.

The bake places 295 measured architectural floor domains into ground and
retains other physical levels as selectable supports. Attack has 13,621 ground
triangles, including 3,192 certified physical triangles. Defense has 13,614,
including 3,189 certified triangles. Both sides have 894 supports.
Wall geometry, receiver geometry and unaffected data are preserved.

## B-site opening evidence

All 3,319 wall records pass. Three initial discrepancies were missing links to
the existing B-site opening review. Source faces confirm the 4.049761 m plinth,
2.037703 m rim and ceiling interval from 6.985034 m to 10.098913 m. The two
reviewed footprints match the three existing SVG wall parts exactly.

`work/recover_lotus_named_opening.py` records those face identities and hashes
in `work/lotus-all-v2/named-opening-source-verification.json`. Its derived
`reviewed-wall-decisions.json` preserves the original decisions and adds the
exact section bindings. No wall height, opening or artwork changed.

## Delivered checks

| Check | Result |
|---|---|
| Complete floor domains and defaults | 1,214 checks, no failures |
| Runtime cases on each side | 46,139 passed; 81 outside the SVG floor; 108 inside an active SVG wall |
| Saved source levels on each side | 604 passed; two outside the SVG floor; one inside an active wall |
| Placed-agent integration | 4,951 checks passed, including saved lower levels, pointer movement and both sides |
| Native cone contacts | 4,832 cones; 1,187,085 intervals; no flagged contacts at 0.002 SVG units |
| Fault controls | Removed floors and 25 cm height errors detected on both sides; missing and unresolved inventory records rejected |

The primary app poses come from complete physical source measurements. Lotus
has no positions in Dara's September 8 standing review. The fixture builder
records this distinction and reads only source domains plus previously reviewed
SVG footprints and wall intervals when establishing expected levels.

All twelve production painter views and eight placed-agent captures were
personally inspected. The pit view is blocked by the low rim and solid base;
the raised plinth view clears the rim. The Tree-room ramp retains the surrounding
wall and curved corner shadow. Enlarged contacts meet the observer-facing ink.
Four outward-facing boundary captures have no visible cone because the SVG
floor clips it away. The first attack capture has a placeholder portrait.
Image hashes and observations are in `physical-levels/visual-inspection.json`.

The two compressed assets total 2,415,686 bytes. Sampling every third source
placement yields 202 positions per side and 404 measured queries per side after
one warmup pass. Attack median/p95 query cost is 0.661/1.891 ms; defense is
1.098/2.959 ms. Maximum observed costs are 2.592 and 5.473 ms. These include
automatic standing selection and the native query in a Flutter test process;
they are not desktop frame timings.

The installed attack asset SHA-256 is
`fe4e93edfd6ca3285cbb12e9af834af85c3cf4c69663fa9c6e8ba3c187c85e3d`.
Defense is `7a2aa93afb4c0f945cdb66f18e8930657e0858bc5234d41e2dd7c13523a49138`.
The Windows native library is unchanged. No library data, schema, serialization
or runtime visibility implementation changed during this acceptance pass.

Recheck the aggregate result with:

```powershell
python scripts/verify_icebox_physical_delivery.py `
  --source work/lotus-all-v2 `
  --candidate-dir work/lotus-all-v2/physical-levels `
  --fixture test/fixtures/lotus_regional_standing.json `
  --boundaries work/lotus-all-v2/boundaries `
  --walls work/lotus-all-v2/regional-wall-comparison.json `
  --regional-source work/lotus-b-site-v1 `
  --app-fixture test/fixtures/lotus_vision_acceptance.json
```

The work reuses the recorded gameplay opening decisions. Local wall heights use
source stations rather than a continuous proof of every facade point. Crouching,
changing door states and new live-game observations remain outside this pass.
