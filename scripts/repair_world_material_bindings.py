"""Resolve uncertain mesh bindings through verified USD source face indices.

Write a separate candidate world directory. Geometry positions, topology, UVs,
and native navigation remain unchanged. Only faces with a bound source material
are repaired; unbound source faces keep their conservative baseline policy.
Requires usd-core and numpy. Run bake_navigation_floors.py on each output map
before baking visibility.
"""
import argparse
from collections import Counter, defaultdict
import copy
import hashlib
import json
from pathlib import Path
import re
import shutil

import numpy as np

from world_visibility_materials import build_policy


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def normalized_path(path):
    return '/' + '/'.join(re.sub(r'\.\d{3,}$', '', part)
                          for part in path.split('/') if part)


def correspondence_error(expected, actual):
    """Check every face against its source; tolerate corner winding/order only."""
    if expected.shape != actual.shape:
        raise ValueError('Source and evaluated triangle counts disagree')
    if not len(expected):
        return 0.0
    distances = np.linalg.norm(expected[:, :, None] - actual[:, None, :], axis=3)
    # Both directions reject degenerate duplicates that could otherwise match
    # only one or two of a source triangle's vertices.
    return float(max(distances.min(axis=1).max(), distances.min(axis=2).max()))


def assign_bound_faces(material_indices, first_face, source_bindings, append_material,
                       repair_mask=None):
    """Source bindings contain disjoint local face IDs; None means unbound."""
    used = set()
    for face_ids, record in source_bindings:
        ids = [int(i) for i in face_ids]
        if len(ids) != len(set(ids)) or used.intersection(ids):
            raise ValueError('Overlapping source material subsets')
        used.update(ids)
        if record is not None:
            global_ids = np.asarray(ids, dtype=np.int64) + first_face
            if repair_mask is not None:
                global_ids = global_ids[repair_mask[global_ids]]
            if len(global_ids):
                material_indices[global_ids] = append_material(record)


def floor_candidates(triangles, xy, z_min, z_max):
    """Return upward triangle IDs/heights containing a world XY point."""
    if not len(triangles):
        return np.empty(0, dtype=int), np.empty(0)
    selected = np.flatnonzero(((triangles[:, :, :2].min(axis=1) <= xy + 1e-9).all(axis=1)) &
                             ((triangles[:, :, :2].max(axis=1) >= xy - 1e-9).all(axis=1)))
    t = triangles[selected]
    a, b = t[:, 1] - t[:, 0], t[:, 2] - t[:, 0]
    normal = np.cross(a, b)
    upward = normal[:, 2] > .65 * np.linalg.norm(normal, axis=1)
    t, selected = t[upward], selected[upward]
    a, b = t[:, 1] - t[:, 0], t[:, 2] - t[:, 0]
    determinant = a[:, 0] * b[:, 1] - a[:, 1] * b[:, 0]
    delta = xy - t[:, 0, :2]
    u = (delta[:, 0] * b[:, 1] - delta[:, 1] * b[:, 0]) / determinant
    v = (a[:, 0] * delta[:, 1] - a[:, 1] * delta[:, 0]) / determinant
    z = t[:, 0, 2] + u * a[:, 2] + v * b[:, 2]
    inside = (u >= -1e-9) & (v >= -1e-9) & (u + v <= 1 + 1e-9) & (z >= z_min) & (z <= z_max)
    return selected[inside], z[inside]


def update_floor_refinement(baseline, navigation, triangles, old_indices, new_indices, materials):
    """Recheck only columns whose admitted solid floor surfaces were removed."""
    import shapely

    def upward_index(source):
        normals = np.cross(source[:, 1] - source[:, 0], source[:, 2] - source[:, 0])
        indices = np.flatnonzero(normals[:, 2] > .65 * np.linalg.norm(normals, axis=1))
        xy = source[indices, :, :2]
        minimum, maximum = xy.min(axis=1), xy.max(axis=1)
        return indices, shapely.STRtree(shapely.box(
            minimum[:, 0], minimum[:, 1], maximum[:, 0], maximum[:, 1]))

    def candidates_at(tree, indices, seed):
        # Keep the same sub-micrometre edge tolerance as the barycentric check.
        search = shapely.box(seed[0] - 1e-9, seed[1] - 1e-9,
                             seed[0] + 1e-9, seed[1] + 1e-9)
        return indices[tree.query(search)]

    refined = copy.deepcopy(baseline)
    admitted = np.array([m['category'] in ('opaque', 'unresolved') for m in materials])
    removed = np.flatnonzero(admitted[old_indices] & ~admitted[new_indices])
    removed_triangles = triangles[removed]
    native = np.asarray(navigation['vertices'], dtype=float).reshape(-1, 3) / 100
    native[:, 1] *= -1
    affected = []
    if len(removed_triangles):
        removed_upward, removed_tree = upward_index(removed_triangles)
        for index, seed in enumerate(native):
            possible = candidates_at(removed_tree, removed_upward, seed)
            candidates, _ = floor_candidates(removed_triangles[possible], seed[:2], seed[2] - .6, seed[2] + .3)
            if len(candidates):
                affected.append(index)
    accepted_ids = np.flatnonzero(admitted[new_indices])
    accepted_triangles = triangles[accepted_ids] if affected else None
    if affected:
        accepted_upward, accepted_tree = upward_index(accepted_triangles)
    changed = []
    for index in affected:
        seed = native[index]
        possible = candidates_at(accepted_tree, accepted_upward, seed)
        candidates, heights = floor_candidates(accepted_triangles[possible], seed[:2], seed[2] - .6, seed[2] + .3)
        check = refined['checks'][index]
        previous = check['refinedZCm']
        if len(candidates):
            best = int(np.argmax(heights))
            face = int(accepted_ids[possible[candidates[best]]])
            normal = np.cross(triangles[face, 1] - triangles[face, 0],
                              triangles[face, 2] - triangles[face, 0])
            normal /= np.linalg.norm(normal)
            check.update(accepted=True, refinedZCm=float(heights[best] * 100),
                         materialCategory=materials[int(new_indices[face])]['category'],
                         normal=normal.tolist(), sourceFace=face)
            check.pop('estimatedFromMedianLift', None)
        else:
            check.update(accepted=False, materialCategory=None, normal=None)
        check['bindingRepairRechecked'] = True
        if check['accepted'] and abs(check['refinedZCm'] - previous) > .001:
            changed.append({'vertex': index, 'beforeCm': previous, 'afterCm': check['refinedZCm']})
    lifts = [c['sourceZCm'] - c['refinedZCm'] for c in refined['checks']
             if c['accepted'] and c['materialCategory'] == 'opaque']
    if not lifts:
        raise ValueError('No known opaque floor references remain')
    median = float(np.median(lifts))
    for check in refined['checks']:
        if not check['accepted']:
            check['refinedZCm'] = check['sourceZCm'] - median
            check['estimatedFromMedianLift'] = True
        refined['refinedFloorHeightsCm'][check['vertex']] = check['refinedZCm']
    refined['summary'].update(accepted=sum(c['accepted'] for c in refined['checks']),
                              medianNavLiftCm=median,
                              unresolvedSurfaceBindings=sum(c['accepted'] and
                                  c['materialCategory'] == 'unresolved' for c in refined['checks']))
    proof = {'removedSolidFaces': len(removed), 'potentiallyAffectedVertices': len(affected),
             'changedVertexHeights': changed,
             'finalChangedHeightCount': sum(abs(a - b) > .001 for a, b in zip(
                 baseline['refinedFloorHeightsCm'], refined['refinedFloorHeightsCm'])),
             'method': 'exact upward source triangles at affected native-navigation XY columns'}
    refined['bindingRepair'] = proof
    return refined, proof


def repair_map(world, audit_file, navigation_file, output):
    from pxr import Usd, UsdGeom, UsdShade

    if world.resolve() == output.resolve() or world.resolve() in output.resolve().parents:
        raise ValueError('Candidate must be separate from baseline world')
    metadata = json.loads((world / 'geometry.json').read_text())
    audit = json.loads(audit_file.read_text())
    if digest(world / 'geometry.npz') != metadata['geometrySha256']:
        raise ValueError('Baseline geometry fingerprint mismatch')
    if digest(audit_file) != metadata['materialAuditSha256']:
        raise ValueError('Source binding audit fingerprint mismatch')
    if digest(audit['source']) != audit['sourceSha256']:
        raise ValueError('Source USD fingerprint mismatch')
    raw = np.load(world / 'geometry.npz')
    arrays = {key: raw[key] for key in raw.files}
    original_indices = arrays['material_indices'].copy()
    materials = copy.deepcopy(metadata['materials'])
    uncertain_materials = np.array([m['category'] == 'unresolved' for m in materials])
    repair_mask = uncertain_materials[original_indices]
    new_ids = {}

    def append_material(record):
        identity = (record['source'], record['sourceSha256'])
        if identity not in new_ids:
            new_ids[identity] = len(materials)
            materials.append({key: record[key] for key in
                              ['source', 'sourceSha256', 'category', 'blendMode', 'missingTextures']
                              if key in record})
        return new_ids[identity]

    stage = Usd.Stage.Open(audit['source'])
    cache = UsdGeom.XformCache()
    placements = defaultdict(list)
    for obj in metadata['objects']:
        if repair_mask[obj['firstFace']:obj['firstFace'] + obj['faceCount']].any():
            placements[normalized_path(obj['path'])].append(obj)
    source_paths = {b['mesh'].split('/Prototypes/')[0]: b['mesh'] for b in audit['bindings']}
    object_reports, policy_changes, unresolved_placements = [], [], []
    for path in sorted(placements):
        source_path = source_paths.get(path, path)
        prim = stage.GetPrimAtPath(source_path)
        if not prim or not prim.IsA(UsdGeom.Mesh):
            unresolved_placements.extend({'path': obj['path'], 'reason': 'source-mesh-not-resolved',
                                          'firstFace': obj['firstFace'], 'faceCount': obj['faceCount']}
                                         for obj in placements[path])
            continue
        mesh = UsdGeom.Mesh(prim)
        counts = np.asarray(mesh.GetFaceVertexCountsAttr().Get())
        if not (counts == 3).all():
            raise ValueError('Non-triangulated USD source needs explicit face correspondence')
        indices = np.asarray(mesh.GetFaceVertexIndicesAttr().Get()).reshape(-1, 3)
        vertices = np.asarray(mesh.GetPointsAttr().Get())
        if '/Prototypes/' in source_path:
            instancer = UsdGeom.PointInstancer(stage.GetPrimAtPath(path))
            prototype_targets = instancer.GetPrototypesRel().GetTargets()
            if len(prototype_targets) != 1 or str(prototype_targets[0]) != source_path:
                raise ValueError('Multiple or nested source prototypes need explicit instance mapping')
            parent = np.asarray(cache.GetLocalToWorldTransform(instancer.GetPrim()))
            transforms = [np.asarray(t) @ parent for t in instancer.ComputeInstanceTransformsAtTime(
                Usd.TimeCode.Default(), Usd.TimeCode.Default())]
        else:
            transforms = [np.asarray(cache.GetLocalToWorldTransform(prim))]
        candidates = [(vertices @ t[:3, :3] + t[3, :3]) * .01 for t in transforms]
        source_bindings, binding_paths = [], []
        for subset in UsdShade.MaterialBindingAPI(prim).GetMaterialBindSubsets():
            material, _ = UsdShade.MaterialBindingAPI(subset.GetPrim()).ComputeBoundMaterial()
            record = audit['materials'].get(str(material.GetPath())) if material else None
            if record and (record.get('category') == 'unresolved' or not record.get('source')):
                record = None
            face_ids = np.asarray(subset.GetIndicesAttr().Get(), dtype=np.int64)
            if (face_ids < 0).any() or (face_ids >= len(indices)).any():
                raise ValueError('Invalid source material face index')
            source_bindings.append((face_ids, record))
            binding_paths.append(str(subset.GetPath()))
        covered = {int(face) for ids, _ in source_bindings for face in ids}
        remaining = np.asarray(sorted(set(range(len(indices))) - covered), dtype=np.int64)
        if len(remaining):
            material, _ = UsdShade.MaterialBindingAPI(prim).ComputeBoundMaterial()
            record = audit['materials'].get(str(material.GetPath())) if material else None
            if record and (record.get('category') == 'unresolved' or not record.get('source')):
                record = None
            source_bindings.append((remaining, record))
            binding_paths.append(source_path)
        for obj in placements[path]:
            first, count = obj['firstFace'], obj['faceCount']
            actual = arrays['points'][arrays['faces'][first:first + count]]
            matched = None
            for instance, candidate in enumerate(candidates):
                expected = candidate[indices]
                if expected.shape != actual.shape:
                    continue
                if np.max(np.abs(expected.mean(axis=(0, 1)) -
                                 actual.mean(axis=(0, 1), dtype=np.float64))) > .001:
                    continue
                error = correspondence_error(expected, actual)
                if error < .0001:
                    matched = instance, error
                    break
            if matched is None:
                raise ValueError(f'Cannot verify source face correspondence: {obj["path"]}')
            assign_bound_faces(arrays['material_indices'], first, source_bindings,
                               append_material, repair_mask=repair_mask)
            object_reports.append({'path': obj['path'], 'sourcePrim': source_path,
                                   'firstFace': first, 'faceCount': count,
                                   'sourceInstance': matched[0], 'maxCoordinateErrorMeters': matched[1]})
            for (face_ids, record), subset_path in zip(source_bindings, binding_paths):
                if not record or record['category'] in ('opaque', 'unresolved'):
                    continue
                policy = build_policy(record)
                if policy['mode'] == 'solid':
                    continue
                global_faces = face_ids + first
                global_faces = global_faces[repair_mask[global_faces]]
                if not len(global_faces):
                    continue
                triangles = arrays['points'][arrays['faces'][global_faces]]
                policy_changes.append({'sourceSubset': subset_path,
                                       'sourceFaces': global_faces.tolist(),
                                       'newMaterial': append_material(record),
                                       'policyMode': policy['mode'],
                                       'zIntervalCm': [float(triangles[:, :, 2].min() * 100),
                                                       float(triangles[:, :, 2].max() * 100)]})
    changed = np.flatnonzero(original_indices != arrays['material_indices'])
    output.mkdir(parents=True, exist_ok=True)
    if len(changed):
        np.savez_compressed(output / 'geometry.npz', **arrays)
    else:
        shutil.copy2(world / 'geometry.npz', output / 'geometry.npz')
    candidate_arrays = np.load(output / 'geometry.npz')
    preserved = {}
    for key in arrays:
        if key == 'material_indices':
            continue
        preserved[key] = np.array_equal(raw[key], candidate_arrays[key])
        if not preserved[key]:
            raise ValueError(f'Candidate changed source geometry array {key}')
    navigation = json.loads(navigation_file.read_text())
    baseline_refinement = json.loads((world / 'floor-refinement.json').read_text())
    if digest(navigation_file) != baseline_refinement['sourceXYZSha256']:
        raise ValueError('Navigation source fingerprint mismatch')
    refinement, floor_proof = update_floor_refinement(
        baseline_refinement, navigation, arrays['points'][arrays['faces']],
        original_indices, arrays['material_indices'], materials)
    (output / 'floor-refinement.json').write_text(json.dumps(refinement))
    remaining_unknown = np.array([m['category'] == 'unresolved' for m in materials])[arrays['material_indices']]
    report = {'schemaVersion': 2, 'map': metadata['map'], 'changed': bool(len(changed)),
              'baselineGeometrySha256': metadata['geometrySha256'],
              'candidateGeometrySha256': digest(output / 'geometry.npz'),
              'sourceUsdSha256': audit['sourceSha256'], 'materialAuditSha256': digest(audit_file),
              'toolSha256': digest(__file__), 'arraysPreservedExactly': preserved,
              'resolvedFaces': len(changed), 'placements': object_reports,
              'unresolvedPlacements': unresolved_placements,
              'remainingUnresolvedFaces': int(remaining_unknown.sum()),
              'remainingUnresolvedReasons': dict(Counter(materials[int(i)].get('reason', 'unresolved-source')
                  for i in arrays['material_indices'][remaining_unknown])),
              'policyChangedFaces': sum(len(p['sourceFaces']) for p in policy_changes),
              'policyChanges': policy_changes, 'floorRefinement': floor_proof}
    metadata['materials'] = materials
    metadata['geometrySha256'] = report['candidateGeometrySha256']
    metadata['bindingRepair'] = {key: report[key] for key in
                                ['baselineGeometrySha256', 'sourceUsdSha256', 'toolSha256',
                                 'resolvedFaces', 'policyChangedFaces', 'arraysPreservedExactly']}
    metadata['summary']['triangleMaterials'] = dict(Counter(
        materials[int(i)]['category'] for i in arrays['material_indices']))
    metadata['summary']['floorRefinement'] = refinement['summary']
    (output / 'geometry.json').write_text(json.dumps(metadata))
    (output / 'binding-repair.json').write_text(json.dumps(report, indent=2))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--world-root', type=Path, required=True)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--navigation-root', type=Path, required=True)
    parser.add_argument('--output-root', type=Path, required=True)
    parser.add_argument('--maps', nargs='*')
    args = parser.parse_args()
    maps = args.maps or sorted(p.name for p in args.world_root.iterdir() if (p / 'geometry.json').exists())
    manifest = {}
    for name in maps:
        report = repair_map(args.world_root / name, args.audit_root / name / 'materials.json',
                            args.navigation_root / f'{name}_source_xyz.json', args.output_root / name)
        summary = {key: value for key, value in report.items()
                   if key not in ('placements', 'policyChanges', 'unresolvedPlacements')}
        manifest[name] = summary
        print(json.dumps(summary), flush=True)
    args.output_root.mkdir(parents=True, exist_ok=True)
    (args.output_root / 'binding-repair-manifest.json').write_text(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
