# Sunset range audit

September 4, 2026. Icarus 4.6.1, data version 97.

The reported Veto Crosscut mismatch is explained by Sunset's ability scale. The current value, `0.9502102049421427`, makes a nominal 30 m radius cover about **26.87 m** on the map. A value of **1.06** produces **29.97 m** against the extracted geometry. Keep the artwork at its present size.

The audit and Figma cleanup are complete. Update: the runtime scale correction and version 98 placement migration were applied and merged in [PR #159](https://github.com/SunkenInTime/icarus/pull/159). The measurements below retain the original before/candidate terminology. See [the implemented correction](sunset-scale-correction.md) for the final behavior and regression coverage.

The source issue is [Utility Alignment with Edge Shortcut? in Icarus testers](https://discord.com/channels/1353173092649930835/1544901406522089632). The thread separates an Alt-key edge-placement suggestion from the range mismatch. The latter is the issue audited here. The reporter's observation that Abyss looks correct is a useful control, although this audit does not certify every map's physical scale.

## What the measurements establish

| Check | Result | Meaning |
|---|---:|---|
| Repository Sunset drawing, ten held-out corners | RMS 0.433 SVG units, maximum 0.818 | Local geometry agrees within about 0.24 m at the worst checkpoint |
| Original Figma Sunset drawing, same held-out corners | RMS 0.357 SVG units, maximum 0.540 | Figma source also agrees with the extracted geometry |
| Independent affine fit, horizontal/vertical scale ratio | 1.000118 | No material axis stretch in the tested drawing |
| Current runtime scale | 26.866 m effective radius | 10.446% too small |
| Candidate scale 1.06 | 29.970 m effective radius | 0.099% below 30 m |
| Original Discord screenshot | About 29.72 m visible radius | Corroborates 30 m within roughly 1%, not the current 26.87 m |

The screenshot registration uses six map corners. Its largest residual is 0.65 pixels. A robust fit to 497 visible circle-edge pixels gives a radius of 157.81 pixels. Screenshot measurement is a visual check, not a live gameplay distance test.

A follow-up check bypassed the SVG entirely. Fitting Riot's six UV landmarks directly to the screenshot predicts a 30 m radius of 159.29 pixels. The visible circle still measures 157.81 pixels. This disagreement therefore persists without Icarus artwork in the calculation. Leaving out each landmark in turn changes the prediction only to 159.23–159.36 pixels. Moderate changes to the circle-edge brightness threshold give 157.75–157.81 pixels. These are sensitivity checks, not statistical confidence intervals.

The rounded candidate of 1.06 gives 159.14 pixels, or 0.84% above this screenshot's visible circle. A scale of about 1.05116 would match that one visible circle, but would represent about 29.72 m against the extracted map calibration. It is not yet justified as a physical-scale correction.

The extraction contains a useful rendering lead. Crosscut's older minimap area is 4800 units wide around a 2400-unit collider radius. Its `MI_MinimapArea_Circle_Sentinel` material overrides `OutlineThickness` to 5, and its parent `MAT_MinimapArea_Circle_Base` exposes `Smoothing` with default 3. The JSON does not establish those parameters' screen-pixel units or the full shader calculation. They show that the visible edge has separate rendering controls, but do not prove an exact offset in the current client. Reference calibration, older extracted data, and visual-edge rendering remain possible sources of the small residual.

To resolve it, compare the same placement at multiple minimap zoom levels and measure the actual current teleport activation boundary on the same floor. A fixed pixel inset would support an outline-rendering explanation. Do not reshape the SVG or reduce every ability's physical scale just to eliminate this one screenshot difference. Reproduce the follow-up with `python scripts/audit_sunset_residual.py`; results are in [residual-measurements.json](../artifacts/sunset-audit/residual-measurements.json).

See the [original-scene comparison](../artifacts/sunset-audit/discord-scene-check.png), [landmark plot](../artifacts/sunset-audit/sunset-calibration.png), and [machine-readable measurements](../artifacts/sunset-audit/measurements.json).

## References to use

Calibrate against fixed wall corners spread across the map, then check the problem area without refitting. Center the ability on its beacon, not the nearby player icon. The first six landmarks below establish the transform; the rest test it.

| Reference point | Purpose | Riot vertex | Repository SVG x, y |
|---|---|---:|---|
| A Elbow northeast outer corner | Calibration | 281 | 414.436, 138.496 |
| B Site west, upper outer corner | Calibration | 0 | 1.535, 166.880 |
| Attacker Spawn southwest outer corner | Calibration | 142 | 190.045, 454.465 |
| Defender Spawn northeast outer corner | Calibration | 200 | 274.660, 27.640 |
| B Lobby west, upper outer corner | Calibration | 57 | 85.079, 335.039 |
| B Main southwest outer corner | Calibration | 5 | 6.355, 314.410 |
| A Lobby inside elbow | Independent check | 209 | 295.546, 307.191 |
| A Lobby outer southeast corner | Independent check | 255 | 351.242, 307.191 |
| A Elbow southeast outer corner | Independent check | 284 | 414.436, 251.495 |
| Mid Bottom east wall, top and bottom | Independent checks | 160, 163 | 218.464, 226.896 / 218.464, 289.482 |
| Mid Tiles northwest and southeast corners | Independent checks | 184, 241 | 253.274, 250.995 / 323.358, 278.772 |

The [landmark fixture](../test/fixtures/map_calibration/sunset.json) records all 16 points, their UV coordinates, exact SVG path references, Figma counterparts, and source hashes. The scene plot numbers identify the first six corners unambiguously. The circle's position was not used to fit map scale.

## Source data and calculation

The local extraction is under `D:\Downloads\Output\Exports\ShooterGame\Content`. Sunset is `Juliett`; Veto is `Pine`.

- `Maps/Juliett/Juliett_UIData.json` supplies equal-magnitude minimap multipliers of `0.000078` per world unit.
- `UI/InGame/Minimap/Maps/Juliett/Juliett_VisionCones.json` supplies the ground-boundary UV vertices. The audit uses the first 285-vertex ground group.
- `Characters/Pine/S0/Ability_4/GameObject_Pine_4_UsableTeleport.json` contains a `RangeCollider` sphere radius of 2400 and an arming time of 1.5 seconds. Those defaults reflect older tuning.
- `Characters/Pine/S0/Ability_4/Ability_Pine_4_UsableTP.json` has a targeting range of 2000. That is placement targeting, not the teleport's usable-area radius.

Riot's [13.00 patch notes](https://playvalorant.com/en-us/news/game-updates/valorant-patch-notes-13-00/) increased Crosscut's usable area from 24 m to 30 m and reduced arming time from 1.5 to 0.75 seconds. That explains the older extracted values. The audit uses the extraction for map geometry and the patch specification for current ability range. It does not assume every extracted default is current.

The conversion uses 100 centimeters per meter, consistent with [Unreal Engine's default distance units](https://dev.epicgames.com/documentation/en-us/unreal-engine/units-of-measurement-in-unreal-engine), the older 2400-unit/24 m ability tuning, and the current screenshot.

```text
UV per meter = 0.000078 × 100 = 0.0078
Measured SVG units per UV = 447.5358
Measured SVG units per meter = 447.5358 × 0.0078 = 3.490779

Icarus SVG units per meter = 5.78 × mapScale × 473 / 831
Required mapScale = 3.490779 × 831 / (5.78 × 473) = 1.061047
Rounded candidate = 1.06
```

The `473` is the exported SVG height. The `831` is Icarus's virtual base height in `CoordinateSystem`. The renderer contains the SVG within its map area, so the full viewBox height belongs in this calculation, including transparent margins. Increasing the existing scale by 10% is not quite enough. The measured increase is about 11.6%.

The Figma source export is 415 × 473, with a native group size of about 413.78 × 473. The repository asset is 416 × 473. Their small edge differences do not explain the range error. Their independently measured physical scales agree closely.

## Two separate code findings

Custom shapes currently cannot provide an independent meter check. `CustomCircleUtility.diameterInVirtual` multiplies the displayed diameter by `AgentData.inGameMetersDiameter`, which is already twice the per-meter conversion. A value displayed as a 30 m diameter therefore draws the same footprint as a 30 m radius ability. Custom rectangle width and length use the doubled conversion too. See [utilities.dart](../lib/const/utilities.dart).

Crosscut's own `CircleAbility(size: 30)` correctly treats 30 as a radius and doubles it for the widget diameter. The shared map scale is what makes that correct nominal radius too small on Sunset.

The vision-geometry projection has a different issue. `_projectUv` reconstructs a padded frame of about 448.895 × 482.150 SVG units for Sunset. The landmarks instead fit a nearly square UV transform of about 447.536 units, translated by about -19.137, 13.317. The current vertical mapping is stretched by roughly 7.7% and displaced. The extra alignment offset does not correct that stretch. SVG boundaries already replace part of the runtime vision geometry, but the raw projected layer and height data deserve a separate check. This projection does not set Crosscut's circle radius. See [maps.dart](../lib/const/maps.dart) and [vision_geometry.dart](../lib/view_cone/vision_geometry.dart).

## Applying the correction safely

1. Change only Sunset's runtime scale to `1.06` after adding a versioned placement migration. Keep the current artwork dimensions and retain `CircleAbility(size: 30)`.
2. Preserve each saved ability's anchor by applying `newPosition = oldPosition + (oldAnchor - newAnchor) × 1000 / 831`. Do this after canonical-coordinate migration. Include every page, lineup-group ability, and scale-dependent utility. Preserve IDs, deleted flags, page metadata, and lineup images. Agent markers have fixed anchors and must not receive the ability shift.
3. For Crosscut alone, a bare constant change moves the center by about 22.91 normalized units on each axis. That is why changing one number without migrating placements is incomplete. Custom circles use the maximum-size wrapper anchor, not the visible circle radius.
4. Freeze the historical Sunset scale used by `AbilityScaleMigration`, `CustomCircleWrapperMigration`, and `CanonicalCoordinatesMigration`. They currently read the live map scale. Old imports must pass through their historical geometry before receiving the new correction. Capture the original version before migration helpers overwrite it with the current version.
5. Route the new migration through both `migrateToCurrentVersion` and `migrateLegacyData`, and verify library loading and `.ica` import/export. Test pre-page strategies, versions before 39 and 45, defense pages before 97, current version 97 strategies, and repeated import/export of the new version. Assert that ability anchors stay fixed on attack and defense views, including lineup-group abilities and custom shapes.
6. Correct custom-shape meter semantics separately. Existing values need conversion if their physical footprint is to survive. Review slider limits and the custom-circle wrapper at the same time; merely replacing the multiplier would halve existing shapes.
7. Replace the vision projection's crop approximation with a calibrated UV-to-SVG transform, then test its boundaries and height lookup independently of circle sizing.

For the final live-game check, recreate the reported beacon placement on the same floor and inspect the A Lobby/Elbow gap and Mid Tiles wall. Compare 29.5 m, 30 m, and 30.5 m positions using a current build and a distance readout. Repeat on both Icarus sides and use Abyss as a control. Record the beacon center, floor height, patch version, and the range indicator. Corner-placement constraints and beacon-to-wall buffers can otherwise look like small scale errors. This live threshold check remains unperformed.

## Figma cleanup and recovery

The cleanup was applied inside **Icarus Maps Latest One**, on Map Assets. It covers all 79 map assets: 27 base maps, 26 callout overlays, 13 spawn-wall overlays, and 13 ultimate-orb overlays. The second Split defense asset was retained.

The cleanup named 1,549 layers and added 128 groups. It organized artwork, wall details, site overlays, callouts, barriers, orbs, and export bounds. It preserved original export-root names, editable boolean operations, instances, invisible sizing shapes, hidden references, and paint order.

All 79 Figma PNG pairs are byte-identical at 2x. All native asset widths, heights, and positions are exactly equal. Every SVG width, height, and viewBox is unchanged. An independent resvg render of all 79 SVG pairs is also pixel-identical at 2x. One Bind detail accumulated 0.00003052 units of grouping arithmetic; it changed no pixels in either renderer.

Backups are in `C:\Users\shawn\Documents\Codex\2026-09-04\icarus-figma-backup`:

- `Icarus Maps Latest One - before cleanup.fig` is the full untouched document, saved before edits.
- `Icarus Maps Latest One - after cleanup.fig` is the cleaned document.
- `exports` contains before/after SVGs and PNGs, full layer inventories, per-asset changes, and verification reports.
- Figma itself contains the hidden, locked group `BACKUP - Map Assets - 2026-09-04 - before cleanup`, node `2106:2402`. Unhide it to inspect the before-copy. It sits below the working canvas. Import the original `.fig` as a separate file for full-document recovery.

Repository map SVGs and application data were not modified. The [local plugin and independent verifier](../scripts/figma_map_cleanup/README.md) remain available for inspection.

## Reproducing the audit

```powershell
python -m pip install numpy scipy Pillow svgpathtools matplotlib

# Expected to fail while the application still uses 0.9502102049421427.
python scripts/audit_sunset_scale.py --check

# Passes within the 0.5% acceptance threshold.
python scripts/audit_sunset_scale.py --candidate-scale 1.06 --output artifacts/sunset-audit/candidate --check

# Also verifies the pinned local extraction hashes and UV references.
python scripts/audit_sunset_scale.py --fmodel-content 'D:\Downloads\Output\Exports\ShooterGame\Content'

python scripts/audit_sunset_references.py --figma-svg 'C:\Users\shawn\Documents\Codex\2026-09-04\icarus-figma-backup\exports\908-1601_sunsent_map.before.svg' --screenshot artifacts/sunset-audit/discord-reference.png

node scripts/figma_map_cleanup/verify_exports.cjs 'C:\Users\shawn\Documents\Codex\2026-09-04\icarus-figma-backup\exports'
```

These checks verify drawing calibration, the candidate numerical correction, source identity, screenshot agreement, and Figma export preservation. They do not certify an unimplemented library migration or live teleport behavior.
