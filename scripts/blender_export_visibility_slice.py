"""Export diagnostic 2D occluders directly from a recorded observer's 3D planes.

Run inside Blender with the reference blend, --world-rays, --sample and --output.
Every selected triangle remains present, including uncertain materials. This
tests geometry conversion; it does not certify the scene's gameplay visibility.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys

import bpy
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from horizontal_mesh_slice import slice_triangles


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--world-rays', required=True)
    parser.add_argument('--sample', type=int, required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
    world = json.loads(Path(args.world_rays).read_text(encoding='utf-8'))
    if digest(bpy.data.filepath) != world['referenceSha256']:
        raise ValueError('Scene does not match the ray reference.')
    rays = [r for r in world['rays'] if r['id'].split('-')[0] == str(args.sample)]
    if not rays:
        raise ValueError('No rays for the requested sample.')
    elevations = sorted({r['startMeters'][2] for r in rays})
    planes = {z: {'worldElevationMeters': z, 'segmentsUv': [], 'coplanarTriangles': 0} for z in elevations}
    ui = world['uiTransform']

    def uv(point):
        x, y = point
        return [-y * 100 * ui['XMultiplier'] + ui['XScalarToAdd'],
                x * 100 * ui['YMultiplier'] + ui['YScalarToAdd']]

    # Limit work to the square enclosing all recorded rays. No segment inside
    # their range is dropped, and each output is scoped to this one observer.
    positions = np.array([r[k] for r in rays for k in ['startMeters', 'endMeters']])
    low, high = positions.min(axis=0), positions.max(axis=0)
    placements = 0
    for instance in bpy.context.evaluated_depsgraph_get().object_instances:
        if instance.object.type != 'MESH' or not instance.show_self or instance.object.original.hide_render:
            continue
        mesh = instance.object.data
        mesh.calc_loop_triangles()
        if not mesh.loop_triangles:
            continue
        points = np.empty((len(mesh.vertices), 3), dtype=np.float32)
        mesh.vertices.foreach_get('co', points.ravel())
        matrix = np.asarray(instance.matrix_world)
        points = points @ matrix[:3, :3].T + matrix[:3, 3]
        if np.any(points.max(axis=0) < low) or np.any(points.min(axis=0) > high):
            continue
        faces = np.empty((len(mesh.loop_triangles), 3), dtype=np.int32)
        mesh.loop_triangles.foreach_get('vertices', faces.ravel())
        triangles = points[faces]
        placements += 1
        for z, plane in planes.items():
            segments, _, coplanar = slice_triangles(triangles, z)
            plane['segmentsUv'].extend([[uv(a), uv(b)] for a, b in segments])
            plane['coplanarTriangles'] += coplanar
    result = {'schemaVersion': 1, 'map': world['map'], 'sample': args.sample,
              'status': '3d-slice-prototype', 'gameplayCertified': False,
              'worldRaysSha256': digest(args.world_rays), 'referenceSha256': world['referenceSha256'],
              'rayIds': [r['id'] for r in rays], 'slices': list(planes.values()),
              'summary': {'intersectingPlacements': placements,
                          'segmentsPerPlane': {str(z): len(p['segmentsUv']) for z, p in planes.items()},
                          'referenceHitMaterials': dict(Counter(r['materialCategory'] for r in rays))},
              'limitations': ['All selected triangles retained as two-sided occluders.',
                              'Unknown and transparent materials require separate classification.',
                              'This slice is scoped to the recorded observer and ray range.']}
    Path(args.output).write_text(json.dumps(result), encoding='utf-8')
    print(json.dumps(result['summary']), flush=True)


if __name__ == '__main__':
    main()
