"""Select exported static art for diagnostic rays without collision volumes.

Requires usd-core. Keeps the full export unchanged. This selection deliberately
does not certify dynamic state or material opacity.
"""
import argparse
import hashlib
import json
from pathlib import Path

from pxr import Sdf, Usd, UsdGeom


def prepare(source, output):
    source = Path(source).resolve(strict=True)
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    root = Sdf.Layer.FindOrOpen(str(source))
    selected, excluded = [], []
    for relative in root.subLayerPaths:
        path = (source.parent / relative).resolve()
        row = {'path': str(path), 'exists': path.is_file()}
        # Art includes low cover and visible walls. Pawn/projectile blockers,
        # callout/navigation/kill volumes and VFX are different evidence.
        if '_Art_' in path.stem:
            if not path.is_file():
                raise FileNotFoundError(path)
            selected.append(row)
        else:
            excluded.append(row)
    if not selected:
        raise ValueError('No exported Art sublevels found; classify this map explicitly.')
    stage = Usd.Stage.CreateNew(str(output))
    original = Usd.Stage.Open(root)
    UsdGeom.SetStageMetersPerUnit(stage, UsdGeom.GetStageMetersPerUnit(original))
    UsdGeom.SetStageUpAxis(stage, UsdGeom.GetStageUpAxis(original))
    stage.GetRootLayer().subLayerPaths = [r['path'].replace('\\', '/') for r in selected]
    stage.GetRootLayer().Save()
    report = {'schemaVersion': 1, 'status': 'static-art-diagnostic-only',
              'source': str(source),
              'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(),
              'selected': selected, 'excluded': excluded,
              'materialPolicy': 'All selected triangles treated as opaque for diagnostics only.',
              'certified': False}
    output.with_suffix('.selection.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({'selected': len(selected), 'excluded': len(excluded), 'output': str(output)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('output')
    args = parser.parse_args()
    prepare(args.source, args.output)
