"""Independently verify authored XY of restored discarded source fragments.

Reconstruct from the sealed control parents, not the lift's mapped triangles.
Every restored triangle must fit one forward display cell, including line and
point projections. This proves the affine interior as well as its vertices.
Original source Z, UV, opacity and partition coverage require the separate gate.
"""
import argparse
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from lift_reviewed_wall_source_heights import sha
from tactical_alignment_audit import pack
from verify_normalized_wall_profiles import profile_frame, reconstruct_source_points
from verify_region_mapping import declared_mapping


def arrays(path):
    with np.load(path) as archive:
        return {key: archive[key] for key in archive.files}


def anchored(weights, triangles):
    return triangles[:, :1] + np.einsum('nij,njk->nik', weights[:, :, 1:],
                                       triangles[:, 1:] - triangles[:, :1])


def cell_weights(points, triangles):
    """Solve in local coordinates, independent of the compiler's inverse map."""
    basis = np.swapaxes(triangles[:, 1:] - triangles[:, :1], 1, 2)
    uv = np.linalg.solve(basis, np.swapaxes(points-triangles[:, :1], 1, 2))
    uv = np.swapaxes(uv, 1, 2)
    return np.concatenate((1-uv.sum(2, keepdims=True), uv), axis=2)


def affine_display(triangles, source_cells, target_cells):
    """Reject a hidden W kink even when all three mapped vertices agree.

    The search padding only finds candidate cells. Acceptance uses the same
    1e-8 barycentric containment gate as the independent candidate verifier.
    It never edits the geometry or enlarges a blocker.
    """
    triangles = np.asarray(triangles, dtype=float)
    source_cells = np.asarray(source_cells, dtype=float)
    target_cells = np.asarray(target_cells, dtype=float)
    assert source_cells.shape == target_cells.shape
    assert triangles.ndim == 3 and triangles.shape[1:] == (3, 2)
    assert np.isfinite(triangles).all()
    centers = triangles[:, 0] + ((triangles[:, 1]-triangles[:, 0])
                               + (triangles[:, 2]-triangles[:, 0]))/3
    # A triangle inside a convex W cell has its centroid inside that same cell.
    # Degenerate line and point projections satisfy the same implication.
    tree = shapely.STRtree(shapely.polygons(source_cells))
    candidate = tree.query(shapely.box(centers[:, 0]-1e-8, centers[:, 1]-1e-8,
                                      centers[:, 0]+1e-8, centers[:, 1]+1e-8))
    rows, cells = candidate
    weights = cell_weights(triangles[rows], source_cells[cells])
    minimum = weights.min(axis=(1, 2))
    eligible = np.flatnonzero(minimum >= -1e-8)
    # Prefer the largest containment margin when an edge belongs to both cells.
    ranking = eligible[np.lexsort((cells[eligible], -minimum[eligible], rows[eligible]))]
    _, first = np.unique(rows[ranking], return_index=True)
    chosen = ranking[first]
    selected = np.full(len(triangles), -1, dtype=int)
    selected[rows[chosen]] = cells[chosen]
    missing = np.flatnonzero(selected < 0)
    assert not len(missing), ('Restored triangle crosses W cells or is outside W', missing[:20].tolist(), len(missing))
    final_weights = cell_weights(triangles, source_cells[selected])
    displayed = anchored(final_weights, target_cells[selected])
    return displayed, selected, float(final_weights.min(initial=0))


def line_mapping(family, points):
    origin, tangent, _ = profile_frame(family, 'source')
    along = (points-origin) @ tangent
    low, high = family['sourceAlong']
    assert high > low
    # A clamped affine function is affine on a fragment only if no interior
    # crosses either clamp boundary. Do not certify just its endpoints.
    for boundary in (low, high):
        crossing = (along.min(1) < boundary-1e-8) & (along.max(1) > boundary+1e-8)
        assert not crossing.any(), ('Unsplit source clamp', family['edge'], np.flatnonzero(crossing)[:20].tolist())
    target_low, target_high = family['targetAlong']
    parameter = target_low + np.clip((along-low)/(high-low), 0, 1)*(target_high-target_low)
    target_origin, target_tangent, _ = profile_frame(family, 'target')
    return target_origin + parameter[..., None]*target_tangent


def verify_displayed_xy(actual_xy, expected_xy, source_cells, target_cells):
    displayed, cells, minimum = affine_display(actual_xy, source_cells, target_cells)
    assert displayed.shape == expected_xy.shape and np.isfinite(expected_xy).all()
    errors = np.linalg.norm(displayed-expected_xy, axis=2)
    maximum = float(errors.max(initial=0))
    assert maximum < 1e-7, ('Restored authored XY mismatch', maximum, np.unravel_index(errors.argmax(), errors.shape))
    return maximum, cells, minimum


def verify(oracle, candidate, warp_path, output):
    assert not output.exists(), output
    binding_path = candidate/'bindings.json'
    bindings = json.loads(binding_path.read_text())
    control_path = Path(bindings['sourceBackup'])
    assert sha(control_path) == bindings['sourcePackSha256']
    assert sha(warp_path) == bindings['displayWarpSha256']
    header, control = pack(control_path)
    name = header['map']
    sealed_path = candidate/'normalized-face-provenance.npz'
    sealed = arrays(sealed_path)
    actual_path = oracle/'original-source-provenance.npz'
    actual = arrays(actual_path)
    oracle_path = oracle/f'{name}.height.bin.gz'
    _, scene = pack(oracle_path)
    report_path = oracle/'source-height-oracle-report.json'
    report = json.loads(report_path.read_text())
    assert sha(actual_path) == report['sourceProvenanceSha256']
    assert sha(oracle_path) == report['oraclePackSha256']
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.asarray(warp['projection']['origin'])
    source_w = np.asarray(warp['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    target_w = np.asarray(warp['targetAttackSvg']).reshape(-1, 2)
    w_cells = np.asarray(warp['triangles']).reshape(-1, 3)
    parents = sealed['discardedSourceFaces'].astype(np.int64)
    assert np.array_equal(parents, sealed['discardedSourceFaces'])
    original = control['vertices'][control['faces'][parents]]
    bary = sealed['discardedBarycentrics']
    source_xy = reconstruct_source_points(bary, original)[:, :, :2] @ matrix.T + origin
    expected = np.full_like(source_xy, np.nan)
    hashes = dict(controlPack=sha(control_path), sealedProvenance=sha(sealed_path),
                  bindings=sha(binding_path), warp=sha(warp_path))
    records = []
    for family in bindings['families']:
        ids = np.flatnonzero(sealed['discardedEdges'] == family['edge'])
        if not len(ids):
            continue
        if family.get('mappingType') == 'piecewise-affine-region-v1':
            cells = sealed['discardedRegionCells'][ids].astype(np.int64)
            assert (cells >= 0).all(), ('Unassigned source region cell requires separate recovery', family['edge'])
            construction = dict(originalNativeTriangles=original[ids], sourceBarycentrics=bary[ids],
                projectionMatrix=matrix, projectionOrigin=origin, sourceParents=parents[ids],
                regionCells=cells, inputHashes=hashes)
            expected[ids], _ = declared_mapping(family, source_xy[ids], cells,
                source_construction=construction, containment_records=records)
        else:
            expected[ids] = line_mapping(family, source_xy[ids])
    rows = np.flatnonzero(actual['restoredDiscardIds'] >= 0)
    restored = actual['restoredDiscardIds'][rows]
    assert np.array_equal(restored, restored.astype(np.int64))
    restored = restored.astype(np.int64)
    assert (restored < len(parents)).all()
    required = np.flatnonzero(sealed['discardedEdges'] >= 0)
    assert set(restored.tolist()) == set(required.tolist())
    assert np.array_equal(actual['edges'][rows], sealed['discardedEdges'][restored])
    weights = actual['inputFragmentBarycentrics'][rows]
    assert np.isfinite(weights).all() and weights.min() >= -1e-8
    assert abs(weights.sum(2)-1).max() < 1e-8
    expected_xy = anchored(weights, expected[restored])
    assert np.isfinite(expected_xy).all()
    actual_xy = scene['vertices'][scene['faces'][rows]][:, :, :2] @ matrix.T + origin
    maximum, cells, minimum = verify_displayed_xy(actual_xy, expected_xy, source_w[w_cells], target_w[w_cells])
    result = dict(scope=__doc__, passed=True, restoredFragments=len(required), restoredTriangles=len(rows),
        maximumAuthoredXYErrorSvg=maximum, minimumDisplayCellBarycentric=minimum,
        usedDisplayCells=len(np.unique(cells)), sourceRegionContainment=records,
        oraclePackSha256=sha(oracle_path), oracleProvenanceSha256=sha(actual_path),
        oracleReportSha256=sha(report_path), candidatePackSha256=sha(candidate/f'{name}.height.bin.gz'),
        inputSha256=hashes, verifierSha256=sha(Path(__file__)),
        regionVerifierSha256=sha(Path(__file__).with_name('verify_region_mapping.py')),
        sourceContainmentHelperSha256=sha(Path(__file__).with_name('precise_region_containment.py')),
        limitations=['Discarded XY only; use the independent original-Z/material/partition gate together with this report.',
                     'Unassigned source-region cells fail explicitly; this verifier does not invent their ownership.',
                     'No whole-map, gameplay, floor-policy or performance certification.'])
    output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({key: value for key, value in result.items() if key != 'sourceRegionContainment'}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['oracle', 'candidate', 'warp', 'output']:
        parser.add_argument(key, type=Path)
    args = parser.parse_args()
    verify(args.oracle, args.candidate, args.warp, args.output)
