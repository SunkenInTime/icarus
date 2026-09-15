"""Report native Pawn support evidence for every mirrored floor-window placement.

No collision preset or class default is invented for omitted serialized fields.
Confirmed exclusions and explicit BlockAll/complex support are separate from
unresolved inheritance and simple collision whose contact shape is unchecked.
"""
import argparse
from collections import Counter
from functools import lru_cache
import json
from pathlib import Path

from seal_world_plane_manifest import digest
from native_collision_defaults import custom_pawn_default

MAPS = frozenset('abyss ascent bind breeze corrode fracture haven icebox lotus pearl split summit sunset'.split())


def classify_support(component, mesh_body, actor):
    props = component.get('Properties', {})
    explicit = props.get('BodyInstance', {})
    use_default = props.get('bUseDefaultCollision')
    if actor.get('Properties', {}).get('bActorEnableCollision') is False:
        return 'excluded-actor-collision-disabled', 'actor', explicit
    if use_default is True:
        effective = mesh_body.get('DefaultInstance', {})
        basis = 'explicit-use-mesh-default'
    elif explicit:
        effective, basis = explicit, 'serialized-component-body'
    else:
        return 'unresolved-component-default', 'not-serialized', None
    profile = effective.get('CollisionProfileName')
    enabled = effective.get('CollisionEnabled')
    responses = [row['Response'].split('::')[-1] for row in effective.get('CollisionResponses', {}).get('ResponseArray', [])
                 if row.get('Channel') == 'Pawn']
    if len(set(responses)) > 1:
        return 'unresolved-conflicting-pawn-responses', basis, effective
    if profile == 'NoCollision' or (isinstance(enabled, str) and enabled.split('::')[-1] == 'NoCollision'):
        return 'excluded-no-collision', basis, effective
    if responses and responses[0] in ('ECR_Ignore', 'ECR_Overlap'):
        return 'excluded-explicit-pawn-nonblocking', basis, effective
    if profile in ('IgnoreOnlyPawn', 'OverlapOnlyPawn'):
        return 'excluded-pawn-nonblocking-profile', basis, effective
    if enabled is not None and enabled.split('::')[-1] not in ('QueryAndPhysics', 'QueryOnly'):
        return 'unresolved-query-collision-mode', basis, effective
    # Both named presets retain Pawn blocking in the extracted game config.
    # SourceFloors binds BlockAllDynamic to those exact config fingerprints.
    blocks = responses == ['ECR_Block'] or profile in ('BlockAll', 'BlockAllDynamic') or custom_pawn_default(effective) is not None
    if not blocks:
        return 'unresolved-pawn-profile', basis, effective
    if mesh_body.get('CollisionTraceFlag') == 'ECollisionTraceFlag::CTF_UseComplexAsSimple':
        return 'declared-pawn-blocking-complex', basis, effective
    return 'declared-pawn-blocking-shape-unverified', basis, effective


def audit(root, output):
    root, output = Path(root), Path(output)
    mesh_roots = [root / 'native-material-audit' / name / 'properties' for name in
                  ('mesh-export', 'extra-mesh-export', 'inherited-mesh-export')]
    @lru_cache(maxsize=16)
    def load(path):
        return json.loads(Path(path).read_bytes())
    results = []
    for comparison_path in sorted((root / 'mirrored-floor-audit').glob('*.json')):
        if comparison_path.stem.endswith('-winding'):
            continue
        comparison = load(comparison_path)
        if not isinstance(comparison, dict) or comparison.get('status') != 'read-only-handedness-floor-comparison':
            continue
        name = comparison['map']
        orientation_path = root / 'native-material-audit/world' / name / 'native-slot-audit.json'
        orientation = load(orientation_path)
        if digest(orientation_path) != comparison['source']['orientationAuditSha256']:
            raise ValueError(f'{name}: orientation audit changed after the floor comparison.')
        pieces = comparison['pieces']
        grouped = {}
        for piece in pieces:
            face = piece['sourceFace']
            placement = next(row for row in orientation['placements'] if row['firstFace'] <= face < row['firstFace'] + row['faceCount'])
            record = grouped.setdefault(placement['firstFace'], {'placement': placement, 'pieces': []})
            record['pieces'].append(piece)
        rows = []
        for first, record in sorted(grouped.items()):
            placement = record['placement']
            level_path = Path(placement['nativeLevel'])
            level = load(level_path)
            if digest(level_path) != placement['nativeLevelSha256']:
                raise ValueError('Native component source changed.')
            component = level[placement['nativeComponentIndex']]
            actors = [row for row in level if row.get('Name') == placement['nativeActor']]
            if len(actors) != 1:
                raise ValueError('Native actor identity is ambiguous.')
            relative = Path('ShooterGame/Content') / (placement['nativeMesh'].removeprefix('/Game/') + '.json')
            mesh_path = next((path / relative for path in mesh_roots if (path / relative).is_file()), None)
            if mesh_path is None or digest(mesh_path) != placement['nativeMeshSha256']:
                raise ValueError('Native mesh source is missing or changed.')
            mesh = load(mesh_path)
            mesh_object = next(row for row in mesh if row['Type'] == 'StaticMesh')
            body_pointer = mesh_object.get('BodySetup')
            bodies = [row for row in mesh if row['Type'] == 'BodySetup']
            if len(bodies) != 1:
                raise ValueError('Mesh BodySetup is ambiguous; explicit object resolution required.')
            body = bodies[0]
            classification, basis, effective = classify_support(component, body.get('Properties', {}), actors[0])
            props = component.get('Properties', {})
            rows.append({'firstFace': first, 'faceCount': placement['faceCount'], 'object': placement['path'],
                'sourcePrim': placement['sourcePrim'], 'sourceInstance': placement['sourceInstance'],
                'nativeActor': placement['nativeActor'], 'nativeActorType': actors[0]['Type'],
                'nativeComponentIndex': placement['nativeComponentIndex'], 'nativeMesh': placement['nativeMesh'],
                'classification': classification, 'effectiveBodyBasis': basis, 'effectiveBody': effective,
                'bUseDefaultCollision': props.get('bUseDefaultCollision', 'not-serialized'),
                'componentBodyInstance': props.get('BodyInstance'),
                'actorCollisionEnabled': actors[0].get('Properties', {}).get('bActorEnableCollision', 'not-serialized'),
                'meshBodySetup': {'name': body['Name'], 'pointer': body_pointer,
                    'defaultInstance': body.get('Properties', {}).get('DefaultInstance'),
                    'collisionTraceFlag': body.get('Properties', {}).get('CollisionTraceFlag'),
                    'aggregateGeometryKinds': list(body.get('Properties', {}).get('AggGeom', {})),
                    'cookedDataMetadata': body.get('CookedFormatData')},
                'floorWindowPieces': len(record['pieces']), 'parentNavPolygons': sorted({row['parentNavPolygon'] for row in record['pieces']}),
                'facingChangedFacesInFloorWindows': sorted({row['sourceFace'] for row in record['pieces']}),
                'source': {'levelPath': str(level_path), 'levelSha256': digest(level_path),
                           'meshPath': str(mesh_path), 'meshSha256': digest(mesh_path)}})
        result = {'map': name, 'geometrySha256': orientation['baselineGeometrySha256'],
                  'nativeCandidateGeometrySha256': orientation['candidateGeometrySha256'],
                  'orientationAuditSha256': digest(orientation_path), 'floorComparisonSha256': digest(comparison_path),
                  'placements': rows, 'summary': dict(Counter(row['classification'] for row in rows))}
        results.append(result)
        print(json.dumps({'map': name, 'placements': len(rows), **result['summary']}), flush=True)
    names = [row['map'] for row in results]
    if len(names) != len(set(names)) or set(names) != MAPS:
        raise ValueError(f'Floor comparison coverage is incomplete or duplicated: {names}')
    result = {'schemaVersion': 1, 'status': 'native-pawn-support-evidence', 'gameplayCertified': False,
              'sourceScriptSha256': digest(__file__), 'maps': results,
              'limitations': ['Support coverage is the union of all mirrored faces clipped to the original floor windows.',
                  'Declared Pawn blocking plus complex collision is source evidence, not a decoded cooked contact or live standing test.',
                  'Omitted component defaults remain unresolved; mesh defaults are not automatically substituted.',
                  'Explicit body responses are reported with bUseDefaultCollision and their source basis for review.']}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, allow_nan=False), encoding='utf-8')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    audit(args.root, args.output)
