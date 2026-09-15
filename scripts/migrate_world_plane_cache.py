"""Reuse an offline plane only when material repairs cannot change its section.

This migration requires identical positions, triangle order, UVs, projection,
and navigation. Changed floors invalidate planes whose observer domain differs.
A changed material invalidates every plane
intersecting any affected triangle, even when that triangle was hidden in the
old reduction. Removing a blocker can expose previously discarded boundaries.
The normal baker recomputes those invalidated planes from the complete world.
"""
import argparse
import ast
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import shutil

import numpy as np
import shapely

from world_geometry_bake import digest, floor_ranges_by_polygon
from world_visibility_materials import build_policy
from world_visibility_reduce import navigation_domain


def signature(policy):
    """Ignore confidence-only changes; preserve every alpha sampling input."""
    if policy['mode'] in ('solid', 'ignore'):
        return policy['mode']
    if policy.get('alphaTextureSha256'):
        # Different material aliases and source paths can name identical mask
        # bytes. These are precisely the inputs consumed by the frozen sampler.
        return json.dumps({
            'mode': policy['mode'], 'textureSha256': policy['alphaTextureSha256'],
            'threshold': policy['threshold'], 'wrapS': policy['wrapS'], 'wrapT': policy['wrapT'],
            'alphaScale': policy.get('alphaScale', 1.0), 'alphaBias': policy.get('alphaBias', 0.0),
            'textureAlphaRange': policy.get('textureAlphaRange'),
        }, sort_keys=True, allow_nan=False)
    return json.dumps(policy, sort_keys=True, allow_nan=False)


def changed_faces(old_ids, new_ids, old_policies, new_policies):
    labels = {}

    def codes(policies):
        result = []
        for policy in policies:
            key = signature(policy)
            if key not in labels:
                labels[key] = len(labels)
            result.append(labels[key])
        return np.asarray(result, dtype=np.int32)

    return codes(old_policies)[old_ids] != codes(new_policies)[new_ids]


def intersects_changed_height(triangles, elevation_cm):
    if not len(triangles):
        return False
    # Match NumPy's input-dtype scalar conversion in intersect_triangles,
    # including float32 planes that land exactly on a triangle's top edge.
    delta = triangles[:, :, 2] - elevation_cm / 100
    return bool(((delta.min(axis=1) <= 0) & (delta.max(axis=1) >= 0)).any())


def changed_height_intervals(triangles):
    if not len(triangles):
        return np.empty((0, 2))
    z = triangles[:, :, 2]
    intervals = sorted(zip(z.min(axis=1), z.max(axis=1)))
    merged = []
    for low, high in intervals:
        if merged and low <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], float(high))
        else:
            merged.append([float(low), float(high)])
    return np.asarray(merged)


def height_is_changed(intervals, dtype, elevation_cm):
    if not len(intervals):
        return False
    height = np.asarray(elevation_cm / 100, dtype=dtype).item()
    index = int(np.searchsorted(intervals[:, 0], height, side='right')) - 1
    return bool(index >= 0 and height <= intervals[index, 1])


def require_same_array(old, new, name):
    if old.dtype != new.dtype or not np.array_equal(old, new):
        raise ValueError(f'{name} changed; material-only cache migration is not valid.')


def require_same_sampling(old_helper, new_helper):
    def sampling_tree(path):
        tree = ast.parse(Path(path).read_text(encoding='utf-8'))
        tree.body = [node for node in tree.body
                     if not isinstance(node, ast.FunctionDef) or node.name != 'build_policy']
        return ast.dump(tree, include_attributes=False)

    if sampling_tree(old_helper) != sampling_tree(new_helper):
        raise ValueError('Material sampling code changed; cached sections need a full rebake.')


def observer_domains(nav, refinement, floor_mesh, elevations, scale, eye):
    """Reconstruct the frozen baker's exact domains and manual-height choices."""
    common = Counter(int(round(z)) for z in refinement['refinedFloorHeightsCm'])
    menu = [z + eye for z, count in common.items()
            if count >= max(8, len(refinement['refinedFloorHeightsCm']) * .02)]
    menu = menu or [common.most_common(1)[0][0] + eye]
    global_elevations = {min(elevations, key=lambda value: abs(value - target)) for target in menu}
    domain_all = navigation_domain(nav, scale)
    minimum, maximum = floor_ranges_by_polygon(nav, refinement, floor_mesh)
    walkable = np.asarray(nav.get('walkable', [True] * len(nav['polygons'])))
    xy = np.asarray(nav['vertices']).reshape(-1, 3)[:, :2] * (scale / nav['coordinateScale'])
    polygons = np.array([shapely.Polygon(xy[p]) for p in nav['polygons']], dtype=object)
    result = {}
    for index, elevation in enumerate(elevations):
        global_origins = elevation in global_elevations
        if global_origins:
            domain = domain_all
        else:
            low = (elevations[index - 1] + elevation) / 2 - eye if index else -np.inf
            high = (elevations[index + 1] + elevation) / 2 - eye if index + 1 < len(elevations) else np.inf
            allowed = walkable & (minimum <= high + .001) & (maximum >= low - .001)
            if not allowed.any():
                continue
            domain = shapely.union_all(polygons[allowed])
        result[elevation] = (global_origins, domain.wkb)
    return result


def migrate(base_path, old_folder, new_folder, navigation_path, elevations_path,
            output_path, texture_properties_root=None, *, dry_run=False, original_material_helper=None):
    base_path, old_folder, new_folder = map(Path, (base_path, old_folder, new_folder))
    output_path = Path(output_path)
    base = json.loads(base_path.read_bytes())
    audit_path = base_path.with_suffix('.audit.json')
    audit = json.loads(audit_path.read_bytes())
    old_meta = json.loads((old_folder / 'geometry.json').read_bytes())
    new_meta = json.loads((new_folder / 'geometry.json').read_bytes())
    if base.get('format') != 'plane-cache-v1' or base.get('maxDistanceMeters') is not None:
        raise ValueError('Migration requires full-range plane-cache-v1 data.')
    if len({base['map'], audit['map'], old_meta['map'], new_meta['map']}) != 1:
        raise ValueError('Map identities do not match.')
    if audit['alphaSamplingFailures']:
        raise ValueError('The original bake has unresolved alpha sampling failures.')
    for folder, metadata in ((old_folder, old_meta), (new_folder, new_meta)):
        if metadata['geometrySha256'] != digest(folder / 'geometry.npz'):
            raise ValueError('Geometry fingerprint mismatch.')
    if base['source']['geometrySha256'] != old_meta['geometrySha256']:
        raise ValueError('The plane manifest does not belong to the original world.')
    if old_meta['uiTransform'] != new_meta['uiTransform']:
        raise ValueError('Map projection changed.')
    nav = json.loads(Path(navigation_path).read_bytes())
    nav_hash = digest(navigation_path)
    if base['source']['navigationSha256'] != nav_hash:
        raise ValueError('Navigation changed.')
    refinements = [json.loads((folder / 'floor-refinement.json').read_bytes())
                   for folder in (old_folder, new_folder)]
    floors = [json.loads((folder / 'floor-mesh.json').read_bytes())
              for folder in (old_folder, new_folder)]
    if any(row['navigationSha256'] != nav_hash for row in refinements + floors):
        raise ValueError('Floor navigation fingerprint mismatch.')
    for floor, metadata in zip(floors, (old_meta, new_meta)):
        if floor['geometrySha256'] != metadata['geometrySha256']:
            raise ValueError('Floor geometry fingerprint mismatch.')
    floors_changed = (refinements[0]['refinedFloorHeightsCm'] != refinements[1]['refinedFloorHeightsCm'] or
                      floors[0]['floorMesh'] != floors[1]['floorMesh'])
    with np.load(old_folder / 'geometry.npz') as old, np.load(new_folder / 'geometry.npz') as new:
        for field in ('points', 'faces', 'uvs'):
            require_same_array(old[field], new[field], field)
        policies = [build_policy(material, texture_properties_root=texture_properties_root)
                    for material in new_meta['materials']]
        bad_reasons = {'source-hash-mismatch', 'source-blend-mode-disagrees-with-audit'}
        if any(policy['reason'] in bad_reasons for policy in policies):
            raise ValueError('Repaired source materials do not match their recorded evidence.')
        changed = changed_faces(old['material_indices'], new['material_indices'], audit['policies'], policies)
        changed_triangles = new['points'][new['faces'][changed]]
    height_intervals = changed_height_intervals(changed_triangles)
    elevations = sorted(set(json.loads(Path(elevations_path).read_bytes())))
    if not elevations or len(elevations) == 1:
        raise ValueError('Pass the full original standing elevation list, not a probe subset.')
    retained = {layer['elevationCm']: layer for layer in base['layers']}
    if not set(retained).issubset(elevations):
        raise ValueError('Original plane heights are absent from the requested elevation list.')
    scale, eye = base['coordinateScale'], base['observerHeightCm']
    if scale != 1048576:
        raise ValueError('Unsupported baker coordinate scale.')
    # This mirrors the frozen baker cache key. Cache reuse is also checked by
    # an end-to-end regression against its actual output file names.
    scripts = Path(__file__).parent
    material_helper = scripts / 'world_visibility_materials.py'
    original_material_helper = Path(original_material_helper) if original_material_helper else material_helper
    require_same_sampling(original_material_helper, material_helper)
    cache_inputs = {
        'geometry': new_meta['geometrySha256'], 'navigation': nav_hash,
        'policies': policies, 'scale': scale, 'ui': new_meta['uiTransform'],
        'baker': digest(scripts / 'world_geometry_bake.py'),
        'materials': digest(material_helper),
        'reduction': digest(scripts / 'world_visibility_reduce.py'),
        'maxDistanceMeters': None, 'floorMesh': digest(new_folder / 'floor-mesh.json'),
    }
    fingerprint = hashlib.sha256(json.dumps(cache_inputs, sort_keys=True).encode()).hexdigest()
    original_inputs = {**cache_inputs, 'geometry': old_meta['geometrySha256'],
                       'policies': audit['policies'], 'materials': digest(original_material_helper),
                       'floorMesh': digest(old_folder / 'floor-mesh.json')}
    original_fingerprint = hashlib.sha256(json.dumps(original_inputs, sort_keys=True).encode()).hexdigest()
    old_domains, new_domains = [observer_domains(nav, refinement, floor['floorMesh'], elevations, scale, eye)
                                for refinement, floor in zip(refinements, floors)]
    if set(retained) != set(old_domains) or any(
            layer['globalOrigins'] != old_domains[elevation][0] for elevation, layer in retained.items()):
        raise ValueError('Original plane domains do not match the original standing floors.')
    cache_folder = new_folder / 'visibility-cache'
    if not dry_run:
        cache_folder.mkdir(parents=True, exist_ok=True)
    rows = []
    for elevation in elevations:
        layer = retained.get(elevation)
        if layer is None:
            continue
        old_domain = old_domains[elevation][1]
        old_domain_hash = hashlib.sha256(old_domain).hexdigest()[:12]
        new_domain = new_domains.get(elevation, (False, None))[1]
        new_domain_hash = hashlib.sha256(new_domain).hexdigest()[:12] if new_domain is not None else None
        source = Path(layer['cacheFile'])
        if source.name != f'{elevation:.6f}-{original_fingerprint[:16]}-{old_domain_hash}.json.gz':
            raise ValueError('Original cache fingerprint does not match the unchanged baker and observer domain.')
        raw = source.read_bytes()
        cache = json.loads(gzip.decompress(raw))
        if cache['alphaFailures'] or cache['statistics']['elevationCm'] != elevation:
            raise ValueError('Original cache has a wrong elevation or unresolved alpha failures.')
        material_changed = height_is_changed(height_intervals, changed_triangles.dtype, elevation)
        domain_changed = old_domain != new_domain
        invalidated = material_changed or domain_changed
        target = cache_folder / f'{elevation:.6f}-{fingerprint[:16]}-{new_domain_hash}.json.gz'
        row = {'elevationCm': elevation, 'reuse': not invalidated,
               'materialSectionChanged': material_changed, 'observerDomainChanged': domain_changed,
               'originalDomainSha256': hashlib.sha256(old_domain).hexdigest(),
               'targetDomainSha256': hashlib.sha256(new_domain).hexdigest() if new_domain is not None else None,
               'originalCacheSha256': hashlib.sha256(raw).hexdigest(), 'target': str(target.resolve())}
        rows.append(row)
        if not invalidated and not dry_run:
            if target.exists() and target.read_bytes() != raw:
                raise ValueError('The target cache already contains different bytes.')
            if source.resolve() != target.resolve():
                pending = target.with_suffix('.writing')
                shutil.copyfile(source, pending)
                pending.replace(target)
    result = {'map': base['map'], 'dryRun': dry_run, 'changedFaces': int(changed.sum()),
              'standingFloorsChanged': floors_changed,
              'newlyEligibleElevationsCm': sorted(set(new_domains) - set(old_domains)),
              'noLongerEligibleElevationsCm': sorted(set(old_domains) - set(new_domains)),
              'reusedPlanes': sum(row['reuse'] for row in rows),
              'recomputedPlanes': sum(not row['reuse'] for row in rows),
              'originalManifestSha256': digest(base_path), 'originalAuditSha256': digest(audit_path),
              'originalGeometrySha256': old_meta['geometrySha256'],
              'repairedGeometrySha256': new_meta['geometrySha256'], 'targetCacheFingerprint': fingerprint,
              'originalCacheFingerprint': original_fingerprint,
              'migrationSha256': digest(__file__), 'layers': rows}
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps({key: value for key, value in result.items() if key != 'layers'}), flush=True)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('base', 'old_world', 'new_world', 'navigation', 'elevations', 'output'):
        parser.add_argument(name, type=Path)
    parser.add_argument('--texture-properties-root', type=Path)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--original-material-helper', type=Path,
                        help='Archived helper used by the original bake, required if build_policy changed.')
    args = parser.parse_args()
    migrate(args.base, args.old_world, args.new_world, args.navigation, args.elevations,
            args.output, args.texture_properties_root, dry_run=args.dry_run,
            original_material_helper=args.original_material_helper)
