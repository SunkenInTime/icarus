"""Restore original Z across the existing candidate's complete control domain.

This composes the independently checked reviewed subset with untouched control
faces and unbound fragments. It does not restore geometry excluded before the
control pack, choose a receiver floor, or certify the game's visibility policy.
"""
import argparse
import gzip
import json
from pathlib import Path
from types import SimpleNamespace

import numpy as np

from build_global_tactical_candidate import GroundField
from lift_reviewed_wall_source_heights import sha
from tactical_alignment_audit import pack
from tactical_pack_writer import write_pack
from verify_source_height_region_oracle import arrays


def disjoint_control_cover(face_count, unchanged, removed):
    unchanged, removed = np.asarray(unchanged), np.asarray(removed)
    combined = np.r_[unchanged, removed]
    if not np.array_equal(np.sort(combined), np.arange(face_count)):
        raise ValueError('Untouched and replaced control parents must partition the control exactly')


def source_triangle_distances(points, triangles):
    """Metric distance, including thin/degenerate source faces, without moving points."""
    edges = np.roll(triangles, -1, axis=1) - triangles
    delta = points[:, :, None, :] - triangles[:, None, :, :]
    lengths2 = np.sum(edges * edges, axis=2)
    parameters = np.divide(np.einsum('nped,ned->npe', delta, edges), lengths2[:, None, :],
        out=np.zeros(delta.shape[:3]), where=lengths2[:, None, :] > 0)
    closest = triangles[:, None, :, :] + np.clip(parameters, 0, 1)[..., None] * edges[:, None, :, :]
    distance = np.linalg.norm(points[:, :, None, :] - closest, axis=3).min(2)
    normal = np.cross(edges[:, 0], triangles[:, 2] - triangles[:, 0])
    length = np.linalg.norm(normal, axis=1)
    unit = np.divide(normal, length[:, None], out=np.zeros_like(normal), where=length[:, None] > 0)
    signs = np.einsum('nped,nd->npe', np.cross(edges[:, None, :, :], delta), unit)
    inside = (signs >= 0).all(2) & (length[:, None] > 0)
    plane_distance = abs(np.einsum('npd,nd->np', points - triangles[:, :1], unit))
    return np.where(inside, plane_distance, distance)


def compile_complete(candidate, lifted, oracle, full_path, output):
    if output.exists():
        raise FileExistsError(output)
    bindings = json.loads((candidate / 'bindings.json').read_text())
    gate = json.loads((candidate / 'root-independent-profile-review.json').read_text())
    lift_report = json.loads((lifted / 'report.json').read_text())
    height_gate = json.loads((oracle / 'root-height-material-review.json').read_text())
    xy_gate = json.loads((oracle / 'root-restored-xy-review.json').read_text())
    assert height_gate['passed'] and xy_gate['passed']
    control_path = Path(bindings['sourceBackup'])
    original_path = Path(bindings.get('originalSourcePack', str(control_path)))
    header, control = pack(control_path)
    name = header['map']
    candidate_path, oracle_path = candidate / f'{name}.height.bin.gz', oracle / f'{name}.height.bin.gz'
    assert sha(candidate_path) == gate['candidatePackSha256'] == height_gate['candidatePackSha256'] == lift_report['candidatePackSha256']
    assert sha(oracle_path) == height_gate['oraclePackSha256'] == xy_gate['oraclePackSha256']
    assert sha(control_path) == sha(original_path) == bindings['sourcePackSha256']
    assert sha(full_path) == header['sourcePackSha256'] == lift_report['fullSourcePackSha256']
    assert sha(candidate / 'bindings.json') == gate['wallBindingsSha256']
    lift_path = lifted / 'source-world-fragments.npz'
    assert sha(lift_path) == lift_report['dataSha256']
    sealed = arrays(candidate / 'normalized-face-provenance.npz')
    assert sha(candidate / 'normalized-face-provenance.npz') == gate['provenanceSha256']
    data = arrays(lift_path)
    correspondence = arrays(candidate / 'correspondence.npz')['sourceFaces']
    unchanged = np.ones(len(correspondence), dtype=bool)
    unchanged[sealed['generatedFaceIds']] = False
    untouched_parents = correspondence[unchanged]
    removed = np.unique(np.r_[data['controlParents'], data['discardedControlParents']])
    disjoint_control_cover(len(control['faces']), untouched_parents, removed)
    full_header, full = pack(full_path)
    oracle_header, subset = pack(oracle_path)
    assert header['materials'] == full_header['materials'] == oracle_header['materials']
    field_path = original_path.parent / f'{name}.tactical-ground.json.gz'
    assert sha(field_path) == header['tacticalGroundFieldSha256']
    field = GroundField(field_path)
    control_to_full = arrays(original_path.parent / 'correspondence.npz')['sourceFaces']
    assert sha(original_path.parent / 'correspondence.npz') == lift_report['controlCorrespondenceSha256']
    triangles, masks, uvs, materials, groups, identities = [], [], [], [], [], []
    mask_offset = 0

    def append(xyz, face_masks, source_uvs, source_materials, group, ids):
        nonlocal mask_offset
        selected = np.asarray(face_masks) >= 0
        new_masks = np.full(len(xyz), -1, dtype=np.int32)
        new_masks[selected] = mask_offset + np.arange(int(selected.sum()))
        triangles.append(xyz); masks.append(new_masks)
        uvs.append(source_uvs[np.asarray(face_masks)[selected]])
        materials.append(source_materials[np.asarray(face_masks)[selected]])
        groups.append(np.full(len(xyz), group, dtype=np.int8)); identities.append(ids)
        mask_offset += int(selected.sum())

    maximum_source_distance = 0.
    for start in range(0, len(untouched_parents), 50000):
        parents = untouched_parents[start:start + 50000]
        xyz = control['vertices'][control['faces'][parents]].copy()
        xyz[:, :, 2] += field.heights(xyz[:, :, :2].reshape(-1, 2)).reshape(-1, 3)
        original = full['vertices'][full['faces'][control_to_full[parents]]]
        error = float(source_triangle_distances(xyz, original).max(initial=0))
        maximum_source_distance = max(maximum_source_distance, error)
        assert error < 1e-7, error
        # Preserve the literal inverse-ground transform; metric verification
        # avoids treating skinny source triangles as a large physical escape.
        append(xyz, control['faceMasks'][parents], control['maskedUvs'], control['maskedMaterials'], 0, parents)
    unbound = np.flatnonzero(data['edges'] < 0)
    append(data['triangles'][unbound], data['faceMasks'][unbound], data['maskedUvs'], data['maskedMaterials'], 1, unbound)
    unbound_discarded = np.flatnonzero(data['discardedEdges'] < 0)
    # Discarded UV arrays are indexed by fragment, unlike packed mask tables.
    disc_masks = np.where(data['discardedFaceMasks'][unbound_discarded] >= 0, unbound_discarded, -1)
    append(data['discardedSourceTriangles'][unbound_discarded], disc_masks, data['discardedMaskedUvs'], data['discardedMaskedMaterials'], 2, unbound_discarded)
    append(subset['vertices'][subset['faces']], subset['faceMasks'], subset['maskedUvs'], subset['maskedMaterials'], 3, np.arange(len(subset['faces'])))
    xyz = np.concatenate(triangles)
    proof = dict(scope=__doc__, candidatePackSha256=sha(candidate_path), subsetPackSha256=sha(oracle_path),
        originalHeightGateSha256=sha(oracle / 'root-height-material-review.json'),
        restoredXYGateSha256=sha(oracle / 'root-restored-xy-review.json'),
        liftDataSha256=sha(lift_path), untouchedControlFaces=len(untouched_parents), replacedControlParents=len(removed),
        unboundGeneratedFragments=len(unbound), unboundDiscardedFragments=len(unbound_discarded),
        reviewedSubsetTriangles=len(subset['faces']), untouchedMaximumSourceDistanceMeters=maximum_source_distance,
        untouchedSourceDistanceLimitMeters=1e-7, untouchedHeightPolicy='literal inverse of sealed control ground transform', productionMutation=False)
    source = SimpleNamespace(header=oracle_header, raw=gzip.decompress(oracle_path.read_bytes()))
    result = write_pack(source, oracle_path, output, xyz.reshape(-1, 3), np.arange(xyz.size // 3).reshape(-1, 3),
        np.concatenate(masks), np.concatenate(uvs), np.concatenate(materials), np.arange(len(xyz)),
        header['tacticalGroundFieldSha256'], [float(xyz[:, :, 2].min()), float(xyz[:, :, 2].max())], proof,
        header_overrides=dict(status='experimental-complete-control-domain-original-height-reference',
            coordinatePolicy='authored-normalized-XY-original-source-Z',
            referenceEquivalence='Existing control-domain geometry restored to original Z. No receiver policy or game equivalence.'))
    order = arrays(output / 'correspondence.npz')['sourceFaces']
    np.savez_compressed(output / 'composition-provenance.npz', group=np.concatenate(groups)[order], inputId=np.concatenate(identities)[order])
    result.update(proof=proof, compilerSha256=sha(Path(__file__)), compositionProvenanceSha256=sha(output / 'composition-provenance.npz'))
    (output / 'complete-oracle-report.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['candidate', 'lifted', 'oracle', 'full_path', 'output']:
        parser.add_argument(key, type=Path)
    args = parser.parse_args()
    compile_complete(**vars(args))
