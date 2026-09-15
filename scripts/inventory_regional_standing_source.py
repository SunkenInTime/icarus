"""Inventory native mesh and player-volume evidence before reading map assets."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from audit_all_map_gameplay_levels import ROOT, MAPS, read
from gameplay_source_floors import SourceFloors
from gameplay_standing_volumes import StandingVolumes


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(name, output, bounds):
    if name not in MAPS:
        raise ValueError('Unknown map')
    output.mkdir(parents=True, exist_ok=True)
    target = output/'source-inventory.json'
    if target.exists():
        raise ValueError('Choose a new inventory output folder')
    source = SourceFloors(name)
    volumes = StandingVolumes(name)
    if volumes.unresolved:
        raise ValueError(volumes.unresolved)
    alignment_path = ROOT/f'tactical-alignment-sides-v1/{name}.json'
    matrix = np.asarray(read(alignment_path)['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    native = np.c_[inverse, -inverse@matrix[:, 2]]
    region = affine_transform(shapely.box(*bounds), [*native[0, :2], *native[1, :2], *native[:, 2]])
    rows = []
    for oid, obj in enumerate(source.objects):
        if not obj['faceCount']:
            continue
        try:
            evidence = source.object(oid)
        except (ValueError, KeyError, FileNotFoundError) as error:
            evidence = dict(classification='unresolved-source-identity', diagnostic=f'{type(error).__name__}: {error}')
        classification = evidence['classification']
        rows.append(dict(sourceObject=oid, path=obj['path'],
            status='excluded' if classification.startswith('excluded') else 'unresolved',
            reason=classification, evidence={k: v for k, v in evidence.items() if k != 'sections'}))
    bodies = [dict(collision=row['id'], kill=row['kill'], unwalkable=row['unwalkable'],
        status='excluded' if row['kill'] or row['unwalkable'] else 'resolved-collision-body', bounds=row['bounds'])
        for row in volumes.rows if region.intersects(shapely.box(*row['bounds'][0][:2], *row['bounds'][1][:2]))]
    paths = [Path(__file__), *[Path('scripts')/file for file in [
        'gameplay_source_floors.py', 'native_collision_defaults.py', 'native_supplement_placement.py',
        'audit_floor_pawn_support.py', 'cooked_collision_evidence.py', 'native_instance_collision.py',
        'gameplay_standing_volumes.py', 'build_all_map_gameplay_supports.py', 'standing_complex_clearance.py',
        'redundant_capsule_collision.py', 'native_capsule_collision.py', 'native_capsule_standing.py']]]
    archive = output/'inventory-algorithms'
    archive.mkdir()
    for path in paths:
        (archive/path.name).write_bytes(path.read_bytes())
    geometry = ROOT/f'supplemented-v2/world/{name}/geometry.npz'
    review = Path('scripts/data/gameplay-standing-review-2026-09-08.json')
    evidence = dict(geometrySha256=sha(geometry), metadataSha256=sha(geometry.with_suffix('.json')),
        alignmentSha256=sha(alignment_path), gameplayStandingReviewSha256=sha(review),
        nativePlacementAuditSha256=sha(ROOT/f'native-material-audit/world/{name}/native-slot-audit.json'),
        algorithmsSha256={path.name: sha(path) for path in paths})
    counts = dict(Counter(row['status'] for row in rows))
    result = dict(map=name, source=evidence, sourceRegion=json.loads(shapely.to_geojson(region)),
        regionSvgBounds=bounds, sourceInventoryMarginMeters=.42,
        requiredSourceObjects=[row['sourceObject'] for row in rows], inventory=rows, collisionBodies=bodies,
        counts=counts, scope='Every nonempty scene mesh is inventoried. Standing measurements are clipped to the declared region; all scene colliders can influence clearance.',
        status='unresolved' if counts.get('unresolved') else 'inventory-classified')
    target.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(dict(map=name, counts=counts, collisionBodies=len(bodies))), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--map', required=True, choices=MAPS)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--region-svg-bounds', nargs=4, type=float, default=[0, 0, 512, 512])
    args = parser.parse_args()
    inventory(args.map, args.output, args.region_svg_bounds)
