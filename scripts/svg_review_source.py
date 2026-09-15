"""Resolve the declared source revision instead of guessing a versioned folder."""
from functools import lru_cache
import hashlib
import json
from pathlib import Path

import numpy as np

from audit_svg_source_height_associations import ROOT


@lru_cache(maxsize=13)
def source_world(name):
    manifest = ROOT / 'completeness/combined-manifest-release-inputs-v2.json'
    rows = json.loads(manifest.read_text())
    matches = [row for row in rows if row['map'] == name]
    if len(matches) != 1:
        raise ValueError(('Missing or duplicate source revision', name))
    row = matches[0]
    folder = Path(row['combinedWorldFolder'])
    actual = hashlib.sha256((folder / 'geometry.npz').read_bytes()).hexdigest()
    if actual != row['geometrySha256']:
        raise ValueError(('Source geometry changed after its manifest', name))
    return folder


def source_world_for_hashes(name, geometry_sha256, metadata_sha256):
    """Match the frozen wall review to its exact geometry and metadata revision."""
    for folder in [source_world(name), ROOT/f'supplemented-v2/world/{name}']:
        metadata = folder/'geometry.json'
        if not metadata.exists() or hashlib.sha256(metadata.read_bytes()).hexdigest() != metadata_sha256:
            continue
        if hashlib.sha256((folder/'geometry.npz').read_bytes()).hexdigest() == geometry_sha256:
            return folder
    raise ValueError((name, 'No declared source revision matches the review fingerprints'))


def verified_source_pack(name, reference=None):
    """Check every packed triangle against the declared source revision."""
    from audit_tactical_target_rays import ReferenceModel
    folder = ROOT / f'tactical-visibility-revision/full-height-input-v1/{name}'
    pack = folder / f'{name}.height.bin.gz'
    proof = json.loads((folder / 'full-source-coverage.json').read_text())
    source = source_world(name) / 'geometry.npz'
    if proof['geometrySha256'] != hashlib.sha256(source.read_bytes()).hexdigest():
        raise ValueError((name, 'Source pack uses a different geometry revision'))
    if proof['packSha256'] != hashlib.sha256(pack.read_bytes()).hexdigest():
        raise ValueError((name, 'Source pack changed after coverage verification'))
    reference = reference or ReferenceModel(pack)
    with np.load(folder / 'source-correspondence.npz') as correspondence:
        mapping = correspondence['sourceFaces'].copy()
    with np.load(source) as archive:
        points, faces = archive['points'], archive['faces']
    if len(mapping) != len(reference.arrays['faces']) or len(mapping) != proof['retainedFaces']:
        raise ValueError((name, 'Incomplete source correspondence'))
    if not len(mapping) or mapping.min() < 0 or mapping.max() >= len(faces):
        raise ValueError((name, 'Invalid source face identifiers'))
    for first in range(0, len(mapping), 50000):
        last = first + 50000
        packed = reference.arrays['vertices'][reference.arrays['faces'][first:last]]
        original = points[faces[mapping[first:last]]]
        if not np.allclose(packed, original, rtol=0, atol=1e-6):
            raise ValueError((name, 'Packed triangle differs from declared source', first))
    retained = np.zeros(len(faces), dtype=bool)
    retained[mapping] = True
    masked = np.zeros(len(faces), dtype=bool)
    masked[mapping[reference.arrays['faceMasks'] >= 0]] = True
    return dict(reference=reference, mapping=mapping, retained=retained, masked=masked,
                proof=dict(sourceGeometrySha256=proof['geometrySha256'],
                           sourcePackSha256=proof['packSha256'],
                           verifiedTriangles=len(mapping)))
