"""Compare measured complex floors with independently decoded cooked triangles."""
import hashlib
import argparse
import json
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree
from pxr import Usd, UsdGeom

from audit_all_map_gameplay_levels import ROOT, read
from cooked_triangle_mesh import triangle_mesh
from gameplay_source_floors import SourceFloors
from native_instance_collision import instance_physics_matrix


def verify(source_dir=Path('work/icebox-all'), export=ROOT/'icebox-complex-collision-v1',
           objects=(4567, 4835, 4836, 4697, 3724), output=Path('work/icebox-expanded-v2/cooked-floor-verification.json')):
    source = SourceFloors('icebox')
    stage = Usd.Stage.Open(str(ROOT.parent/'2026-09-04/verification-final-13.05/icebox/static-art.usda'))
    cache = UsdGeom.XformCache()
    rows = read(source_dir/'source-colliders.json')
    arrays = np.load(source_dir/'source-colliders.npz')
    result = []
    for oid in objects:
        placement = source.placement(oid)
        relative = 'ShooterGame/Content/' + placement['nativeMesh'].removeprefix('/Game/')
        mesh = export/'properties'/(relative+'.json')
        assert hashlib.sha256(mesh.read_bytes()).hexdigest() == placement['nativeMeshSha256']
        directory = export/'collision'/relative
        records = read(directory/'index.json')
        assert len(records) == 1
        record = records[0]
        data = (directory/record['file']).read_bytes()
        assert hashlib.sha256(data).hexdigest() == record['sha256'] and len(data) == record['bytes']
        vertices, faces, metadata = triangle_mesh(data)
        vertices[:, 1] *= -1
        prim = stage.GetPrimAtPath(placement['sourcePrim'])
        if '/Prototypes/' in placement['sourcePrim']:
            parent = np.array(cache.GetLocalToWorldTransform(stage.GetPrimAtPath(placement['sourcePrim'].split('/Prototypes/')[0])))
            component = source.level(placement['nativeLevel'])[placement['nativeComponentIndex']]
            matrix, _ = instance_physics_matrix(ROOT, placement, component, parent)
        else:
            matrix = np.array(cache.GetLocalToWorldTransform(prim))
        vertices = (vertices @ matrix[:3, :3] + matrix[3, :3]) * .01
        selected = [i for i, r in enumerate(rows) if r.get('sourceObject') == oid]
        assert len(selected) == 1
        triangles = arrays[str(selected[0])]
        reference_vertices, inverse = np.unique(triangles.reshape(-1, 3), axis=0, return_inverse=True)
        distance, correspondence = cKDTree(reference_vertices).query(vertices[faces].reshape(-1, 3))
        error = float(distance.max())
        assert error <= .00015, (oid, error)
        cooked_vertices, cooked_inverse = np.unique(vertices, axis=0, return_inverse=True)
        inverse_distance, source_correspondence = cKDTree(cooked_vertices).query(triangles.reshape(-1, 3))
        error = max(error, float(inverse_distance.max()))
        assert error <= .00015, (oid, error)
        actual = np.sort(cooked_inverse[faces], axis=1)
        expected = np.sort(source_correspondence.reshape(-1, 3), axis=1)
        # Chaos welds nearly coincident render vertices and removes triangles
        # that collapse in that native particle array. Preserve their count.
        collapsed = (expected[:, 0] == expected[:, 1]) | (expected[:, 1] == expected[:, 2])
        expected = expected[~collapsed]
        ordered = lambda value: value[np.lexsort(value.T[::-1])]
        assert np.array_equal(ordered(actual), ordered(expected)), (oid, 'Cooked floor triangles differ from source measurement')
        result.append(dict(sourceObject=oid, nativeMesh=placement['nativeMesh'], cookedSha256=record['sha256'],
            nativeMeshSha256=placement['nativeMeshSha256'], maximumVertexDifferenceMeters=error,
            sourceTriangleCount=len(triangles), collapsedSourceTriangles=int(collapsed.sum()),
            status='passed', **metadata))
    report = dict(status='passed', coordinateToleranceMeters=.00015, records=result,
        measuredCollisionSha256=hashlib.sha256((source_dir/'source-colliders.npz').read_bytes()).hexdigest(),
        scope='Collision geometry prefix and complete triangle correspondence; BVH and material tables are outside this check.')
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, default=Path('work/icebox-all'))
    parser.add_argument('--export', type=Path, default=ROOT/'icebox-complex-collision-v1')
    parser.add_argument('--objects', type=Path)
    parser.add_argument('--output', type=Path, default=Path('work/icebox-expanded-v2/cooked-floor-verification.json'))
    args = parser.parse_args()
    verify(args.source_dir, args.export, read(args.objects) if args.objects else (4567, 4835, 4836, 4697, 3724), args.output)
