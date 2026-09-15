"""Add verified permanent scenery to existing Art visibility plane caches.

Adding opaque boundaries cannot expose an Art edge previously hidden behind
another retained Art boundary. The expensive original reduction stays valid.
This pass sections the extra scenery and planarizes its union with each cached
plane. Fixed-grid noding can shift an existing edge at a newly snapped crossing;
it is not lossless edge preservation or a universal ray-distance bound. Final
independent source-ray checks remain required. Observer floors and walking
connectivity are unchanged.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import time

import numpy as np

from world_geometry_bake import digest, intersect_triangles, planarize_segments
from world_visibility_materials import clip_alpha_segment
from seal_world_plane_manifest import checked_policies, seal_path, seal_plane_manifest, verify_plane_seal


def validate_combined_world(base_folder, supplement_folder, combined_folder, base, metadata, combined):
    """Check the frozen composition itself, including unchanged observer floors."""
    base_metadata = json.loads((base_folder / 'geometry.json').read_bytes())
    provenance = combined.get('supplementation', {})
    if provenance.get('supplementMetadataSha256') != digest(supplement_folder / 'geometry.json'):
        raise ValueError('Combined world does not bind the approved supplement metadata.')
    if combined.get('uiTransform') != base_metadata.get('uiTransform'):
        raise ValueError('Combined world projection differs from the sealed base.')
    if combined.get('materials') != base_metadata['materials'] + metadata['materials']:
        raise ValueError('Combined material table is not the exact approved append.')
    for name in ('floor-refinement.json', 'floor-mesh.json'):
        expected = provenance.get('floorFilesPreservedSha256', {}).get(name)
        if not expected or digest(base_folder / name) != expected or digest(combined_folder / name) != expected:
            raise ValueError('Combined observer floor differs from the sealed base.')
    with np.load(base_folder / 'geometry.npz') as original, np.load(supplement_folder / 'geometry.npz') as extra, np.load(combined_folder / 'geometry.npz') as joined:
        fields = {'points', 'faces', 'material_indices', 'uvs'}
        if set(original.files) != fields or set(extra.files) != fields or set(joined.files) != fields:
            raise ValueError('Unsupported geometry arrays in the approved composition.')
        point_count = len(original['points'])
        for name in sorted(fields):
            before, addition, actual = original[name], extra[name], joined[name]
            offset = point_count if name == 'faces' else len(base_metadata['materials']) if name == 'material_indices' else 0
            # Float32 Art and float64 USD instances concatenate to float64.
            # Require exact values on both sides, without downcasting the extras.
            if (actual.dtype != np.result_type(before.dtype, addition.dtype)
                    or actual.shape != (len(before) + len(addition), *before.shape[1:])
                    or not np.array_equal(actual[:len(before)], before, equal_nan=True)
                    or not np.array_equal(actual[len(before):], addition + offset if offset else addition, equal_nan=True)):
                raise ValueError(f'Combined {name} are not the exact approved geometry append.')
            del before, addition, actual


def join_segments(base, additions, ui, scale):
    """Node the combined linework on the same fixed-precision UV grid."""
    base = np.asarray(base).reshape(-1, 2, 2)
    additions = np.asarray(additions).reshape(-1, 2, 2)
    if not len(additions):
        return [(tuple(a), tuple(b)) for a, b in base]
    world = np.empty_like(base, dtype=float)
    world[:, :, 0] = (base[:, :, 1] / scale - ui['YScalarToAdd']) / (100 * ui['YMultiplier'])
    world[:, :, 1] = -(base[:, :, 0] / scale - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])
    return planarize_segments(np.concatenate([world, additions]), ui, scale)


def supplement(base_path, supplement_folder, combined_folder, output_path, texture_properties_root=None,
               evidence_paths=()):
    started = time.perf_counter()
    base_path, output_path = Path(base_path), Path(output_path)
    if output_path.exists() or seal_path(output_path).exists():
        raise ValueError('Use a fresh output manifest; completed composition evidence is not overwritten.')
    supplement_folder, combined_folder = Path(supplement_folder), Path(combined_folder)
    base = json.loads(base_path.read_bytes())
    sealed_base = verify_plane_seal(base_path)
    base_folder = Path(sealed_base['worldFolder'])
    metadata = json.loads((supplement_folder / 'geometry.json').read_bytes())
    combined = json.loads((combined_folder / 'geometry.json').read_bytes())
    if base.get('format') != 'plane-cache-v1':
        raise ValueError('The base must be a completed plane cache manifest.')
    if metadata.get('status') != 'approved-static-scenery-supplement' or metadata.get('issues'):
        raise ValueError('Scenery classification must be completed before supplementing a map.')
    if base['map'] != metadata['map'] or base['map'] != combined['map']:
        raise ValueError('Source maps do not match.')
    if combined.get('baseGeometrySha256') != base['source']['geometrySha256']:
        raise ValueError('The combined world uses a different Art baseline.')
    if combined.get('supplementGeometrySha256') != metadata['geometrySha256']:
        raise ValueError('The combined world uses a different scenery supplement.')
    if metadata['geometrySha256'] != digest(supplement_folder / 'geometry.npz'):
        raise ValueError('Supplement geometry fingerprint mismatch.')
    if combined['geometrySha256'] != digest(combined_folder / 'geometry.npz'):
        raise ValueError('Combined reference fingerprint mismatch.')
    validate_combined_world(base_folder, supplement_folder, combined_folder, base, metadata, combined)
    approved_path = supplement_folder / 'material-policies.json'
    policies, _ = checked_policies(metadata['materials'], json.loads(approved_path.read_bytes()), texture_properties_root)
    source = np.load(supplement_folder / 'geometry.npz')
    triangles = source['points'][source['faces']]
    materials = source['material_indices']
    texture_uvs = source['uvs']
    evidence_paths = tuple(Path(path).resolve() for path in evidence_paths)
    evidence_hashes = {str(path): digest(path) for path in evidence_paths}
    if len(evidence_hashes) != len(evidence_paths):
        raise ValueError('Duplicate composition evidence.')
    ui, scale = combined['uiTransform'], base['coordinateScale']
    fingerprint = hashlib.sha256(json.dumps({
        'baseManifest': digest(base_path), 'baseSeal': digest(seal_path(base_path)),
        'supplement': digest(supplement_folder / 'geometry.npz'),
        'supplementMetadata': digest(supplement_folder / 'geometry.json'),
        'approvedPolicies': digest(approved_path), 'combinedMetadata': digest(combined_folder / 'geometry.json'),
        'policies': policies, 'script': digest(__file__),
        'baker': digest(Path(__file__).with_name('world_geometry_bake.py')),
        'materialHelper': digest(Path(__file__).with_name('world_visibility_materials.py')),
        'additionalCompositionEvidence': evidence_hashes,
    }, sort_keys=True).encode()).hexdigest()
    cache_folder = output_path.parent / (base['map'] + '-supplement-cache')
    cache_folder.mkdir(parents=True, exist_ok=True)
    result = {**base, 'layers': [], 'source': {**base['source'],
        'baseGeometrySha256': base['source']['geometrySha256'],
        'supplementGeometrySha256': metadata['geometrySha256'],
        'geometrySha256': combined['geometrySha256'], 'supplementBakeSha256': fingerprint,
        'basePlaneSealSha256': digest(seal_path(base_path)),
        'supplementMetadataSha256': digest(supplement_folder / 'geometry.json'),
        'supplementPoliciesSha256': digest(approved_path)}}
    statistics = []
    for layer in base['layers']:
        cache = json.loads(gzip.decompress(Path(layer['cacheFile']).read_bytes()))
        segments, faces, uvs = intersect_triangles(triangles, layer['elevationCm'] / 100, texture_uvs)
        parts = []
        for index, face in enumerate(faces):
            policy = policies[int(materials[face])]
            if policy['mode'] == 'ignore':
                continue
            intervals = clip_alpha_segment(policy, *uvs[index]) if policy['mode'] == 'alpha-test' else [(0, 1)]
            a, b = segments[index]
            parts.extend([[a + (b - a) * low, a + (b - a) * high]
                          for low, high in intervals if high > low])
        row = {'elevationCm': layer['elevationCm'], 'baseSegments': len(cache['segments']),
               'additionalSegments': len(parts)}
        if parts:
            joined = join_segments(cache['segments'], parts, ui, scale)
            row['finalSegments'] = len(joined)
            cache_path = cache_folder / f'{layer["elevationCm"]:.6f}-{fingerprint[:16]}.json.gz'
            payload = {'segments': joined, 'statistics': row, 'alphaFailures': {}}
            pending = cache_path.with_suffix('.writing')
            pending.write_bytes(gzip.compress(json.dumps(payload, separators=(',', ':')).encode(), compresslevel=3, mtime=0))
            pending.replace(cache_path)
            result['layers'].append({**layer, 'cacheFile': str(cache_path.resolve())})
        else:
            row['finalSegments'] = len(cache['segments'])
            result['layers'].append(layer)
        statistics.append(row)
    navigation = base_path.with_name(base['map'] + '_navigation.json.gz')
    shutil.copyfile(navigation, output_path.with_name(navigation.name))
    pending = output_path.with_suffix('.writing')
    pending.write_text(json.dumps(result, separators=(',', ':')), encoding='utf-8')
    pending.replace(output_path)
    audit = {'map': base['map'], 'status': 'additive-permanent-scenery-bake', 'gameplayCertified': False,
             'intersectionPolicy': 'Fixed-grid union; near-grazing distance errors are not bounded by the coordinate grid.',
             'coordinateUnitMeters': [1 / (scale * value) for value in base['uvUnitsPerMeter']],
             'source': result['source'], 'layers': statistics, 'alphaSamplingFailures': {},
             'policies': json.loads(base_path.with_suffix('.audit.json').read_bytes())['policies'] + policies,
             'summary': {
                 'layers': len(statistics), 'supplementedLayers': sum(row['additionalSegments'] > 0 for row in statistics),
                 'seconds': time.perf_counter() - started}}
    output_path.with_suffix('.audit.json').write_text(json.dumps(audit, indent=2), encoding='utf-8')
    verify_plane_seal(base_path)
    if any(digest(path) != evidence_hashes[str(path)] for path in evidence_paths):
        raise ValueError('Composition evidence changed during the bake.')
    seal_plane_manifest(output_path, combined_folder, texture_properties_root, evidence_paths=(
        seal_path(base_path), supplement_folder / 'geometry.json', approved_path,
        supplement_folder / 'geometry.npz', *evidence_paths))
    print(json.dumps({'map': base['map'], **audit['summary']}), flush=True)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base', type=Path)
    parser.add_argument('supplement', type=Path)
    parser.add_argument('combined', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--texture-properties-root')
    parser.add_argument('--evidence', type=Path, action='append', default=[])
    args = parser.parse_args()
    supplement(args.base, args.supplement, args.combined, args.output, args.texture_properties_root, args.evidence)
