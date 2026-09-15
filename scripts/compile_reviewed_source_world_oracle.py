"""Build a source-height 3D oracle for reviewed lines and connected regions.

All discarded pieces are restored, even exact or numerical zero-area pieces.
This is an offline reference subset, not a production pack or floor policy.
"""
import argparse
import gzip
import json
from pathlib import Path
from types import SimpleNamespace

import numpy as np

from authored_region_cells import partition_mesh
from authored_wall_profile_cells import inverse_in_cell
from lift_reviewed_wall_source_heights import sha
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from tactical_pack_writer import write_pack
from verify_normalized_wall_profiles import verify_source_partition


def restore_triangle(display_triangle, backward, matrix, origin):
    """Split inverse-display cells while carrying exact source attributes."""
    data = np.column_stack((display_triangle, np.eye(3)))
    inverse = np.linalg.inv(matrix)
    output = []
    for polygon, cell in partition_mesh(data, backward.points, backward.tri.simplices):
        for j in range(1, len(polygon) - 1):
            part = polygon[[0, j, j + 1]]
            xy = (inverse_in_cell(part[:, :2], backward, cell) - origin) @ inverse.T
            output.append((np.column_stack((xy, part[:, 2])), part[:, 3:], cell))
    if not output:
        raise ValueError('Restored fragment was not assigned to a display cell')
    return output


def compile_oracle(lifted, candidate, warp_path, output):
    if output.exists():
        raise FileExistsError(output)
    report = json.loads((lifted / 'report.json').read_text())
    lift_path = lifted / 'source-world-fragments.npz'
    assert sha(lift_path) == report['dataSha256']
    assert sha(warp_path) == report['displayWarpSha256']
    # NpzFile decompresses on every lookup. Cache each array once before taking
    # views in the fragment loop, otherwise each retained row owns a fresh copy.
    with np.load(lift_path) as archive:
        data = {name: archive[name] for name in archive.files}
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    candidate_path = candidate / f'{report["map"]}.height.bin.gz'
    assert sha(candidate_path) == report['candidatePackSha256']
    header, scene = pack(candidate_path)
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.asarray(warp['projection']['origin'])
    source = np.asarray(warp['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    target = np.asarray(warp['targetAttackSvg']).reshape(-1, 2)
    backward = explicit_warp(target, source - target, np.asarray(warp['triangles']).reshape(-1, 3))
    triangles, parents, barycentrics, edges, restored_ids, fragment_weights = [], [], [], [], [], []
    masks, uvs, materials = [], [], []

    def append(triangle, parent, bary, edge, restored, uv, material, weights):
        triangles.append(triangle); parents.append(parent); barycentrics.append(bary)
        edges.append(edge); restored_ids.append(restored)
        fragment_weights.append(weights)
        masks.append(-1 if uv is None else len(uvs))
        if uv is not None:
            uvs.append(uv); materials.append(material)

    for i in np.flatnonzero(data['edges'] >= 0):
        mask = int(data['faceMasks'][i])
        append(data['triangles'][i], data['fullSourceParents'][i], data['sourceBarycentrics'][i],
            data['edges'][i], -1, None if mask < 0 else data['maskedUvs'][mask],
            -1 if mask < 0 else data['maskedMaterials'][mask], np.eye(3))
    generated_count = len(triangles)
    partition_parents, partition_bary = [], []
    discarded = np.flatnonzero(data['discardedEdges'] >= 0)
    for i in discarded:
        display = data['discardedAbsoluteDisplayTriangles'][i]
        assert np.isfinite(display).all(), ('Unmapped discarded fragment', int(i))
        mask = int(data['discardedFaceMasks'][i])
        for triangle, weights, cell in restore_triangle(display, backward, matrix, origin):
            append(triangle, data['discardedFullSourceParents'][i],
                weights @ data['discardedSourceBarycentrics'][i], data['discardedEdges'][i], i,
                None if mask < 0 else weights @ data['discardedMaskedUvs'][i],
                -1 if mask < 0 else data['discardedMaskedMaterials'][i], weights)
            partition_parents.append(i); partition_bary.append(weights)
    # Every discarded triangle is represented once in source coordinates.
    # Do not use its projected area to decide whether to retain it.
    partition = verify_source_partition(np.asarray(partition_parents), np.asarray(partition_bary), discarded)
    triangles = np.asarray(triangles)
    assert np.isfinite(triangles).all()
    source_pack = SimpleNamespace(header=header, raw=gzip.decompress(candidate_path.read_bytes()))
    proof = dict(scope=__doc__, liftDataSha256=sha(lift_path),
        fullSourcePackSha256=report['fullSourcePackSha256'], sourceProfileProofSha256=report['sourceProfileProofSha256'],
        restoredSourcePartition=partition, productionMutation=False)
    write_pack(source_pack, candidate_path, output, triangles.reshape(-1, 3),
        np.arange(triangles.size // 3).reshape(-1, 3), np.asarray(masks),
        np.asarray(uvs).reshape(-1, 3, 2), np.asarray(materials), np.arange(len(triangles)),
        header['tacticalGroundFieldSha256'], [float(triangles[:, :, 2].min()), float(triangles[:, :, 2].max())],
        proof, header_overrides=dict(status='experimental-source-height-reviewed-subset',
            coordinatePolicy='authored-normalized-XY-original-source-Z',
            referenceEquivalence='Only reviewed source families; original heights and material references restored. No floor or full-game equivalence.'))
    order = np.load(output / 'correspondence.npz')['sourceFaces']
    np.savez_compressed(output / 'original-source-provenance.npz',
        fullSourceParents=np.asarray(parents)[order], sourceBarycentrics=np.asarray(barycentrics)[order],
        edges=np.asarray(edges)[order], restoredDiscardIds=np.asarray(restored_ids)[order],
        inputFragmentBarycentrics=np.asarray(fragment_weights)[order])
    result = dict(scope=__doc__, generatedFragments=generated_count,
        discardedFragmentsRestored=len(discarded), restoredTriangles=len(triangles) - generated_count,
        totalTriangles=len(triangles), compilerSha256=sha(Path(__file__)),
        regionPartitionHelperSha256=sha(Path(__file__).with_name('authored_region_cells.py')),
        inverseWarpHelperSha256=sha(Path(__file__).with_name('authored_wall_profile_cells.py')),
        liftDataSha256=sha(lift_path), oraclePackSha256=sha(output / f'{report["map"]}.height.bin.gz'),
        sourceProvenanceSha256=sha(output / 'original-source-provenance.npz'),
        restoredSourcePartition=partition, productionMutation=False,
        limitations=['Reviewed families only; unaffected geometry absent.',
                     'Every discarded fragment retained; no exact zero-area classification required.',
                     'Independent height, material and sightline verification still required.'])
    (output / 'source-height-oracle-report.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['lifted', 'candidate', 'warp', 'output']:
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    compile_oracle(args.lifted, args.candidate, args.warp, args.output)
