"""Check complete reference composition and literal inverse-ground heights.

The subset's independently checked original heights and authored XY are retained
bit-for-bit. Other fragments are reconstructed from sealed control provenance.
This establishes composition within the existing control domain, not game LOS.
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
from verify_source_height_region_oracle import arrays


def texture_bytes(path, header):
    raw = gzip.decompress(path.read_bytes())
    base = (8 + struct.unpack_from('<I', raw, 4)[0] + 7) // 8 * 8
    return [(t['width'], t['height'], raw[base+t['offset']:base+t['offset']+t['width']*t['height']]) for t in header['textures']]


def verify(complete, candidate, subset, output):
    if output.exists():
        raise FileExistsError(output)
    report = json.loads((complete / 'complete-oracle-report.json').read_text())
    bindings = json.loads((candidate / 'bindings.json').read_text())
    control_path = Path(bindings['sourceBackup'])
    original_path = Path(bindings.get('originalSourcePack', str(control_path)))
    control_header, control = pack(control_path)
    name = control_header['map']
    complete_path, subset_path = complete / f'{name}.height.bin.gz', subset / f'{name}.height.bin.gz'
    header, scene = pack(complete_path)
    subset_header, reviewed = pack(subset_path)
    assert sha(complete_path) == report['packSha256']
    assert sha(subset_path) == report['proof']['subsetPackSha256']
    assert sha(candidate / f'{name}.height.bin.gz') == report['proof']['candidatePackSha256']
    assert sha(complete / 'composition-provenance.npz') == report['compositionProvenanceSha256']
    assert sha(control_path) == sha(original_path) == bindings['sourcePackSha256']
    assert sha(subset / 'root-height-material-review.json') == report['proof']['originalHeightGateSha256']
    assert sha(subset / 'root-restored-xy-review.json') == report['proof']['restoredXYGateSha256']
    height_gate = json.loads((subset / 'root-height-material-review.json').read_text())
    xy_gate = json.loads((subset / 'root-restored-xy-review.json').read_text())
    candidate_gate = json.loads((candidate / 'root-independent-profile-review.json').read_text())
    assert height_gate['passed'] and xy_gate['passed']
    assert candidate_gate['status'] == 'attribute-and-continuous-span-contact-checks-passed'
    candidate_sha = sha(candidate / f'{name}.height.bin.gz')
    assert candidate_gate['candidatePackSha256'] == height_gate['candidatePackSha256'] == xy_gate['candidatePackSha256'] == candidate_sha
    assert candidate_gate['wallBindingsSha256'] == height_gate['bindingsSha256'] == sha(candidate / 'bindings.json')
    assert height_gate['oraclePackSha256'] == xy_gate['oraclePackSha256'] == sha(subset_path)
    assert height_gate['sourceProvenanceSha256'] == xy_gate['oracleProvenanceSha256'] == sha(subset / 'original-source-provenance.npz')
    assert sha(candidate / 'normalized-face-provenance.npz') == candidate_gate['provenanceSha256']
    sealed = arrays(candidate / 'normalized-face-provenance.npz')
    candidate_parents = arrays(candidate / 'correspondence.npz')['sourceFaces']
    composition = arrays(complete / 'composition-provenance.npz')
    group, identity = composition['group'], composition['inputId']
    assert len(group) == len(scene['faces']) and np.isin(group, [0, 1, 2, 3]).all()
    untouched = np.ones(len(candidate_parents), dtype=bool)
    untouched[sealed['generatedFaceIds']] = False
    required = [candidate_parents[untouched], np.flatnonzero(sealed['generatedEdges'] < 0),
                np.flatnonzero(sealed['discardedEdges'] < 0), np.arange(len(reviewed['faces']))]
    for kind in range(4):
        assert np.array_equal(np.sort(identity[group == kind]), np.sort(required[kind])), ('missing/duplicated composition input', kind)
    removed = np.unique(np.r_[candidate_parents[sealed['generatedFaceIds']], sealed['discardedSourceFaces'].astype(int)])
    assert np.array_equal(np.sort(np.r_[required[0], removed]), np.arange(len(control['faces'])))
    ground_path = original_path.parent / f'{name}.tactical-ground.json.gz'
    assert sha(ground_path) == control_header['tacticalGroundFieldSha256']
    field = GroundField(ground_path)
    maximum_z, maximum_xy, maximum_uv = 0., 0., 0.
    for start in range(0, len(group), 50000):
        rows = np.arange(start, min(start+50000, len(group)))
        actual = scene['vertices'][scene['faces'][rows]]
        for kind in range(4):
            local = np.flatnonzero(group[rows] == kind)
            if not len(local):
                continue
            ids = identity[rows[local]]
            if kind == 3:
                expected = reviewed['vertices'][reviewed['faces'][ids]]
                assert np.array_equal(actual[local], expected), 'Checked subset geometry changed'
                source = reviewed; masks = source['faceMasks'][ids]; weights = None
            else:
                if kind == 0:
                    parents = ids; weights = None
                elif kind == 1:
                    parents = candidate_parents[sealed['generatedFaceIds'][ids]]
                    weights = sealed['generatedBarycentrics'][ids]
                else:
                    parents = sealed['discardedSourceFaces'][ids].astype(int)
                    weights = sealed['discardedBarycentrics'][ids]
                parent_xyz = control['vertices'][control['faces'][parents]].copy()
                parent_xyz[:, :, 2] += field.heights(parent_xyz[:, :, :2].reshape(-1, 2)).reshape(-1, 3)
                expected = parent_xyz if weights is None else parent_xyz[:, :1] + np.einsum('nij,njk->nik', weights[:, :, 1:], parent_xyz[:, 1:] - parent_xyz[:, :1])
                source = control; masks = source['faceMasks'][parents]
            z_error = float(abs(actual[local, :, 2] - expected[:, :, 2]).max(initial=0))
            xy_error = float(abs(actual[local, :, :2] - expected[:, :, :2]).max(initial=0))
            maximum_z = max(maximum_z, z_error); maximum_xy = max(maximum_xy, xy_error)
            assert z_error < 1e-7 and xy_error < 1e-7, (kind, z_error, xy_error)
            actual_masks = scene['faceMasks'][rows[local]]
            assert np.array_equal(masks >= 0, actual_masks >= 0)
            masked = masks >= 0
            if masked.any():
                uv = source['maskedUvs'][masks[masked]]
                if weights is not None:
                    uv = weights[masked] @ uv
                observed_uv = scene['maskedUvs'][actual_masks[masked]]
                uv_error = float(abs(uv - observed_uv).max(initial=0))
                maximum_uv = max(maximum_uv, uv_error)
                assert uv_error < 1e-10, uv_error
                assert np.array_equal(source['maskedMaterials'][masks[masked]], scene['maskedMaterials'][actual_masks[masked]])
    assert header['materials'] == control_header['materials'] == subset_header['materials']
    assert texture_bytes(complete_path, header) == texture_bytes(control_path, control_header) == texture_bytes(subset_path, subset_header)
    result = dict(scope=__doc__, passed=True, triangles=len(group), groupCounts=[len(x) for x in required],
        maximumLiteralInverseGroundZErrorMeters=maximum_z, maximumUnchangedXYErrorMeters=maximum_xy,
        maximumUvError=maximum_uv, checkedSubsetBitwiseUnchanged=True, everyInputRetainedExactlyOnce=True,
        completePackSha256=sha(complete_path), candidatePackSha256=sha(candidate / f'{name}.height.bin.gz'),
        subsetPackSha256=sha(subset_path), verifierSha256=sha(Path(__file__)), productionMutation=False)
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['complete', 'candidate', 'subset', 'output']:
        parser.add_argument(key, type=Path)
    verify(**vars(parser.parse_args()))
