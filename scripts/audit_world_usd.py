"""Inventory a real FModel USD export without treating it as gameplay truth.

Requires usd-core. Exported game assets remain local and are not committed.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path

from pxr import Sdf, Usd, UsdGeom, UsdUtils


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inventory(source, output, world_json=None):
    source = Path(source).resolve(strict=True)
    root = Sdf.Layer.FindOrOpen(str(source))
    sublevels = []
    for relative in root.subLayerPaths:
        path = (source.parent / relative).resolve()
        sublevels.append({'path': relative, 'exists': path.is_file(),
                          'sha256': sha256(path) if path.is_file() else None})
    membership = None
    if world_json:
        content_root = next((p for p in source.parents if p.name == 'Content'), None)
        if content_root is None:
            raise ValueError('Expected the root USD under ShooterGame/Content for JSON membership checks.')
        objects = json.loads(Path(world_json).read_text(encoding='utf-8-sig'))
        declared = []
        root_paths = {(source.parent / p).resolve() for p in root.subLayerPaths}
        for obj in objects:
            if not obj.get('Type', '').startswith('LevelStreaming'):
                continue
            package = obj.get('Properties', {}).get('WorldAsset', {}).get('AssetPathName', '').split('.')[0]
            if not package.startswith('/Game/'):
                raise ValueError(f'Unresolved streamed world package: {package!r}')
            path = (content_root / package.removeprefix('/Game/')).with_suffix('.usda').resolve()
            declared.append({'type': obj['Type'], 'package': package,
                             'persistent': obj['Type'] in ['LevelStreamingAlwaysLoaded', 'LevelStreamingPersistent'],
                             'exists': path.is_file(), 'referencedByRoot': path in root_paths})
        if not declared:
            raise ValueError('No streaming declarations found in the supplied world JSON.')
        membership = {'sourceJsonSha256': sha256(world_json), 'levels': declared,
                      'persistentDeclared': sum(r['persistent'] for r in declared),
                      'persistentMissing': sum(r['persistent'] and not r['exists'] for r in declared),
                      'declaredButNotReferenced': sum(not r['referencedByRoot'] for r in declared)}
    layers, assets, unresolved = UsdUtils.ComputeAllDependencies(str(source))
    stage = Usd.Stage.Open(str(source))
    cache = UsdGeom.BBoxCache(Usd.TimeCode.Default(), ['default', 'render'],
                            useExtentsHint=False)
    meshes = []
    placeholders = []
    instancers = []
    types = Counter()
    for prim in Usd.PrimRange.Stage(stage, Usd.TraverseInstanceProxies()):
        types[prim.GetTypeName()] += 1
        if prim.IsA(UsdGeom.Cube):
            placeholders.append(str(prim.GetPath()))
        if prim.IsA(UsdGeom.PointInstancer):
            instancer = UsdGeom.PointInstancer(prim)
            instancers.append({'path': str(prim.GetPath()),
                               'placements': len(instancer.GetProtoIndicesAttr().Get() or []),
                               'prototypes': [str(p) for p in instancer.GetPrototypesRel().GetTargets()]})
        if not prim.IsA(UsdGeom.Mesh):
            continue
        mesh = UsdGeom.Mesh(prim)
        points = mesh.GetPointsAttr().Get()
        faces = mesh.GetFaceVertexCountsAttr().Get()
        indices = mesh.GetFaceVertexIndicesAttr().Get()
        visible = mesh.ComputeVisibility() != UsdGeom.Tokens.invisible
        bounds = cache.ComputeWorldBound(prim).ComputeAlignedRange()
        meshes.append({
            'path': str(prim.GetPath()), 'visible': visible,
            'pointInstancerPrototype': '/Prototypes/' in str(prim.GetPath()),
            'points': len(points) if points is not None else 0,
            'faces': len(faces) if faces is not None else 0,
            'triangles': sum(max(0, n - 2) for n in faces) if faces is not None else 0,
            'invalidIndices': sum(i < 0 or i >= len(points or []) for i in indices or []),
            'nonFinitePoints': sum(not all(math.isfinite(v) for v in p) for p in points or []),
            'faceCountMismatch': sum(faces or []) != len(indices or []),
            'bounds': [list(bounds.GetMin()), list(bounds.GetMax())] if not bounds.IsEmpty() else None,
        })
    report = {
        'schemaVersion': 1, 'status': 'export-inventory',
        'independentlyVerifiedGameplaySightlines': 0,
        'source': str(source), 'sourceSha256': sha256(source),
        'metersPerUnit': UsdGeom.GetStageMetersPerUnit(stage),
        'upAxis': str(UsdGeom.GetStageUpAxis(stage)),
        'sublevels': sublevels, 'streamingMembership': membership,
        'dependencies': {'layers': len(layers), 'assets': len(assets),
                         'unresolved': sorted(unresolved)},
        'summary': {'meshPrimsIncludingPrototypes': len(meshes),
                    'visibleMeshPrimsIncludingPrototypes': sum(m['visible'] for m in meshes),
                    'trianglesBeforeInstancerExpansion': sum(m['triangles'] for m in meshes),
                    'visibleTrianglesBeforeInstancerExpansion': sum(m['triangles'] for m in meshes if m['visible']),
                    'pointInstancerPlacements': sum(i['placements'] for i in instancers),
                    'invalidIndices': sum(m['invalidIndices'] for m in meshes),
                    'nonFinitePoints': sum(m['nonFinitePoints'] for m in meshes),
                    'faceCountMismatches': sum(m['faceCountMismatch'] for m in meshes),
                    'emptyMeshes': sum(not m['points'] or not m['faces'] for m in meshes)},
        'types': dict(types), 'meshes': meshes,
        'pointInstancers': instancers, 'cubePrimsToInspect': placeholders,
        'limitations': [
            'FModel defaults export persistent sublevels; dynamic sublevels require explicit selection.',
            'Successful parsing and valid indices do not establish complete gameplay occlusion.',
            'USD preview materials may approximate the game shader; inspect cutouts and transparency.',
            'Mesh-prim counts include instancer prototypes, not fully expanded scene placements.',
            'Cubes need inspection: the exporter can substitute a dummy cube for an unresolved mesh.',
        ],
    }
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({k: report[k] for k in ['sourceSha256', 'metersPerUnit', 'upAxis', 'dependencies', 'summary']}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('output')
    parser.add_argument('--world-json', help='Fresh FModel root-world JSON for streaming membership checks')
    args = parser.parse_args()
    inventory(args.source, args.output, args.world_json)
