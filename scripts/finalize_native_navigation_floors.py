"""Rebuild standing floors after native material-slot eligibility changes."""
import argparse
import copy
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from bake_navigation_floors import bake
from repair_world_material_bindings import floor_candidates


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def refine_changed_columns(baseline, navigation, triangles, changed_faces, admitted_faces):
    """Recast changed XY columns; preserve unrelated calibrated fallback heights."""
    def index(faces):
        xyz = triangles[faces]
        normal = np.cross(xyz[:, 1] - xyz[:, 0], xyz[:, 2] - xyz[:, 0])
        faces = faces[normal[:, 2] > .65 * np.linalg.norm(normal, axis=1)]
        xy = triangles[faces, :, :2]
        lo, hi = xy.min(axis=1), xy.max(axis=1)
        return faces, shapely.STRtree(shapely.box(lo[:, 0], lo[:, 1], hi[:, 0], hi[:, 1]))

    def at(faces, tree, seed):
        search = shapely.box(seed[0] - 1e-9, seed[1] - 1e-9, seed[0] + 1e-9, seed[1] + 1e-9)
        possible = faces[tree.query(search)]
        selected, heights = floor_candidates(triangles[possible], seed[:2], seed[2] - .6, seed[2] + .3)
        return possible[selected], heights

    source = np.asarray(navigation['vertices']).reshape(-1, 3) / 100
    source[:, 1] *= -1
    changed_ids, changed_tree = index(np.asarray(changed_faces))
    affected = [i for i, seed in enumerate(source) if len(at(changed_ids, changed_tree, seed)[0])]
    eligible_ids, eligible_tree = index(np.asarray(admitted_faces)) if affected else (None, None)
    refined = copy.deepcopy(baseline)
    rows = []
    for i in affected:
        faces, heights = at(eligible_ids, eligible_tree, source[i])
        check = refined['checks'][i]
        previous = refined['refinedFloorHeightsCm'][i]
        if len(faces):
            best = int(np.argmax(heights))
            value = float(heights[best] * 100)
            face = int(faces[best])
            normal = np.cross(triangles[face, 1] - triangles[face, 0], triangles[face, 2] - triangles[face, 0])
            normal /= np.linalg.norm(normal)
            check.update(accepted=True, refinedZCm=value, sourceFace=face, normal=normal.tolist())
            check.pop('estimatedFromMedianLift', None)
        else:
            value = check['sourceZCm'] - baseline['summary']['medianNavLiftCm']
            check.update(accepted=False, refinedZCm=value, materialCategory=None,
                         normal=None, estimatedFromMedianLift=True)
        check['nativeMaterialRechecked'] = True
        refined['refinedFloorHeightsCm'][i] = value
        rows.append({'vertex': i, 'beforeCm': previous, 'afterCm': value,
                     'accepted': bool(len(faces)), 'sourceFace': int(faces[best]) if len(faces) else None})
    refined['summary']['accepted'] = sum(c['accepted'] for c in refined['checks'])
    proof = {'method': 'exact upward source triangles at all changed eligibility XY columns',
             'checkedColumns': rows, 'changedHeightCount': sum(abs(r['afterCm'] - r['beforeCm']) > .001 for r in rows),
             'fallbackMedianPreservedCm': baseline['summary']['medianNavLiftCm']}
    refined['nativeMaterialRefinement'] = proof
    return refined, proof


def finalize(baseline, candidate, navigation):
    audit = json.loads((candidate / 'native-slot-audit.json').read_bytes())
    meta = json.loads((candidate / 'geometry.json').read_bytes())
    if audit['errors'] or digest(candidate / 'geometry.npz') != audit['candidateGeometrySha256']:
        raise ValueError('Native material repair has not passed source validation.')
    nav = json.loads(navigation.read_bytes())
    old_floor = json.loads((baseline / 'floor-mesh.json').read_bytes())
    refined = json.loads((baseline / 'floor-refinement.json').read_bytes())
    if refined['sourceXYZSha256'] != digest(navigation):
        raise ValueError('Native floor refinement source changed.')
    new, old = np.load(candidate / 'geometry.npz'), np.load(baseline / 'geometry.npz')
    admitted = np.asarray([m['category'] in ('opaque', 'unresolved') for m in meta['materials']])
    changed = np.flatnonzero(admitted[new['material_indices']] != admitted[old['material_indices']])
    floor = bake(candidate, navigation, candidate / 'floor-mesh.json')
    refinement, proof = refine_changed_columns(refined, nav, new['points'][new['faces']], changed,
                                               np.flatnonzero(admitted[new['material_indices']]))
    for check in refinement['checks']:
        if check.get('nativeMaterialRechecked') and check.get('accepted'):
            check['materialCategory'] = meta['materials'][int(new['material_indices'][check['sourceFace']])]['category']
    refinement['geometrySha256'] = meta['geometrySha256']
    refinement['summary']['unresolvedSurfaceBindings'] = sum(c['accepted'] and c['materialCategory'] == 'unresolved'
                                                            for c in refinement['checks'])
    (candidate / 'floor-refinement.json').write_text(json.dumps(refinement, separators=(',', ':')))
    proof.update({'sameDetailedFloorValues': old_floor['floorMesh'] == floor['floorMesh'],
                  'baselineFloorTriangles': old_floor['summary']['triangles'],
                  'candidateFloorTriangles': floor['summary']['triangles'],
                  'sourceGeometrySha256': meta['geometrySha256'],
                  'floorMeshSha256': digest(candidate / 'floor-mesh.json'),
                  'floorRefinementSha256': digest(candidate / 'floor-refinement.json'),
                  'nativeFloorToolSha256': digest(Path(__file__))})
    audit['nativeFloorRepair'] = proof
    audit['floorRevalidationRequired'] = False
    audit['stageReady'] = True
    (candidate / 'native-slot-audit.json').write_text(json.dumps(audit, indent=2))
    print(json.dumps({'map': audit['map'], **{k:v for k,v in proof.items() if k != 'checkedColumns'}}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline-root', type=Path, required=True)
    parser.add_argument('--candidate-root', type=Path, required=True)
    parser.add_argument('--navigation-root', type=Path, required=True)
    parser.add_argument('--maps', nargs='+', required=True)
    args = parser.parse_args()
    for name in args.maps:
        finalize(args.baseline_root / name, args.candidate_root / name,
                 args.navigation_root / f'{name}_source_xyz.json')
