"""Repack the sealed SVG/foliage scope without an absolute-height exclusion.

The frozen packer still validates source hashes, material policy and alpha bytes.
Only its height-domain callback changes. Original standing observer limits stay
in the proof for the subsequent floor-relative bake. Outputs are audit inputs,
never installed app assets.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import numpy as np


def build(root, name):
    compact = root / 'compact-prototype'
    sys.path.insert(0, str(compact))
    spec = importlib.util.spec_from_file_location(
        'frozen_height_packer', compact / 'pack_height_triangles_v2.py')
    packer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packer)
    rows = json.loads((root / 'completeness/combined-manifest-release-inputs-v2.json').read_bytes())
    row = next(row for row in rows if row['map'] == name)
    world, reference = Path(row['combinedWorldFolder']), Path(row['referenceFile'])
    planes = Path(row.get('composedPlaneManifest', str(root / f'candidate-world-final/evidence/{name}.planes.json')))
    scope_path = compact / f'all-map-svg-foliage-v2/{name}/scope.json'
    output = root / f'tactical-visibility-revision/full-height-input-v1/{name}'
    if output.exists():
        raise ValueError(f'Preserving existing output: {output}')
    original_domain = packer.domain_proof
    def full_domain(world, metadata, manifest, policies):
        domain, proof = original_domain(world, metadata, manifest, policies)
        # This covers every source Z, including geometry that was outside the
        # old observer-height range. Material/receiver/foliage scope still applies.
        with np.load(Path(world) / 'geometry.npz', allow_pickle=False) as archive:
            points, _, _, _ = packer.validate_vectors(archive, metadata, policies['policies'])
        full = [float(points[:, 2].min()) - .001, float(points[:, 2].max()) + .001]
        proof.update(originalObserverHeightDomainMeters=domain,
                     format='icarus-full-height-tactical-input-v1',
                     sourceZDomainMeters=full,
                     absoluteHeightFacesExcluded=0)
        return full, proof
    packer.domain_proof = full_domain
    report = packer.pack(world, reference, planes, output, scope_path)
    scope = json.loads(scope_path.read_bytes())
    metadata = json.loads((world / 'geometry.json').read_bytes())
    policies = json.loads(reference.with_suffix('.policies.json').read_bytes())['policies']
    with np.load(world / 'geometry.npz', allow_pickle=False) as archive:
        points, faces, uvs, materials = packer.validate_vectors(archive, metadata, policies)
    with np.load(scope['retainedFacesFile'], allow_pickle=False) as archive:
        scoped = archive['sourceFaceIds']
    modes = np.array([policy['mode'] for policy in policies])
    expected = scoped[modes[materials[scoped]] != 'ignore']
    with np.load(output / 'source-correspondence.npz', allow_pickle=False) as archive:
        actual = archive['sourceFaces']
    np.testing.assert_array_equal(np.sort(actual), expected)
    old_path = compact / f'all-map-height-scoped-v2/{name}/source-correspondence.npz'
    with np.load(old_path, allow_pickle=False) as archive:
        old = archive['sourceFaces']
    missing = np.setdiff1d(expected, old)
    lost = np.setdiff1d(old, actual)
    if len(lost):
        raise ValueError('Full-height input lost previously retained source faces')
    np.savez_compressed(output / 'reintroduced-source-faces.npz', sourceFaceIds=missing)
    proof = dict(map=name, status='complete-scoped-source-set',
                 retainedFaces=len(actual), originalRetainedFaces=len(old),
                 reintroducedFaces=len(missing), lostOriginalFaces=len(lost),
                 geometrySha256=row['geometrySha256'],
                 packSha256=report['dataSha256'],
                 originalObserverHeightDomainMeters=report['heightDomainProof']['originalObserverHeightDomainMeters'],
                 scopeSha256=packer.digest(scope_path),
                 builderSha256=packer.digest(__file__),
                 claim='Every non-ignored scoped source face retained; no absolute-height exclusion. Tactical transformed ray behavior still requires validation.')
    (output / 'full-source-coverage.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(proof), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--maps', nargs='+', default=['split'])
    args = parser.parse_args()
    for name in args.maps:
        build(args.root, name)
