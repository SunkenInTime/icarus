"""Select exported static art for diagnostic rays without collision volumes.

Requires usd-core. Keeps the full export unchanged. This selection deliberately
does not certify dynamic state or material opacity.
"""
import argparse
import hashlib
import json
from pathlib import Path

from pxr import Sdf, Usd, UsdGeom


def prepare(source, output, world_json=None, include_levels=None):
    source = Path(source).resolve(strict=True)
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    root = Sdf.Layer.FindOrOpen(str(source))
    declarations = {}
    if world_json:
        for obj in json.loads(Path(world_json).read_text(encoding='utf-8-sig')):
            if obj.get('Type', '').startswith('LevelStreaming'):
                package = obj.get('Properties', {}).get('WorldAsset', {}).get('AssetPathName', '').split('.')[0]
                declarations[Path(package).name.lower()] = obj['Type']
    explicit = set(json.loads(Path(include_levels).read_text(encoding='utf-8-sig'))) if include_levels else None
    found_explicit = set()
    selected, excluded = [], []
    for relative in root.subLayerPaths:
        path = (source.parent / relative).resolve()
        row = {'path': str(path), 'exists': path.is_file()}
        row['streamingType'] = declarations.get(path.stem.lower())
        if world_json and row['streamingType'] is None:
            raise ValueError(f'No streaming declaration for {path.name}')
        # Art includes low cover and visible walls. Pawn/projectile blockers,
        # callout/navigation/kill volumes are different evidence. Art names can
        # still include VFX or state-dependent surfaces; this is a candidate set.
        selected_as_art = path.stem in explicit if explicit is not None else '_Art_' in path.stem
        if explicit is not None and path.stem in explicit:
            found_explicit.add(path.stem)
        persistent = not world_json or row['streamingType'] in ['LevelStreamingAlwaysLoaded', 'LevelStreamingPersistent']
        if selected_as_art and persistent:
            if not path.is_file():
                raise FileNotFoundError(path)
            selected.append(row)
        else:
            row['reason'] = 'non-persistent state' if not persistent else 'outside selected art levels'
            # Naming is not a completeness check: some maps put floors or site
            # architecture in levels without "Art" in the name. Expose those
            # omissions alongside intentional helper/state exclusions.
            if row['exists']:
                level = Usd.Stage.Open(str(path))
                visible = [str(p.GetPath()) for p in level.Traverse()
                           if p.IsA(UsdGeom.Mesh) and
                           UsdGeom.Mesh(p).ComputeVisibility() != UsdGeom.Tokens.invisible]
                row['visibleMeshPrimsIncludingPrototypes'] = len(visible)
                row['visibleMeshExamples'] = visible[:5]
            excluded.append(row)
    if explicit is not None and found_explicit != explicit:
        raise ValueError(f'Explicit levels absent from root: {sorted(explicit - found_explicit)}')
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
              'streamingSourceJson': str(Path(world_json).resolve()) if world_json else None,
              'streamingSourceSha256': hashlib.sha256(Path(world_json).read_bytes()).hexdigest() if world_json else None,
              'explicitLevelSelection': sorted(explicit) if explicit is not None else None,
              'explicitSelectionSha256': hashlib.sha256(Path(include_levels).read_bytes()).hexdigest() if include_levels else None,
              'selected': selected, 'excluded': excluded,
              'excludedLevelsWithVisibleMeshes': sum(r.get('visibleMeshPrimsIncludingPrototypes', 0) > 0 for r in excluded),
              'materialPolicy': 'All selected triangles treated as opaque for diagnostics only.',
              'certified': False}
    output.with_suffix('.selection.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({'selected': len(selected), 'excluded': len(excluded), 'output': str(output)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('output')
    parser.add_argument('--world-json', help='Match persistent membership against freshly extracted streaming declarations.')
    parser.add_argument('--include-levels', help='JSON array of exact level stems for maps without Art naming, such as Fracture.')
    args = parser.parse_args()
    prepare(args.source, args.output, args.world_json, args.include_levels)
