"""Verify placed Art material slots against native mesh sections and overrides.

USD geometry is used only after checking every placed triangle's correspondence.
Material identity comes from native section.MaterialIndex, StaticMaterials and
the placed component's OverrideMaterials. USD material bindings are not trusted.
Writes reports and separate candidate worlds; never modifies source worlds.
"""
import argparse
from collections import Counter, defaultdict
import copy
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re
import shutil

import numpy as np

from repair_world_material_bindings import correspondence_error, normalized_path
from world_visibility_materials import build_policy


@lru_cache(maxsize=None)
def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def sanitized(name):
    return ('_' if name[:1].isdigit() else '') + re.sub('[^a-zA-Z0-9_]', '_', name or '_unnamed')


def object_name(pointer):
    return pointer['ObjectName'].split("'", 1)[1].rstrip("'").split('.')[-1]


def package_path(pointer):
    if not isinstance(pointer, dict) or not pointer.get('ObjectPath'):
        return None
    return pointer['ObjectPath'].rsplit('.', 1)[0]


def relative_package(package, suffix='.json'):
    if package.startswith('/Game/'):
        return 'ShooterGame/Content/' + package[len('/Game/'):] + suffix
    if package.startswith('/Engine/'):
        return 'Engine/Content/' + package[len('/Engine/'):] + suffix
    raise ValueError(f'Unsupported game package {package}')


def native_level(path):
    """Replay Level.Actors naming, including duplicate labels and attached roots.

    CUE4Parse UsdWorldFormat and UsdPrim.Add determine this order. The replay
    matches the independent supplementary-source actor audit.
    """
    data = json.loads(Path(path).read_bytes())
    level = next(o for o in data if o['Type'] == 'Level')
    actors = {o['Name']: o for o in data if isinstance(o.get('Outer'), dict)
              and o['Outer'].get('ObjectName', '').startswith("Level'")}
    mapping, taken = {}, set()
    component_by_pointer = {}
    for index, obj in enumerate(data):
        obj['_nativeExportIndex'] = index
        if isinstance(obj.get('Outer'), dict):
            outer_path = obj['Outer'].get('ObjectName', '').split("'", 1)
            if len(outer_path) == 2:
                key = obj['Type'] + "'" + outer_path[1].rstrip("'") + '.' + obj['Name'] + "'"
                component_by_pointer[key] = obj
    for pointer in level['Actors']:
        if not pointer:
            continue
        actor = actors.get(object_name(pointer))
        if actor is None:
            continue
        root = actor.get('Properties', {}).get('RootComponent')
        if isinstance(root, dict):
            source_component = component_by_pointer.get(root.get('ObjectName'))
            if source_component and source_component.get('Properties', {}).get('AttachParent'):
                continue
        name = sanitized(actor.get('ActorLabel') or actor['Name'])
        candidate, number = name, 1
        while candidate in taken:
            candidate = name + '_' + str(number)
            number += 1
        taken.add(candidate)
        mapping[candidate] = actor
    return data, mapping


def policy_signature(policy):
    """Only source policy behavior, without confidence or audit-file identity."""
    if policy['mode'] != 'alpha-test':
        return policy['mode']
    excluded = {'source', 'sourceSha256', 'usdSource', 'usdSha256', 'blenderName',
                'category', 'gameplayCertified', 'certain', 'reason', 'flags',
                'blendMode', 'texture', 'textureSource'}
    return json.dumps({k: v for k, v in policy.items() if k not in excluded}, sort_keys=True)


def native_section_materials(sections, slots, overrides, authored_sections, face_count, resolve):
    """Map native slot indices directly, preserving repeated material slots."""
    coverage = np.zeros(face_count, dtype=np.uint8)
    expected_ids = np.empty(face_count, dtype=np.uint32)
    records = []
    for section_index, section in enumerate(sections):
        first = section['FirstIndex'] // 3
        last = first + section['NumTriangles']
        if section['FirstIndex'] % 3 or first < 0 or last > face_count:
            raise ValueError('Native section range does not match source triangles.')
        authored, authored_index = authored_sections[section_index]
        if authored is None or list(authored) != list(range(first, last)):
            raise ValueError('Native section face range differs from authored USD subset.')
        index = section['MaterialIndex']
        if authored_index != index:
            raise ValueError('Native section material index differs from USD custom metadata.')
        ref = overrides[index] if index < len(overrides) and overrides[index] else slots[index].get('MaterialInterface')
        package = package_path(ref)
        if package is None:
            raise ValueError('Native effective material has no package.')
        material_id, policy = resolve(package, ref)
        expected_ids[first:last] = material_id
        coverage[first:last] += 1
        records.append({'section': section_index, 'materialIndex': index,
            'firstFace': first, 'faceCount': last - first, 'effectivePackage': package,
            'effectiveReference': ref,
            'policyMode': policy['mode'], 'certain': policy['certain']})
    if not (coverage == 1).all():
        raise ValueError('Native sections do not cover every source face exactly once.')
    return expected_ids, records


def floor_eligibility_changes(arrays, before, materials, navigation_path):
    """Check every changed upward face against the original floor bake window."""
    import shapely
    from bake_navigation_floors import plane, clip_halfplane
    admitted = np.asarray([m['category'] in ('opaque', 'unresolved') for m in materials])
    changed = np.flatnonzero(admitted[before] != admitted[arrays['material_indices']])
    triangles = arrays['points'][arrays['faces'][changed]]
    normals = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
    upward = normals[:, 2] > .65 * np.linalg.norm(normals, axis=1)
    changed, triangles = changed[upward], triangles[upward]
    result = {'changedUpwardFaces': len(changed), 'clippedPieces': [], 'floorValuesPreserved': True}
    if not len(changed):
        return result
    nav = json.loads(navigation_path.read_bytes())
    vertices = np.asarray(nav['vertices']).reshape(-1, 3) / 100
    vertices[:, 1] *= -1
    faces = np.asarray(nav['triangles']).reshape(-1, 4)
    nav_triangles = vertices[faces[:, 1:]]
    nav_polygons = shapely.polygons(nav_triangles[:, :, :2])
    tree = shapely.STRtree(nav_polygons)
    for source_face, triangle in zip(changed, triangles):
        shape = shapely.Polygon(triangle[:, :2])
        coefficients = plane(triangle)
        for row in tree.query(shape, predicate='intersects'):
            intersection = shape.intersection(nav_polygons[row])
            if intersection.geom_type != 'Polygon' or intersection.area < 1e-8:
                continue
            points = list(intersection.exterior.coords)[:-1]
            delta = coefficients - plane(nav_triangles[row])
            points = clip_halfplane(points, delta, .30001)
            points = clip_halfplane(points, -delta, .60001)
            if len(points) < 3:
                continue
            area = shapely.Polygon(points).area
            if area < 1e-8:
                continue
            result['clippedPieces'].append({'sourceFace': int(source_face),
                'parentNavPolygon': int(faces[row, 0]), 'areaSquareMeters': area,
                'becameFloorEligible': bool(admitted[arrays['material_indices'][source_face]])})
    result['floorValuesPreserved'] = not result['clippedPieces']
    return result


def audit_map(name, world, verification, level_root, mesh_root, output, texture_root,
              *, stage_world=False, resolved_root=None, extra_mesh_roots=(),
              extra_level_roots=(), extra_resolved_roots=(), material_roots=(), navigation_root=None):
    from pxr import Usd, UsdGeom
    world, output = Path(world), Path(output)
    if world.resolve() == output.resolve() or world.resolve() in output.resolve().parents:
        raise ValueError('The native candidate must be separate from the frozen world.')
    metadata = json.loads((world / 'geometry.json').read_bytes())
    binding = json.loads((verification / 'materials.json').read_bytes())
    if digest(world / 'geometry.npz') != metadata['geometrySha256']:
        raise ValueError('Frozen world fingerprint mismatch.')
    if digest(binding['source']) != binding['sourceSha256']:
        raise ValueError('Source USD fingerprint mismatch.')
    stage = Usd.Stage.Open(binding['source'])
    cache = UsdGeom.XformCache()
    raw = np.load(world / 'geometry.npz')
    arrays = {key: raw[key] for key in raw.files}
    before = arrays['material_indices'].copy()
    materials = copy.deepcopy(metadata['materials'])
    # Old records may deliberately mark an otherwise known package unresolved
    # because its USD binding was ambiguous. Native proof must get its own
    # record rather than retaining that old policy through a matching hash.
    material_ids = {}
    old_policies = [build_policy(m, texture_properties_root=texture_root) for m in materials]
    policies = list(old_policies)
    groups = defaultdict(list)
    for obj in metadata['objects']:
        groups[normalized_path(obj['path'])].append(obj)
    source_paths = {b['mesh'].split('/Prototypes/')[0]: b['mesh'] for b in binding['bindings']}
    records, errors, changes = [], [], []

    @lru_cache(maxsize=None)
    def load_level(path):
        data, actors = native_level(path)
        if resolved_root:
            relative = next(Path(path).relative_to(r) for r in (level_root, *extra_level_roots)
                            if Path(path).is_relative_to(r))
            sidecar = next((r / relative for r in (resolved_root, *extra_resolved_roots)
                            if (r / relative).exists()), resolved_root / relative)
            for row in json.loads(sidecar.read_bytes()):
                obj = data[row['exportIndex']]
                if obj['Name'] != row['name']:
                    raise ValueError('Resolved native component index/name mismatch.')
                props = obj.setdefault('Properties', {})
                props['StaticMesh'] = row['mesh']
                props['OverrideMaterials'] = row['overrideMaterials']
                obj['_resolvedComponentSha256'] = digest(sidecar)
        return data, actors

    @lru_cache(maxsize=None)
    def load_mesh(package):
        path = mesh_root / relative_package(package)
        if not path.exists():
            path = next((r / relative_package(package) for r in extra_mesh_roots
                         if (r / relative_package(package)).exists()), path)
        data = json.loads(path.read_bytes())
        mesh = next(o for o in data if o['Type'] == 'StaticMesh')
        return path, mesh

    @lru_cache(maxsize=None)
    def native_material(package, export_root, serialized_ref):
        ref = json.loads(serialized_ref)
        source = Path(export_root) / relative_package(package)
        native_name = ref.get('ObjectName', '')
        if ':' in native_name:
            object_chain = native_name.split("'", 1)[1].rstrip("'").split(':', 1)[1]
            source = Path(export_root) / relative_package(package, suffix='') / (object_chain.replace('.', '/') + '.json')
        if not source.exists():
            candidates = [r / relative_package(package) for r in material_roots
                          if (r / relative_package(package)).exists()]
            if not candidates:
                raise ValueError(f'Material source is absent: {source}')
            if len({digest(p) for p in candidates}) != 1:
                raise ValueError(f'Native material has conflicting extracted sources: {package}')
            source = candidates[0]
        data = json.loads(source.read_text(encoding='utf-8-sig'))
        blend = data.get('Parameters', {}).get('BlendMode')
        if type(blend) is not int:
            raise ValueError(f'Material source has no native blend: {source}')
        record = {'source': str(source), 'sourceSha256': digest(source), 'blendMode': blend,
                  'category': 'opaque' if blend == 0 else 'masked' if blend == 1 else 'shader-dependent',
                  'nativeMaterialPackage': package, 'nativeMaterialReference': ref}
        policy = build_policy(record, texture_properties_root=texture_root)
        key = (record['source'], record['sourceSha256'])
        if key not in material_ids:
            material_ids[key] = len(materials)
            materials.append(record)
            policies.append(policy)
        return material_ids[key], policy

    for path, objects in sorted(groups.items()):
        try:
            source_path = source_paths.get(path, path)
            prim = stage.GetPrimAtPath(source_path)
            if not prim or not prim.IsA(UsdGeom.Mesh):
                raise ValueError('Placed source mesh is absent.')
            specs = [s for s in prim.GetPrimStack() if s.typeName == 'Mesh']
            level_specs = [s for s in specs if '/Maps/' in s.layer.realPath.replace('\\', '/')]
            if not level_specs:
                raise ValueError('Placed source level is absent.')
            source_level = Path(level_specs[0].layer.realPath)
            relative = source_level.as_posix().split('/Exports/')[1]
            native_path = (level_root / relative).with_suffix('.json')
            if not native_path.exists():
                native_path = next(((r / relative).with_suffix('.json') for r in extra_level_roots
                    if (r / relative).with_suffix('.json').exists()), native_path)
            exports, actors = load_level(native_path)
            source_parts = source_path.split('/')
            scopes = [('/'.join(source_parts[:i + 1]), source_parts[i])
                for i in range(2, len(source_parts)) if source_parts[i] != 'Prototypes'
                and stage.GetPrimAtPath('/'.join(source_parts[:i + 1])).GetTypeName() == 'Scope']
            actor_name = scopes[0][1]
            actor = actors.get(actor_name)
            if actor is None:
                raise ValueError(f'Native actor label cannot be replayed: {actor_name}')
            for scope_path, attached_name in scopes[1:]:
                parent_component_name = scope_path.split('/')[-2]
                candidates = []
                for candidate in exports:
                    if sanitized(candidate.get('ActorLabel') or candidate['Name']) != attached_name:
                        continue
                    root_ref = candidate.get('Properties', {}).get('RootComponent')
                    if not package_path(root_ref):
                        continue
                    root_component = exports[int(root_ref['ObjectPath'].rsplit('.', 1)[1])]
                    attach_ref = root_component.get('Properties', {}).get('AttachParent')
                    if not package_path(attach_ref):
                        continue
                    parent_component = exports[int(attach_ref['ObjectPath'].rsplit('.', 1)[1])]
                    if (sanitized(parent_component['Name']) == parent_component_name and
                            parent_component.get('Outer', {}).get('ObjectName', '').endswith('.' + actor['Name'] + "'")):
                        candidates.append(candidate)
                if len(candidates) != 1:
                    raise ValueError(f'Attached native actor cannot be uniquely replayed: {attached_name}')
                actor = candidates[0]
            component_name = source_path.split('/')[-1]
            component_candidates = [o for o in exports if
                isinstance(o.get('Outer'), dict) and
                o['Outer'].get('ObjectName', '').endswith('.' + actor['Name'] + "'") and
                sanitized(o['Name']) == component_name and
                package_path(o.get('Properties', {}).get('StaticMesh'))]
            if len(component_candidates) != 1:
                raise ValueError(f'Expected one native mesh component, found {len(component_candidates)}')
            component = component_candidates[0]
            mesh_package = package_path(component['Properties']['StaticMesh'])
            mesh_path, native = load_mesh(mesh_package)
            sections = native['RenderData']['LODs'][0]['Sections']
            mesh = UsdGeom.Mesh(prim)
            face_counts = np.asarray(mesh.GetFaceVertexCountsAttr().Get())
            if not (face_counts == 3).all():
                raise ValueError('Non-triangulated source mesh.')
            face_count = len(face_counts)
            indices = np.asarray(mesh.GetFaceVertexIndicesAttr().Get()).reshape(-1, 3)
            vertices = np.asarray(mesh.GetPointsAttr().Get())
            overrides = component['Properties'].get('OverrideMaterials', [])
            slots = native['Properties']['StaticMaterials']
            export_root = source_level.as_posix().split('/Exports/')[0] + '/Exports'
            authored_sections = []
            for section_index, section in enumerate(sections):
                subset = stage.GetPrimAtPath(source_path + f'/Section_{section_index}')
                authored = subset.GetAttribute('indices').Get() if subset else None
                authored_sections.append((authored, subset.GetAttribute('unrealMaterialIndex').Get() if subset else None))
            expected_ids, slot_records = native_section_materials(sections, slots, overrides,
                authored_sections, face_count, lambda package, ref: native_material(package, export_root,
                                                                                  json.dumps(ref, sort_keys=True)))
            if '/Prototypes/' in source_path:
                instancer = UsdGeom.PointInstancer(stage.GetPrimAtPath(path))
                targets = instancer.GetPrototypesRel().GetTargets()
                if len(targets) != 1 or str(targets[0]) != source_path:
                    raise ValueError('Multiple source prototypes need explicit mapping.')
                parent = np.asarray(cache.GetLocalToWorldTransform(instancer.GetPrim()))
                transforms = [np.asarray(t) @ parent for t in instancer.ComputeInstanceTransformsAtTime(
                    Usd.TimeCode.Default(), Usd.TimeCode.Default())]
            else:
                transforms = [np.asarray(cache.GetLocalToWorldTransform(prim))]
            local_center = vertices[indices].mean(axis=(0, 1), dtype=np.float64)
            candidate_centers = np.asarray([(local_center @ t[:3, :3] + t[3, :3]) * .01
                                            for t in transforms])
            for obj in objects:
                first, count = obj['firstFace'], obj['faceCount']
                actual = arrays['points'][arrays['faces'][first:first + count]]
                matched = None
                actual_center = actual.mean(axis=(0, 1), dtype=np.float64)
                possible = np.flatnonzero(np.max(abs(candidate_centers - actual_center), axis=1) <= .001)
                for instance in possible:
                    if len(indices) != count:
                        continue
                    t = transforms[instance]
                    candidate = (vertices @ t[:3, :3] + t[3, :3]) * .01
                    expected = candidate[indices]
                    error = correspondence_error(expected, actual)
                    # Include the local conversion budget plus two float32
                    # world-coordinate representable steps per axis. A cloud
                    # card 3km away has larger ULPs than playable geometry.
                    # This only verifies correspondence; no point is changed.
                    ulp = np.spacing(np.max(abs(actual), axis=(0, 1)).astype(np.float32))
                    tolerance = .0001 + 2 * float(np.linalg.norm(ulp))
                    if error <= tolerance:
                        matched = int(instance), error, tolerance
                        break
                if matched is None:
                    raise ValueError(f'Placed triangle correspondence failed: {obj["path"]}')
                old = before[first:first + count]
                pairs = np.unique(np.stack([old, expected_ids], axis=1), axis=0)
                for old_id, new_id in pairs:
                    if policy_signature(policies[old_id]) != policy_signature(policies[new_id]):
                        local_faces = np.flatnonzero((old == old_id) & (expected_ids == new_id))
                        z = actual[local_faces, :, 2]
                        changes.append({'path': obj['path'], 'faces': (local_faces + first).tolist(),
                            'beforeMaterial': int(old_id), 'afterMaterial': int(new_id),
                            'beforeMode': policies[old_id]['mode'], 'afterMode': policies[new_id]['mode'],
                            'zIntervalCm': [float(z.min() * 100), float(z.max() * 100)]})
                arrays['material_indices'][first:first + count] = expected_ids
                records.append({'path': obj['path'], 'firstFace': first, 'faceCount': count,
                    'nativeLevel': str(native_path), 'nativeLevelSha256': digest(native_path),
                    'nativeActor': actor['Name'], 'nativeComponentIndex': component['_nativeExportIndex'],
                    'resolvedComponentSha256': component.get('_resolvedComponentSha256'),
                    'nativeMesh': mesh_package, 'nativeMeshSha256': digest(mesh_path),
                    'sourcePrim': source_path, 'sourceInstance': matched[0],
                    'coordinateErrorMeters': matched[1], 'coordinateToleranceMeters': matched[2],
                    'placementDeterminant': float(np.linalg.det(transforms[matched[0]][:3, :3])),
                    'sections': slot_records})
        except (ValueError, KeyError, StopIteration, FileNotFoundError, IndexError) as error:
            errors.append({'sourcePrim': path, 'reason': str(error), 'placements': len(objects),
                           'faces': sum(o['faceCount'] for o in objects)})
    output.mkdir(parents=True, exist_ok=True)
    report = {'schemaVersion': 1, 'map': name, 'baselineGeometrySha256': metadata['geometrySha256'],
        'nativeSlotToolSha256': digest(__file__), 'sourceUsdSha256': binding['sourceSha256'],
        'placements': records, 'errors': errors, 'policyChanges': changes,
        'changedMaterials': {str(i): materials[i] for i in sorted({c[k] for c in changes
            for k in ('beforeMaterial', 'afterMaterial')})},
        'summary': {'totalPlacements': len(metadata['objects']), 'verifiedPlacements': len(records),
            'verifiedFaces': sum(r['faceCount'] for r in records),
            'policyChangedFaces': sum(len(c['faces']) for c in changes),
            'bindingChangedFaces': int((before != arrays['material_indices']).sum()),
            'errors': len(errors)}}
    if stage_world:
        if errors:
            report['stageReady'] = False
        else:
            if navigation_root is None:
                raise ValueError('Staging requires native navigation for floor eligibility checks.')
            floor_proof = floor_eligibility_changes(arrays, before, materials,
                navigation_root / f'{name}_source_xyz.json')
            report['floorEligibility'] = floor_proof
            np.savez_compressed(output / 'geometry.npz', **arrays)
            with np.load(output / 'geometry.npz') as staged:
                unchanged = {}
                for key in raw.files:
                    if key == 'material_indices':
                        continue
                    original, candidate = raw[key], staged[key]
                    unchanged[key] = (original.dtype == candidate.dtype and
                        np.array_equal(original, candidate, equal_nan=True))
                if not all(unchanged.values()):
                    raise ValueError('Native repair changed immutable source arrays or dtypes.')
            report['unchangedArraysAndDtypes'] = unchanged
            metadata['materials'] = materials
            metadata['geometrySha256'] = digest(output / 'geometry.npz')
            metadata['nativeSlotRepair'] = {k: report[k] for k in
                ('baselineGeometrySha256', 'nativeSlotToolSha256', 'sourceUsdSha256', 'summary')}
            metadata['summary']['triangleMaterials'] = dict(Counter(materials[int(i)]['category']
                for i in arrays['material_indices']))
            (output / 'geometry.json').write_text(json.dumps(metadata))
            for filename in ('floor-refinement.json', 'floor-mesh.json'):
                floor = json.loads((world / filename).read_bytes())
                floor['geometrySha256'] = metadata['geometrySha256']
                floor['nativeMaterialFloorProof'] = floor_proof
                (output / filename).write_text(json.dumps(floor, separators=(',', ':')))
            report['candidateGeometrySha256'] = metadata['geometrySha256']
            report['floorRevalidationRequired'] = not floor_proof['floorValuesPreserved']
            report['stageReady'] = floor_proof['floorValuesPreserved']
    (output / 'native-slot-audit.json').write_text(json.dumps(report, indent=2))
    print(json.dumps({'map': name, **report['summary']}), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--world-root', type=Path, required=True)
    parser.add_argument('--verification-root', type=Path, required=True)
    parser.add_argument('--level-properties', type=Path, required=True)
    parser.add_argument('--mesh-properties', type=Path, required=True)
    parser.add_argument('--resolved-components', type=Path)
    parser.add_argument('--extra-mesh-properties', nargs='*', type=Path, default=[])
    parser.add_argument('--extra-level-properties', nargs='*', type=Path, default=[])
    parser.add_argument('--extra-resolved-components', nargs='*', type=Path, default=[])
    parser.add_argument('--reference-manifest', type=Path)
    parser.add_argument('--navigation-root', type=Path)
    parser.add_argument('--output-root', type=Path, required=True)
    parser.add_argument('--texture-properties', type=Path, required=True)
    parser.add_argument('--maps', nargs='*')
    parser.add_argument('--stage-worlds', action='store_true')
    args = parser.parse_args()
    names = args.maps or sorted(p.name for p in args.world_root.iterdir() if (p / 'geometry.json').exists())
    material_roots = [Path(m['folder']) / 'Exports' for m in
        json.loads(args.reference_manifest.read_bytes())['maps']] if args.reference_manifest else []
    for name in names:
        audit_map(name, args.world_root / name, args.verification_root / name,
            args.level_properties, args.mesh_properties, args.output_root / name,
            args.texture_properties, stage_world=args.stage_worlds,
            resolved_root=args.resolved_components, extra_mesh_roots=args.extra_mesh_properties,
            extra_level_roots=args.extra_level_properties,
            extra_resolved_roots=args.extra_resolved_components, material_roots=material_roots,
            navigation_root=args.navigation_root)


if __name__ == '__main__':
    main()
