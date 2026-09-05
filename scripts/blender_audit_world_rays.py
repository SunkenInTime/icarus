"""Cast diagnostic rays through a Blender scene built from exported map art.

blender --background SCENE.blend --python scripts/blender_audit_world_rays.py --
  --navigation assets/maps/split_vision.json --ui-data Bonsai_UIData.json --output REPORT.json

The navigation samples seed positions only. All intersections use the actual
exported triangles, including evaluated instances. Missing shader semantics
keep these results provisional. No SVG geometry enters the 3D ray test.
"""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import sys
import time

import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
import numpy as np


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def object_path(obj):
    parts = []
    while obj:
        parts.append(obj.name)
        obj = obj.parent
    return '/'.join(reversed(parts))


def build_tree():
    vertices, triangles, owners, objects = [], [], array('I'), []
    offset = 0
    for instance in bpy.context.evaluated_depsgraph_get().object_instances:
        if instance.object.type != 'MESH' or not instance.show_self:
            continue
        obj = instance.object
        if obj.original.hide_render:
            continue
        mesh = obj.data
        mesh.calc_loop_triangles()
        if not mesh.loop_triangles:
            continue
        points = np.empty((len(mesh.vertices), 3), dtype=np.float32)
        mesh.vertices.foreach_get('co', points.ravel())
        matrix = np.asarray(instance.matrix_world)
        points = points @ matrix[:3, :3].T + matrix[:3, 3]
        faces = np.empty((len(mesh.loop_triangles), 3), dtype=np.int32)
        mesh.loop_triangles.foreach_get('vertices', faces.ravel())
        path = object_path(instance.parent.original if instance.is_instance else obj.original)
        objects.append({'path': path, 'mesh': obj.name,
                        'isInstance': instance.is_instance,
                        'matrixWorld': matrix.tolist(),
                        'boundsMeters': [points.min(axis=0).tolist(), points.max(axis=0).tolist()]})
        owners.extend([len(objects) - 1] * len(faces))
        vertices.extend(points.tolist())
        triangles.extend((faces + offset).tolist())
        offset += len(points)
    if not triangles:
        raise ValueError('No visible evaluated mesh triangles.')
    print(f'Building BVH: {len(objects)} placements, {len(triangles)} triangles', flush=True)
    tree = BVHTree.FromPolygons(vertices, triangles, all_triangles=True, epsilon=0.00001)
    return tree, owners, objects


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--navigation', required=True)
    parser.add_argument('--ui-data', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--sample-step', type=int, default=2)
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
    if args.sample_step < 1:
        parser.error('--sample-step must be positive')
    started = time.perf_counter()
    ui_objects = json.loads(Path(args.ui_data).read_text(encoding='utf-8-sig'))
    ui = next(o['Properties'] for o in ui_objects if 'XMultiplier' in o.get('Properties', {}))
    navigation = json.loads(Path(args.navigation).read_text())
    coordinate_scale = navigation['coordinateScale']

    def uv_to_world(u, v, z):
        # FModel mirrors Unreal Y in USD; Blender applies metersPerUnit=.01.
        return Vector(((v - ui['YScalarToAdd']) / ui['YMultiplier'] / 100,
                       -(u - ui['XScalarToAdd']) / ui['XMultiplier'] / 100,
                       z))

    def world_to_uv(p):
        return [(-p.y * 100) * ui['XMultiplier'] + ui['XScalarToAdd'],
                p.x * 100 * ui['YMultiplier'] + ui['YScalarToAdd']]

    tree, owners, objects = build_tree()

    def cast(start, end):
        delta = end - start
        location, normal, index, distance = tree.ray_cast(start, delta.normalized(), delta.length)
        return {'blocked': index is not None,
                'distanceMeters': float(distance) if distance is not None else delta.length,
                'hitMeters': list(location) if location is not None else None,
                'normal': list(normal) if normal is not None else None,
                'objectIndex': owners[index] if index is not None else None}

    # A real exported Mid crate measures 1.3m high. Check this geometry before
    # using a broad sweep. These are geometric assertions, not game eye heights.
    anchors = [o for o in objects if '/Crate_1_Wood_8/StaticMeshComponent0' in o['path']
               and o['path'].startswith('Bonsai_Art_Mid/')]
    calibration = []
    if navigation['map'] == 'split' and len(anchors) != 1:
        raise ValueError(f'Expected one Split Mid crate anchor, found {len(anchors)}')
    for anchor in anchors:
        low, high = map(Vector, anchor['boundsMeters'])
        middle = (low + high) / 2
        for height in [0.98, 1.5, 1.7]:
            a = Vector((low.x - 0.5, middle.y, low.z + height))
            b = Vector((high.x + 0.5, middle.y, low.z + height))
            calibration.append({'id': f'mid-crate-{height}', 'heightAboveCrateBase': height,
                                'startMeters': list(a), 'endMeters': list(b),
                                'sourceBoundsMeters': anchor['boundsMeters'], **cast(a, b)})
    if calibration:
        assert abs(calibration[0]['sourceBoundsMeters'][1][2] -
                   calibration[0]['sourceBoundsMeters'][0][2] - 1.3) < 0.002
        assert calibration[0]['blocked']
        assert 'Crate_1_Wood_8/' in objects[calibration[0]['objectIndex']]['path']
        assert all(not c['blocked'] for c in calibration[1:])

    rays, floors = [], []
    samples = navigation.get('heightSamples', [])
    if not samples:
        raise ValueError('No navigation height samples.')
    for index in range(0, len(samples), 3 * args.sample_step):
        u, v, z = samples[index:index + 3]
        seed = uv_to_world(u / coordinate_scale, v / coordinate_scale, z / 100)
        floor = cast(seed + Vector((0, 0, 0.6)), seed - Vector((0, 0, 1.2)))
        valid = (floor['blocked'] and floor['normal'][2] > 0.65
                 and abs(floor['hitMeters'][2] - seed.z) < 0.6)
        floors.append({'sample': index // 3, 'seedMeters': list(seed),
                       'accepted': valid, **floor})
        if not valid:
            continue
        base = Vector(floor['hitMeters'])
        for height in [0.98, 1.5, 1.7]:
            start = base + Vector((0, 0, height))
            for direction in range(16):
                angle = direction * math.tau / 16
                end = start + Vector((math.cos(angle) * 25, math.sin(angle) * 25, 0))
                hit = cast(start, end)
                # Tiny hits flag origins inside/against a surface for review.
                rays.append({'id': f'{index // 3}-{height}-{direction}',
                             'heightAboveFloorMeters': height,
                             'startMeters': list(start), 'endMeters': list(end),
                             'startUv': world_to_uv(start), 'endUv': world_to_uv(end),
                             'originNearSurface': hit['distanceMeters'] < 0.1, **hit})
    for c in calibration:
        start, end = Vector(c['startMeters']), Vector(c['endMeters'])
        rays.append({**c, 'startUv': world_to_uv(start), 'endUv': world_to_uv(end),
                     'heightAboveFloorMeters': c['heightAboveCrateBase'],
                     'originNearSurface': c['distanceMeters'] < 0.1})
    report = {'schemaVersion': 1, 'map': navigation['map'],
              'status': 'provisional-static-triangle-comparison', 'certified': False,
              'materialPolicy': 'All selected triangles treated as opaque, including unresolved materials.',
              'referenceBlend': bpy.data.filepath, 'referenceSha256': digest(bpy.data.filepath),
              'navigationSha256': digest(args.navigation), 'uiDataSha256': digest(args.ui_data),
              'summary': {'meshPlacements': len(objects), 'triangles': len(owners),
                          'floorSeeds': len(floors), 'acceptedFloors': sum(f['accepted'] for f in floors),
                          'rays': len(rays), 'blocked': sum(r['blocked'] for r in rays),
                          'seconds': time.perf_counter() - started},
              'calibration': calibration, 'floorChecks': floors, 'objects': objects, 'rays': rays,
              'limitations': ['Height sweep values are test parameters, not verified stance heights.',
                              'Navigation comes from an earlier extraction and only seeds candidate positions.',
                              'No game-camera or material-opacity ground truth has been certified.',
                              'Map-to-SVG registration must be validated before accepting disagreements.']}
    report['uiTransform'] = {k: ui[k] for k in ['XScalarToAdd', 'XMultiplier', 'YScalarToAdd', 'YMultiplier']}
    Path(args.output).write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('WORLD_RAYS ' + json.dumps(report['summary']), flush=True)
    print('CALIBRATION ' + json.dumps(calibration), flush=True)


if __name__ == '__main__':
    main()
