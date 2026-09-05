# Sunset scale correction

The Sunset map scale is now `1.06`, up from `0.9502102049421427`.
The SVG artwork and its 416 by 473 viewBox are unchanged.

A nominal 30 m Crosscut radius previously represented 26.87 m against the
extracted minimap geometry. It now represents 29.97 m. Six fixed map corners
establish the transform, and ten separate corners check it. The held-out error
is 0.433 SVG units RMS and 0.818 units maximum. The affine axis ratio is 1.000118,
which does not support stretching the artwork to correct the range.

The calculation uses Sunset's extracted `Juliett_UIData` multiplier of
0.000078 per centimeter, 447.5358 SVG units per minimap UV unit, the SVG height
of 473, and Icarus's virtual height of 831:

```text
SVG units per meter = 0.000078 * 100 * 447.5358 = 3.490779
Map scale = 3.490779 * 831 / (5.78 * 473) = 1.061047
Rounded runtime value = 1.06
```

The [landmark fixture](../test/fixtures/map_calibration/sunset.json) pins the
coordinates and hashes of the source files. Reproduce the measurement with:

```powershell
python -m pip install numpy svgpathtools matplotlib
python scripts/audit_sunset_scale.py --check
```

The check rejects a scale error above 0.5% or excessive held-out landmark error.
Use `--fmodel-content <ShooterGame/Content>` to verify the extracted source hashes.

## Saved placements

Data version 98 preserves the anchor of each existing Sunset ability, lineup
ability, and scale-dependent utility. The migration runs after canonical
coordinate conversion, so it applies the same calculation to attack and defense
pages. Agent positions and fixed-size anchors do not move.

```text
newPosition = oldPosition + (oldAnchor - newAnchor) * 1000 / 831
```

Historical migrations 39, 45, and 97 retain the old Sunset scale. Each migration
is selected using the original input version, because intermediate helpers can
stamp the current version before later stages run. Current-version data does
not receive the correction twice. No Hive fields or adapters changed.

Regression coverage includes every ability and utility type, lineup metadata,
deleted flags, both page sides, pre-page imports, versions 16/38/39/44/45/96/97,
other maps, source immutability, and ZIP JSON export/import.

## Accuracy limits

The corrected range is about 0.84% larger than the visible circle in the
reporter's screenshot. That residual persists when fitting Riot's minimap UVs
directly to the screenshot without the SVG. It is accepted as a visual
discrepancy, not fitted away by changing the physical scale. The minimap outline
is not a 3D collision mesh, and a current live activation-boundary test has not
been performed.

The local Crosscut extraction contains older 24 m tuning. The 30 m specification
comes from [Riot's patch 13.00 notes](https://playvalorant.com/en-us/news/game-updates/valorant-patch-notes-13-00/).
Custom-shape diameter semantics and vision-boundary projection are separate
issues and are not changed here.
