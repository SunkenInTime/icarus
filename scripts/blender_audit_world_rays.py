"""Cast diagnostic rays through a Blender scene built from exported map art.

blender --background SCENE.blend --python scripts/blender_audit_world_rays.py --
  --navigation assets/maps/split_vision.json --ui-data Bonsai_UIData.json --output REPORT.json
  --eye-heights 1.55 1.75 1.95 --materials MATERIAL_AUDIT.json

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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from world_reference_materials import MaterialCatalog


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def object_path(obj):
    parts = []
    while obj:
        parts.append(obj.name)
        obj = obj.parent
    return '/'.join(reversed(parts))


def build_tree(material_audit=None, epsilon=0):
    vertices, triangles, owners, objects = [], [], array('I'), []
    triangle_materials, materials, material_ids = array('I'), [], {}
    catalog = MaterialCatalog(material_audit) if material_audit else None

    def material_id(name, unresolved_mesh=None):
        key = name, unresolved_mesh
        if key not in material_ids:
            material_ids[key] = len(materials)
            materials.append({'category': 'unresolved', 'reason': 'unresolved-source-binding',
                              'sourceMesh': unresolved_mesh, 'blenderName': name} if unresolved_mesh else
                             catalog.resolve(name) if catalog else
                             {'category': 'unresolved', 'reason': 'no-material-audit', 'blenderName': name})
        return material_ids[key]
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
        face_materials = np.empty(len(mesh.loop_triangles), dtype=np.int32)
        mesh.loop_triangles.foreach_get('material_index', face_materials)
        path = object_path(instance.parent.original if instance.is_instance else obj.original)
        unresolved_mesh = catalog.unresolved_mesh(path) if catalog else None
        slots = [material_id(slot.material.name if slot.material else None, unresolved_mesh) for slot in obj.material_slots]
        triangle_materials.extend(slots[i] if 0 <= i < len(slots) else material_id(None)
                                  for i in face_materials)
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
    # A positive BVH overlap epsilon can accept a nearby triangle outside the
    # exact ray. Keep the reference geometric; test tolerances belong in the
    # comparison, not in expanded source surfaces.
    tree = BVHTree.FromPolygons(vertices, triangles, all_triangles=True, epsilon=epsilon)
    return tree, owners, objects, triangle_materials, materials


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--navigation', required=True)
    parser.add_argument('--ui-data', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--sample-step', type=int, default=2)
    parser.add_argument('--sample-ids', type=int, nargs='+',
                        help='Restrict output to these seed IDs for repeatable fixtures.')
    parser.add_argument('--seed-reference',
                        help='Reuse candidate floor positions from a fingerprinted earlier ray report.')
    parser.add_argument('--eye-heights', type=float, nargs='+', required=True,
                        help='Explicit standing eye-height candidates in metres; these are test inputs, not certified defaults.')
    parser.add_argument('--directions', type=int, default=16)
    parser.add_argument('--materials', help='Material binding audit of the source scene.')
    parser.add_argument('--floor-grid', type=float,
                        help='Seed candidate floors from 3D geometry on this metre grid instead of navigation samples.')
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
    if args.sample_step < 1:
        parser.error('--sample-step must be positive')
    if args.directions < 4:
        parser.error('--directions must be at least 4')
    if any(not math.isfinite(h) or h <= 0 for h in args.eye_heights):
        parser.error('--eye-heights must be finite and positive')
    if args.floor_grid is not None and (not math.isfinite(args.floor_grid) or args.floor_grid <= 0):
        parser.error('--floor-grid must be finite and positive')
    if args.sample_ids and any(i < 0 for i in args.sample_ids):
        parser.error('--sample-ids must be nonnegative')
    if args.seed_reference and args.floor_grid is not None:
        parser.error('--seed-reference and --floor-grid are alternatives')
    eye_heights = sorted(set(args.eye_heights))
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

    material_audit = json.loads(Path(args.materials).read_text(encoding='utf-8')) if args.materials else None
    tree, owners, objects, triangle_materials, materials = build_tree(material_audit)

    def cast(start, end):
        delta = end - start
        location, normal, index, distance = tree.ray_cast(start, delta.normalized(), delta.length)
        return {'blocked': index is not None,
                'distanceMeters': float(distance) if distance is not None else delta.length,
                'hitMeters': list(location) if location is not None else None,
                'normal': list(normal) if normal is not None else None,
                'objectIndex': owners[index] if index is not None else None,
                'materialIndex': triangle_materials[index] if index is not None else None,
                'materialCategory': materials[triangle_materials[index]]['category'] if index is not None else None}

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
    seed_generation = {'source': 'navigation', 'sampleStep': args.sample_step}
    seeds = []
    if args.seed_reference:
        prior = json.loads(Path(args.seed_reference).read_text(encoding='utf-8'))
        if prior['referenceSha256'] != digest(bpy.data.filepath) or prior['map'] != navigation['map']:
            raise ValueError('Seed reference does not match the loaded map scene.')
        seeds = [(f['sample'], Vector(f['seedMeters'])) for f in prior['floorChecks']]
        seed_generation = {'source': 'recorded-candidates',
                           'referenceSha256': digest(args.seed_reference),
                           'originalGeneration': prior.get('seedGeneration', {'source': 'navigation'})}
    elif args.floor_grid is None:
        if not samples:
            raise ValueError('No navigation height samples. Use --floor-grid for explicitly provisional mesh candidates.')
        for index in range(0, len(samples), 3 if args.sample_ids else 3 * args.sample_step):
            u, v, z = samples[index:index + 3]
            seeds.append((index // 3, uv_to_world(u / coordinate_scale, v / coordinate_scale, z / 100)))
    else:
        # Multiple upward surfaces at the same XY remain separate candidates.
        # Head clearance alone does not establish walkability or reachability.
        corner_a, corner_b = uv_to_world(0, 0, 0), uv_to_world(1, 1, 0)
        lower = min(o['boundsMeters'][0][2] for o in objects) - 1
        upper = max(o['boundsMeters'][1][2] for o in objects) + 1
        clearance = max(eye_heights) + 0.05
        truncated = []
        columns = 0
        for x in np.arange(min(corner_a.x, corner_b.x), max(corner_a.x, corner_b.x), args.floor_grid):
            for y in np.arange(min(corner_a.y, corner_b.y), max(corner_a.y, corner_b.y), args.floor_grid):
                columns += 1
                top = upper
                for _ in range(128):
                    hit = cast(Vector((x, y, top)), Vector((x, y, lower)))
                    if not hit['blocked']:
                        break
                    point = Vector(hit['hitMeters'])
                    if hit['normal'][2] > 0.65 and hit['materialCategory'] == 'opaque':
                        headroom = cast(point + Vector((0, 0, 0.01)), point + Vector((0, 0, clearance)))
                        if not headroom['blocked']:
                            seeds.append((len(seeds), point))
                    top = point.z - 0.01
                    if top <= lower:
                        break
                else:
                    truncated.append([float(x), float(y)])
        seed_generation = {'source': 'mesh-grid', 'spacingMeters': args.floor_grid,
                           'uvBounds': [0, 0, 1, 1], 'columns': columns,
                           'verticalClearanceMeters': clearance,
                           'truncatedColumns': truncated, 'walkabilityCertified': False,
                           'limitations': ['Roof and prop tops can pass this geometric check.',
                                           'No movement capsule or connected walkable region is inferred.']}
        print('MESH_FLOOR_CANDIDATES ' + json.dumps({'seeds': len(seeds), **seed_generation}), flush=True)
    if args.sample_ids:
        wanted = set(args.sample_ids)
        seeds = [(sample, seed) for sample, seed in seeds if sample in wanted]
        if {sample for sample, _ in seeds} != wanted:
            raise ValueError('Requested seed IDs are missing.')
        seed_generation['sampleIds'] = sorted(wanted)
    for sample, seed in seeds:
        floor = cast(seed + Vector((0, 0, 0.6)), seed - Vector((0, 0, 1.2)))
        valid = (floor['blocked'] and floor['normal'][2] > 0.65
                 and abs(floor['hitMeters'][2] - seed.z) < 0.6)
        floors.append({'sample': sample, 'seedMeters': list(seed),
                       'accepted': valid, **floor})
        if not valid:
            continue
        base = Vector(floor['hitMeters'])
        for height in eye_heights:
            start = base + Vector((0, 0, height))
            for direction in range(args.directions):
                angle = direction * math.tau / args.directions
                end = start + Vector((math.cos(angle) * 25, math.sin(angle) * 25, 0))
                hit = cast(start, end)
                # Tiny hits flag origins inside/against a surface for review.
                rays.append({'id': f'{sample}-{height}-{direction}',
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
              'visibilityModel': 'Horizontal standing sightlines; height candidates measure sensitivity, not stances.',
              'eyeHeightCandidatesMeters': eye_heights,
              'directionsPerOrigin': args.directions,
              'bvhEpsilonMeters': 0,
              'seedGeneration': seed_generation,
              'materialAuditSha256': digest(args.materials) if args.materials else None,
              'referenceBlend': bpy.data.filepath, 'referenceSha256': digest(bpy.data.filepath),
              'navigationSha256': digest(args.navigation), 'uiDataSha256': digest(args.ui_data),
              'summary': {'meshPlacements': len(objects), 'triangles': len(owners),
                          'floorSeeds': len(floors), 'acceptedFloors': sum(f['accepted'] for f in floors),
                          'rays': len(rays), 'blocked': sum(r['blocked'] for r in rays),
                          'seconds': time.perf_counter() - started},
              'calibration': calibration, 'floorChecks': floors, 'objects': objects,
              'materials': materials, 'rays': rays,
              'limitations': ['Standing height candidates are test parameters, not verified camera heights.',
                              'Parsed blend modes annotate first hits; uncertain surfaces are never silently removed.',
                              'Seed generation identifies candidate surfaces, not certified playable floors.',
                              'No game-camera or material-opacity ground truth has been certified.',
                              'Map-to-SVG registration must be validated before accepting disagreements.']}
    report['uiTransform'] = {k: ui[k] for k in ['XScalarToAdd', 'XMultiplier', 'YScalarToAdd', 'YMultiplier']}
    Path(args.output).write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('WORLD_RAYS ' + json.dumps(report['summary']), flush=True)
    print('CALIBRATION ' + json.dumps(calibration), flush=True)


if __name__ == '__main__':
    main()
