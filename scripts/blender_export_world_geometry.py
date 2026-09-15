"""Export placed map triangles, texture coordinates and refined navigation floors.

Run inside the fingerprinted reference Blender scene. The output is an offline
build input; no game meshes or texture files are copied into application assets.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys
import time

import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from world_reference_materials import MaterialCatalog
from blender_audit_world_rays import object_path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--navigation', required=True, help='Stable source XYZ navigation sidecar.')
    parser.add_argument('--materials', required=True)
    parser.add_argument('--ui-data', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
    started = time.perf_counter()
    folder = Path(args.output)
    folder.mkdir(parents=True, exist_ok=True)
    navigation = json.loads(Path(args.navigation).read_text(encoding='utf-8'))
    material_audit = json.loads(Path(args.materials).read_text(encoding='utf-8'))
    ui_values = json.loads(Path(args.ui_data).read_text(encoding='utf-8-sig'))
    ui = next(v['Properties'] for v in ui_values if 'XMultiplier' in v.get('Properties', {}))
    catalog = MaterialCatalog(material_audit)
    points_parts, face_parts, uv_parts, material_parts = [], [], [], []
    objects, materials, material_ids = [], [], {}
    point_offset, face_offset = 0, 0

    def material_id(name, unresolved):
        key = name, unresolved
        if key not in material_ids:
            material_ids[key] = len(materials)
            record = {'category': 'unresolved', 'blenderName': name,
                      'sourceMesh': unresolved, 'reason': 'unresolved-source-binding'} if unresolved else catalog.resolve(name)
            materials.append(record)
        return material_ids[key]

    for instance in bpy.context.evaluated_depsgraph_get().object_instances:
        obj = instance.object
        if obj.type != 'MESH' or not instance.show_self or obj.original.hide_render:
            continue
        mesh = obj.data
        mesh.calc_loop_triangles()
        count = len(mesh.loop_triangles)
        if not count:
            continue
        points = np.empty((len(mesh.vertices), 3), dtype=np.float32)
        mesh.vertices.foreach_get('co', points.ravel())
        transform = np.asarray(instance.matrix_world)
        points = points @ transform[:3, :3].T + transform[:3, 3]
        faces = np.empty((count, 3), dtype=np.int32)
        mesh.loop_triangles.foreach_get('vertices', faces.ravel())
        loops = np.empty((count, 3), dtype=np.int32)
        mesh.loop_triangles.foreach_get('loops', loops.ravel())
        uvs = np.full((count, 3, 2), np.nan, dtype=np.float32)
        if mesh.uv_layers.active:
            uv_values = np.empty((len(mesh.loops), 2), dtype=np.float32)
            mesh.uv_layers.active.data.foreach_get('uv', uv_values.ravel())
            uvs = uv_values[loops]
        slots = np.empty(count, dtype=np.int32)
        mesh.loop_triangles.foreach_get('material_index', slots)
        path = object_path(instance.parent.original if instance.is_instance else obj.original)
        unresolved = catalog.unresolved_mesh(path)
        bindings = [material_id(s.material.name if s.material else None, unresolved) for s in obj.material_slots]
        missing = material_id(None, unresolved)
        ids = np.array([bindings[i] if 0 <= i < len(bindings) else missing for i in slots], dtype=np.uint32)
        points_parts.append(points)
        face_parts.append((faces + point_offset).astype(np.uint32))
        uv_parts.append(uvs)
        material_parts.append(ids)
        objects.append({'path': path, 'firstFace': face_offset, 'faceCount': count,
                        'boundsMeters': [points.min(axis=0).tolist(), points.max(axis=0).tolist()]})
        point_offset += len(points)
        face_offset += count
    points = np.concatenate(points_parts)
    faces = np.concatenate(face_parts)
    uvs = np.concatenate(uv_parts)
    material_indices = np.concatenate(material_parts)
    del points_parts, face_parts, uv_parts, material_parts
    if not np.all(np.isfinite(points)):
        raise ValueError('Nonfinite world points.')
    print(json.dumps({'map': navigation['map'], 'points': len(points), 'triangles': len(faces)}), flush=True)
    np.savez_compressed(folder / 'geometry.npz', points=points, faces=faces,
                        uvs=uvs, material_indices=material_indices)

    # Navigation is lifted above surfaces by Recast's voxel build. Recast supplies
    # topology and reachable regions; the actual mesh supplies the eye's floor Z.
    tree = BVHTree.FromPolygons(points.tolist(), faces.tolist(), all_triangles=True, epsilon=0)
    raw_vertices = np.asarray(navigation['vertices'], dtype=float).reshape(-1, 3)
    heights, checks = [], []
    for index, raw in enumerate(raw_vertices):
        seed = Vector((raw[0] / 100, -raw[1] / 100, raw[2] / 100))
        start = seed + Vector((0, 0, 0.3))
        end = seed - Vector((0, 0, 0.7))
        accepted, category, normal = False, None, None
        for _ in range(64):
            hit, normal, face, distance = tree.ray_cast(start, Vector((0, 0, -1)), start.z - end.z)
            if face is None:
                break
            category = materials[int(material_indices[face])]['category']
            # Look through texture overlays and foliage to the solid surface.
            accepted = (normal.z > 0.65 and abs(hit.z - seed.z) <= 0.6
                        and category in ['opaque', 'unresolved'])
            if accepted:
                break
            start = hit - Vector((0, 0, 0.0001))
            if start.z <= end.z:
                break
        height = hit.z * 100 if accepted else float(raw[2])
        heights.append(height)
        checks.append({'vertex': index, 'sourceZCm': float(raw[2]), 'refinedZCm': height,
                       'accepted': accepted, 'materialCategory': category,
                       'normal': list(normal) if normal else None})
    measured_lifts = [c['sourceZCm'] - c['refinedZCm'] for c in checks
                      if c['accepted'] and c['materialCategory'] == 'opaque']
    if not measured_lifts:
        raise ValueError('No solid floor references for the navigation mesh.')
    median_lift = float(np.median(measured_lifts))
    for check in checks:
        if not check['accepted']:
            check['refinedZCm'] = check['sourceZCm'] - median_lift
            check['estimatedFromMedianLift'] = True
            heights[check['vertex']] = check['refinedZCm']
    refinement = {'schemaVersion': 1, 'map': navigation['map'],
                  'navigationSha256': navigation['navigationSha256'],
                  'sourceXYZSha256': digest(args.navigation),
                  'refinedFloorHeightsCm': heights, 'checks': checks,
                  'summary': {'vertices': len(heights), 'accepted': sum(c['accepted'] for c in checks),
                              'medianNavLiftCm': median_lift,
                              'unresolvedSurfaceBindings': sum(c['accepted'] and c['materialCategory'] == 'unresolved' for c in checks)}}
    (folder / 'floor-refinement.json').write_text(json.dumps(refinement), encoding='utf-8')
    metadata = {'schemaVersion': 1, 'map': navigation['map'],
                'referenceBlend': bpy.data.filepath, 'referenceSha256': digest(bpy.data.filepath),
                'materialAuditSha256': digest(args.materials), 'uiDataSha256': digest(args.ui_data),
                'geometrySha256': digest(folder / 'geometry.npz'),
                'uiTransform': {k: ui[k] for k in ['XMultiplier', 'XScalarToAdd', 'YMultiplier', 'YScalarToAdd']},
                'materials': materials, 'objects': objects,
                'summary': {'placements': len(objects), 'triangles': len(faces), 'points': len(points),
                            'triangleMaterials': dict(Counter(materials[int(i)]['category'] for i in material_indices)),
                            'floorRefinement': refinement['summary'], 'seconds': time.perf_counter() - started}}
    (folder / 'geometry.json').write_text(json.dumps(metadata), encoding='utf-8')
    print(json.dumps(metadata['summary']), flush=True)


if __name__ == '__main__':
    main()
