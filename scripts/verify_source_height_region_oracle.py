"""Independently check original heights, materials and complete fragment retention.

Source heights are recovered from the control ground and original full triangles,
using a dominant-plane solve instead of the lift's pseudoinverse. This does not
certify gameplay, floor selection, or the authored XY policy.
"""
import argparse
import gzip
import json
import struct
from pathlib import Path

import numpy as np

from build_global_tactical_candidate import GroundField
from lift_reviewed_wall_source_heights import sha
from tactical_alignment_audit import pack
from verify_normalized_wall_profiles import verify_source_partition, reconstruct_source_points
from verify_source_world_wall_oracle import dominant_bary


def arrays(path):
    with np.load(path) as archive:
        return {name: archive[name] for name in archive.files}


def verify(oracle, candidate, full_path, output):
    if output.exists():
        raise FileExistsError(output)
    bindings_path = candidate / 'bindings.json'
    bindings = json.loads(bindings_path.read_text())
    control_path = Path(bindings['sourceBackup'])
    original_path = Path(bindings.get('originalSourcePack', str(control_path)))
    header, control = pack(control_path)
    assert sha(control_path) == sha(original_path) == bindings['sourcePackSha256']
    assert sha(full_path) == header['sourcePackSha256']
    full_header, full = pack(full_path)
    name = header['map']
    candidate_path = candidate / f'{name}.height.bin.gz'
    _, candidate_scene = pack(candidate_path)
    oracle_path = oracle / f'{name}.height.bin.gz'
    oracle_header, scene = pack(oracle_path)
    compiler_report = json.loads((oracle / 'source-height-oracle-report.json').read_text())
    assert sha(oracle_path) == compiler_report['oraclePackSha256']
    provenance_path = oracle / 'original-source-provenance.npz'
    assert sha(provenance_path) == compiler_report['sourceProvenanceSha256']
    actual = arrays(provenance_path)
    sealed = arrays(candidate / 'normalized-face-provenance.npz')
    candidate_parents = arrays(candidate / 'correspondence.npz')['sourceFaces']
    control_to_full = arrays(original_path.parent / 'correspondence.npz')['sourceFaces']
    ground_path = original_path.parent / f'{name}.tactical-ground.json.gz'
    assert sha(ground_path) == header['tacticalGroundFieldSha256']
    gen_rows = np.flatnonzero(sealed['generatedEdges'] >= 0)
    gen_faces = sealed['generatedFaceIds'][gen_rows]
    gen_parents = candidate_parents[gen_faces]
    disc_parents = sealed['discardedSourceFaces'].astype(int)
    parents = np.unique(np.r_[gen_parents, disc_parents])
    ctrl_triangles = control['vertices'][control['faces'][parents]].copy()
    ctrl_triangles[:, :, 2] += GroundField(ground_path).heights(ctrl_triangles[:, :, :2].reshape(-1, 2)).reshape(-1, 3)
    source_triangles = full['vertices'][full['faces'][control_to_full[parents]]]
    parent_bary, plane_error = dominant_bary(ctrl_triangles, source_triangles)
    assert plane_error < 1e-7, plane_error
    gen_bary = sealed['generatedBarycentrics'][gen_rows] @ parent_bary[np.searchsorted(parents, gen_parents)]
    disc_bary = sealed['discardedBarycentrics'] @ parent_bary[np.searchsorted(parents, disc_parents)]
    order = arrays(oracle / 'correspondence.npz')['sourceFaces']
    generated = actual['restoredDiscardIds'] < 0
    assert np.array_equal(np.sort(order[generated]), np.arange(len(gen_rows))), 'Missing or duplicated generated fragment'
    assert np.array_equal(generated, order < len(gen_rows))
    discarded = ~generated
    disc_ids = actual['restoredDiscardIds'][discarded]
    required = np.flatnonzero(sealed['discardedEdges'] >= 0)
    assert set(disc_ids.tolist()) == set(required.tolist()), 'Missing or unexpected discarded fragment'
    weights = actual['inputFragmentBarycentrics'][discarded]
    coverage = verify_source_partition(disc_ids, weights, required)
    expected_bary = np.empty_like(actual['sourceBarycentrics'])
    expected_parents = np.empty(len(order), dtype=int)
    expected_edges = np.empty(len(order), dtype=int)
    expected_bary[generated] = gen_bary[order[generated]]
    expected_parents[generated] = control_to_full[gen_parents[order[generated]]]
    expected_edges[generated] = sealed['generatedEdges'][gen_rows[order[generated]]]
    expected_bary[discarded] = weights @ disc_bary[disc_ids]
    expected_parents[discarded] = control_to_full[disc_parents[disc_ids]]
    expected_edges[discarded] = sealed['discardedEdges'][disc_ids]
    assert np.array_equal(expected_parents, actual['fullSourceParents'])
    assert np.array_equal(expected_edges, actual['edges'])
    bary_error = float(abs(expected_bary - actual['sourceBarycentrics']).max())
    assert bary_error < 1e-8, bary_error
    xyz = scene['vertices'][scene['faces']]
    original = reconstruct_source_points(expected_bary, full['vertices'][full['faces'][expected_parents]])
    height_error = float(abs(xyz[:, :, 2] - original[:, :, 2]).max())
    assert height_error < 1e-7, height_error
    candidate_xy = candidate_scene['vertices'][candidate_scene['faces'][gen_faces[order[generated]]]][:, :, :2]
    assert np.array_equal(xyz[generated, :, :2], candidate_xy), 'Generated authored XY changed'
    source_masks = full['faceMasks'][expected_parents]
    masks = scene['faceMasks']
    assert np.array_equal(source_masks >= 0, masks >= 0)
    masked = masks >= 0
    uv_error = 0.
    if masked.any():
        expected_uv = expected_bary[masked] @ full['maskedUvs'][source_masks[masked]]
        uv_error = float(abs(expected_uv - scene['maskedUvs'][masks[masked]]).max())
        assert uv_error < 1e-7, uv_error
        assert np.array_equal(full['maskedMaterials'][source_masks[masked]], scene['maskedMaterials'][masks[masked]])

    def texture_bytes(path, metadata):
        raw = gzip.decompress(path.read_bytes())
        start = (8 + struct.unpack_from('<I', raw, 4)[0] + 7) // 8 * 8
        return [(t['width'], t['height'], raw[start+t['offset']:start+t['offset']+t['width']*t['height']]) for t in metadata['textures']]

    assert texture_bytes(full_path, full_header) == texture_bytes(oracle_path, oracle_header)
    assert full_header['materials'] == oracle_header['materials'], 'Source alpha sampler or threshold table changed'
    result = dict(scope=__doc__, passed=True, originalParentPlaneErrorMeters=plane_error,
        maximumSourceBarycentricError=bary_error, maximumOriginalHeightErrorMeters=height_error,
        maximumOriginalUvError=uv_error, generatedFragments=int(generated.sum()),
        discardedFragmentsRetained=len(required), restoredTriangles=int(discarded.sum()),
        restoredSourcePartition=coverage, oraclePackSha256=sha(oracle_path),
        sourceProvenanceSha256=sha(provenance_path), fullSourcePackSha256=sha(full_path),
        candidatePackSha256=sha(candidate_path), bindingsSha256=sha(bindings_path),
        verifierSha256=sha(Path(__file__)),
        limitations=['Independent original-height/material/retention proof only.',
                     'Generated XY matches source-gated candidate; discarded XY mapping still requires separate verification.',
                     'No whole-map, floor, gameplay or performance certification.'])
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'restoredSourcePartition'}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['oracle', 'candidate', 'full', 'output']:
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    verify(args.oracle, args.candidate, args.full, args.output)
