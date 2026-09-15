"""Compare regional colliders with the independently loaded complete scene."""
import argparse
import json
from pathlib import Path

import numpy as np
import shapely

from audit_all_map_gameplay_levels import read
from compile_icebox_ramp_ground import sha


def verify(source_dir, whole_scene):
    source_path = source_dir/'source-colliders.json'
    whole_path = whole_scene/'source-colliders.json'
    local, whole = read(source_path), read(whole_path)
    inventory = read(source_dir/'source-inventory.json')
    scene_accounting = read(whole_scene/'collision-accounting.json')
    assert scene_accounting['allSceneColliders'] and not scene_accounting['unresolved']
    assert not read(source_dir/'collision-accounting.json')['unresolved']
    local_ids = {r['id']: i for i, r in enumerate(local)}
    assert len(local_ids) == len(local)
    assert len({r['id'] for r in whole}) == len(whole)
    radius = .42
    region = shapely.from_geojson(json.dumps(inventory['sourceRegion'])).buffer(radius, join_style='mitre')
    relevant, missing, changed = [], [], []
    with np.load(source_dir/'source-colliders.npz') as local_meshes, np.load(whole_scene/'source-colliders.npz') as all_meshes:
        for i, row in enumerate(whole):
            lo, hi = row['bounds']
            if not region.intersects(shapely.box(*lo[:2], *hi[:2])):
                continue
            relevant.append(row['id'])
            if row['id'] not in local_ids:
                missing.append(row['id'])
                continue
            j = local_ids[row['id']]
            if row != local[j] or not np.array_equal(all_meshes[str(i)], local_meshes[str(j)]):
                changed.append(row['id'])
    result = dict(status='passed' if not missing and not changed else 'incomplete',
        wholeSceneCollidersSha256=sha(whole_path), regionalCollidersSha256=sha(source_path),
        wholeSceneMeshesSha256=sha(whole_scene/'source-colliders.npz'),
        regionalMeshesSha256=sha(source_dir/'source-colliders.npz'),
        sourceInventorySha256=sha(source_dir/'source-inventory.json'),
        wholeSceneAccountingSha256=sha(whole_scene/'collision-accounting.json'),
        algorithmSha256=sha(Path(__file__)), radiusMeters=radius,
        relevantSceneColliders=len(relevant), missingInfluencers=missing, changedInfluencers=changed)
    (source_dir/'whole-scene-influence-verification.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))
    assert result['status'] == 'passed'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--whole-scene', type=Path, required=True)
    args = parser.parse_args()
    verify(args.source, args.whole_scene)
