"""Rebake floors where verified material repairs changed upward eligibility."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from bake_navigation_floors import bake


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def finalize(baseline_root, candidate_root, navigation_root, maps):
    manifest = {}
    for name in maps:
        baseline, candidate = baseline_root / name, candidate_root / name
        proof = json.loads((candidate / 'binding-repair.json').read_text())
        metadata = json.loads((candidate / 'geometry.json').read_text())
        old_metadata = json.loads((baseline / 'geometry.json').read_text())
        if digest(candidate / 'geometry.npz') != proof['candidateGeometrySha256']:
            raise ValueError('Candidate fingerprint mismatch')
        if digest(baseline / 'geometry.npz') != proof['baselineGeometrySha256']:
            raise ValueError('Baseline fingerprint mismatch')
        current, old = np.load(candidate / 'geometry.npz'), np.load(baseline / 'geometry.npz')
        admitted = np.array([m['category'] in ('opaque', 'unresolved') for m in metadata['materials']])
        old_admitted = np.array([m['category'] in ('opaque', 'unresolved') for m in old_metadata['materials']])
        changed = np.flatnonzero(admitted[current['material_indices']] != old_admitted[old['material_indices']])
        triangles = current['points'][current['faces'][changed]]
        normals = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
        upward = normals[:, 2] > .65 * np.linalg.norm(normals, axis=1)
        upward_count = int(upward.sum())
        floor_path = candidate / 'floor-mesh.json'
        if upward_count:
            floor = bake(candidate, navigation_root / f'{name}_source_xyz.json', floor_path)
        else:
            floor = json.loads((baseline / 'floor-mesh.json').read_text())
            floor['reusedFloorMeshFromGeometrySha256'] = floor['geometrySha256']
            floor['geometrySha256'] = metadata['geometrySha256']
            # Eligibility and coordinates are identical. The baseline's count
            # of unresolved material labels can change without a geometry change.
            count = floor['summary'].pop('unresolvedMaterialTriangles', None)
            if count is not None:
                floor['summary']['unresolvedMaterialTrianglesAtBaseline'] = count
            floor_path.write_text(json.dumps(floor, separators=(',', ':')))
        baseline_floor = json.loads((baseline / 'floor-mesh.json').read_text())
        if floor['navigationSha256'] != baseline_floor['navigationSha256']:
            raise ValueError('Native navigation source changed during repair')
        row = {'candidateGeometrySha256': metadata['geometrySha256'],
               'candidateFloorMeshSha256': digest(floor_path),
               'candidateFloorRefinementSha256': digest(candidate / 'floor-refinement.json'),
               'navigationSha256': floor['navigationSha256'],
               'changedUpwardFaceCount': upward_count, 'rebaked': bool(upward_count),
               'sameFloorMesh': floor['floorMesh'] == baseline_floor['floorMesh'],
               'baselineFloorTriangles': baseline_floor['summary']['triangles'],
               'candidateFloorTriangles': floor['summary']['triangles']}
        manifest[name] = row
        print(json.dumps({'map': name, **row}), flush=True)
    (candidate_root / 'floor-repair-manifest.json').write_text(json.dumps(manifest, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-root', type=Path, required=True)
    parser.add_argument('--candidate-root', type=Path, required=True)
    parser.add_argument('--navigation-root', type=Path, required=True)
    args = parser.parse_args()
    maps = sorted(json.loads((args.candidate_root / 'binding-repair-manifest.json').read_text()))
    finalize(args.baseline_root, args.candidate_root, args.navigation_root, maps)


if __name__ == '__main__':
    main()
