"""Bind completed plane caches to their checked sources and audit.

This is an explicit, after-the-fact validation of completed output. It does not
claim that hashes were recorded during the original bake, or certify gameplay.
Changing a source, policy helper, audit, navigation file or cache invalidates the
seal. Keep old policy-version outputs separate instead of resealing them.
"""
import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
import math
from pathlib import Path

from world_visibility_materials import build_policy


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read_json(path):
    data = Path(path).read_bytes()
    return json.loads(gzip.decompress(data) if data[:2] == b'\x1f\x8b' else data)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def policy_dependencies(policies):
    dependencies = {}
    for policy in policies:
        if policy.get('reason') in ('source-hash-mismatch', 'source-blend-mode-disagrees-with-audit'):
            raise ValueError('A material source disagrees with its approved audit.')
        for name, hash_name in [('source', 'sourceSha256'), ('usdSource', 'usdSha256'),
                                ('textureProperties', 'texturePropertiesSha256'),
                                ('alphaTexture', 'alphaTextureSha256')]:
            if hash_name not in policy:
                continue
            path = str(Path(policy[name]).resolve())
            expected = policy[hash_name]
            if path in dependencies and dependencies[path] != expected:
                raise ValueError(f'Conflicting material dependency hashes: {path}')
            dependencies[path] = expected
    for path, expected in dependencies.items():
        if digest(path) != expected:
            raise ValueError(f'Material dependency fingerprint mismatch: {path}')
    return dependencies


def checked_policies(materials, approved, texture_properties_root=None):
    current = [build_policy(record, texture_properties_root=texture_properties_root) for record in materials]
    dependencies = policy_dependencies(current)
    if canonical(current) != canonical(approved):
        raise ValueError('Current material policies differ from the policies approved for this output.')
    return current, dependencies


def seal_path(manifest):
    return Path(manifest).with_suffix('.seal.json')


def seal_plane_manifest(manifest, world_folder, texture_properties_root=None, *, evidence_paths=()):
    manifest, world_folder = Path(manifest).resolve(), Path(world_folder).resolve()
    target = seal_path(manifest)
    if target.exists():
        raise ValueError('A seal already exists; verify it instead of silently replacing evidence.')
    data, metadata = read_json(manifest), read_json(world_folder / 'geometry.json')
    audit_path = manifest.with_suffix('.audit.json')
    audit = read_json(audit_path)
    source = data.get('source', {})
    if data.get('format') != 'plane-cache-v1' or data.get('map') != metadata.get('map') or audit.get('map') != data.get('map'):
        raise ValueError('Completed plane manifest, world and audit maps must match.')
    if source.get('geometrySha256') != metadata.get('geometrySha256') or digest(world_folder / 'geometry.npz') != source.get('geometrySha256'):
        raise ValueError('World geometry fingerprint does not match the completed bake.')
    if not source.get('referenceSha256') or source['referenceSha256'] != metadata.get('referenceSha256'):
        raise ValueError('World reference fingerprint does not match the completed bake.')
    audit_reference = audit.get('referenceSha256', audit.get('source', {}).get('referenceSha256'))
    if audit_reference != source['referenceSha256']:
        raise ValueError('Audit reference fingerprint does not match the completed bake.')
    if 'source' in audit and audit['source'] != source:
        raise ValueError('Audit source lineage differs from the plane manifest.')
    if audit.get('alphaSamplingFailures') != {}:
        raise ValueError('The completed audit must explicitly contain zero alpha sampling failures.')
    policies, dependencies = checked_policies(metadata['materials'], audit['policies'], texture_properties_root)
    ui = metadata['uiTransform']
    expected_units = [abs(ui['XMultiplier']) * 100, abs(ui['YMultiplier']) * 100]
    if len(data.get('uvUnitsPerMeter', [])) != 2 or any(
            not math.isclose(a, b, rel_tol=1e-12, abs_tol=1e-15) for a, b in zip(data['uvUnitsPerMeter'], expected_units)):
        raise ValueError('Visibility metric differs from the world projection.')
    navigation_path = manifest.with_name(data['map'] + '_navigation.json.gz')
    navigation = read_json(navigation_path)
    floor = read_json(world_folder / 'floor-mesh.json')
    refinement = read_json(world_folder / 'floor-refinement.json')
    for document in (navigation, floor, refinement):
        if document.get('map') != data['map']:
            raise ValueError('Navigation or floor map mismatch.')
    for document in (floor, refinement):
        if document.get('navigationSha256') != source.get('navigationSha256') or not source.get('navigationSha256'):
            raise ValueError('Floor and navigation lineage differ.')
    if canonical(navigation.get('floorMesh')) != canonical(floor['floorMesh']) or canonical(
            navigation.get('refinedFloorHeightsCm')) != canonical(refinement['refinedFloorHeightsCm']):
        raise ValueError('Bundled navigation differs from the checked observer floor.')
    for key in ('observerHeightCm', 'defaultFloorElevationCm'):
        if navigation.get(key) != data.get(key) or not isinstance(data.get(key), (int, float)) or not math.isfinite(data[key]):
            raise ValueError('Navigation and visibility standing height metadata differ.')
    layers = data.get('layers', [])
    rows = audit.get('layers', [])
    if not layers or len(layers) != len(rows) or audit.get('summary', {}).get('layers') != len(layers):
        raise ValueError('Audit must cover every completed plane exactly once.')
    if any(type(layer.get('globalOrigins')) is not bool for layer in layers) or not any(layer['globalOrigins'] for layer in layers):
        raise ValueError('Each completed plane needs an explicit observer domain and the map needs a global plane.')
    global_elevations = [layer['elevationCm'] for layer in layers if layer['globalOrigins']]
    if data.get('menuElevationsCm') != global_elevations:
        raise ValueError('Manual elevations must match the completed global observer planes.')
    files = dict(dependencies)
    for record in navigation.get('source', {}).get('files', []):
        path = str(Path(record['path']).resolve())
        if digest(path) != record['sha256']:
            raise ValueError('Native navigation source fingerprint mismatch.')
        files[path] = record['sha256']
    for path in (manifest, audit_path, navigation_path, world_folder / 'geometry.json',
                 world_folder / 'geometry.npz', world_folder / 'floor-mesh.json',
                 world_folder / 'floor-refinement.json', Path(__file__).with_name('world_visibility_materials.py'), *evidence_paths):
        path = Path(path)
        files[str(path.resolve())] = digest(path)
    sealed_layers = []
    previous = -math.inf
    for layer, row in zip(layers, rows):
        elevation = layer['elevationCm']
        if not isinstance(elevation, (float, int)) or not math.isfinite(elevation) or elevation <= previous:
            raise ValueError('Completed elevations must be finite and strictly increasing.')
        previous = elevation
        path = Path(layer['cacheFile']).resolve()
        cache = read_json(path)
        statistics = cache.get('statistics', {})
        count = len(cache['segments'])
        if row.get('elevationCm') != elevation or statistics.get('elevationCm') != elevation:
            raise ValueError('Cache or audit elevation differs from its selected plane.')
        if cache.get('alphaFailures') != {}:
            raise ValueError('A plane cache contains unresolved alpha sampling failures.')
        if row.get('finalSegments', row.get('segments')) != count or statistics.get('finalSegments', statistics.get('segments')) != count:
            raise ValueError('Cache segment count differs from the completed audit.')
        for segment in cache['segments']:
            if len(segment) != 2 or any(len(point) != 2 or any(type(value) is not int or not -(2**31) <= value < 2**31 for value in point) for point in segment):
                raise ValueError('Plane cache has non-int32 endpoint coordinates.')
        files[str(path)] = digest(path)
        sealed_layers.append({'elevationCm': elevation, 'cacheFile': str(path), 'sha256': files[str(path)], 'segments': count})
    result = {'schemaVersion': 1, 'kind': 'completed-world-plane-seal',
              'attestation': 'after-the-fact-completed-output-validation', 'gameplayCertified': False,
              'createdUtc': datetime.now(timezone.utc).isoformat(), 'map': data['map'],
              'manifest': str(manifest), 'worldFolder': str(world_folder), 'source': source,
              'texturePropertiesRoot': str(Path(texture_properties_root).resolve()) if texture_properties_root else None,
              'policySha256': hashlib.sha256(canonical(policies).encode()).hexdigest(),
              'files': files, 'layers': sealed_layers}
    pending = target.with_suffix('.writing')
    pending.write_text(json.dumps(result, indent=2, allow_nan=False), encoding='utf-8')
    pending.replace(target)
    return result


def verify_plane_seal(manifest, *, world_folder=None):
    manifest = Path(manifest).resolve()
    seal = read_json(seal_path(manifest))
    data = read_json(manifest)
    if seal.get('schemaVersion') != 1 or seal.get('kind') != 'completed-world-plane-seal':
        raise ValueError('Unsupported completed plane seal.')
    if seal.get('manifest') != str(manifest) or seal.get('map') != data.get('map') or seal.get('source') != data.get('source'):
        raise ValueError('Seal refers to a different plane manifest or source.')
    if world_folder is not None and str(Path(world_folder).resolve()) != seal.get('worldFolder'):
        raise ValueError('Seal refers to a different source world folder.')
    files = seal.get('files', {})
    required = [manifest, manifest.with_suffix('.audit.json'), manifest.with_name(data['map'] + '_navigation.json.gz'),
                Path(seal['worldFolder']) / 'geometry.json', Path(seal['worldFolder']) / 'geometry.npz',
                Path(seal['worldFolder']) / 'floor-mesh.json', Path(seal['worldFolder']) / 'floor-refinement.json',
                Path(__file__).with_name('world_visibility_materials.py')]
    required += [Path(layer['cacheFile']) for layer in data['layers']]
    if any(str(path.resolve()) not in files for path in required):
        raise ValueError('Seal is missing a required source or cache fingerprint.')
    for path, expected in files.items():
        if digest(path) != expected:
            raise ValueError(f'Sealed input changed: {path}')
    # Newly exported metadata can resolve a formerly unknown material without
    # changing an existing dependency file. Rebuild to detect that case too.
    checked_policies(read_json(Path(seal['worldFolder']) / 'geometry.json')['materials'],
                     read_json(manifest.with_suffix('.audit.json'))['policies'], seal.get('texturePropertiesRoot'))
    return seal


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('world_folder', type=Path)
    parser.add_argument('--texture-properties-root')
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    result = verify_plane_seal(args.manifest, world_folder=args.world_folder) if args.verify else seal_plane_manifest(
        args.manifest, args.world_folder, args.texture_properties_root)
    print(json.dumps({'map': result['map'], 'layers': len(result['layers']), 'seal': str(seal_path(args.manifest))}))
