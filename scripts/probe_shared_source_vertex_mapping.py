"""Find source vertices sent to different positions by adjacent wall families.

This checks recorded generated vertices only. It cannot certify arbitrary
surface intersections, T-junctions, discarded fragments, or unchanged walls.
The source proximity threshold handles reconstruction rounding; it is not an
allowed visible gap. Every mapped discrepancy is retained in the report.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
from scipy.spatial import cKDTree
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp


def cross_family_pairs(source, target, families, source_tolerance=1e-9):
    pairs = cKDTree(source).query_pairs(source_tolerance, output_type='ndarray')
    if not len(pairs):
        return pairs, np.empty(0), np.empty(0)
    pairs = pairs[families[pairs[:, 0]] != families[pairs[:, 1]]]
    source_gap = np.linalg.norm(source[pairs[:, 0]]-source[pairs[:, 1]], axis=1)
    target_gap = np.linalg.norm(target[pairs[:, 0]]-target[pairs[:, 1]], axis=1)
    return pairs, source_gap, target_gap


def run(candidate, warp_path, output):
    if output.exists():
        raise FileExistsError(output)
    bindings = json.loads((candidate/'bindings.json').read_text())
    before_path = Path(bindings['sourceBackup'])
    after_path = candidate / (bindings.get('map', 'split')+'.height.bin.gz')
    _, before = pack(before_path)
    _, after = pack(after_path)
    provenance = np.load(candidate/'normalized-face-provenance.npz')
    parents = np.load(candidate/'correspondence.npz')['sourceFaces']
    eligible = provenance['generatedEdges'] >= 0
    ids = provenance['generatedFaceIds'][eligible]
    families = np.repeat(provenance['generatedEdges'][eligible], 3)
    control_parents = parents[ids]
    triangles = before['vertices'][before['faces'][control_parents]]
    bary = provenance['generatedBarycentrics'][eligible]
    source = triangles[:, :1] + np.einsum(
        'nij,njk->nik', bary[:, :, 1:], triangles[:, 1:]-triangles[:, :1])
    target = after['vertices'][after['faces'][ids]]
    w = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((w['projection']['axisU'], w['projection']['axisV']))
    origin = np.array(w['projection']['origin'])
    src_svg = np.array(w['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    dst_svg = np.array(w['targetAttackSvg']).reshape(-1, 2)
    forward = explicit_warp(src_svg, dst_svg-src_svg,
                            np.array(w['triangles']).reshape(-1, 3))
    displayed = forward.apply(target[:, :, :2].reshape(-1, 2) @ matrix.T+origin)
    source = source.reshape(-1, 3)
    pairs, source_gaps, target_gaps = cross_family_pairs(source, displayed, families)
    groups = {}
    for i, (a, b) in enumerate(pairs):
        key = tuple(sorted([int(families[a]), int(families[b])]))
        row = groups.setdefault(key, dict(families=key, pairs=0,
            maximumSourceGapMeters=0., maximumMappedGapSvg=-1.))
        row['pairs'] += 1
        row['maximumSourceGapMeters'] = max(row['maximumSourceGapMeters'], float(source_gaps[i]))
        if target_gaps[i] > row['maximumMappedGapSvg']:
            row.update(maximumMappedGapSvg=float(target_gaps[i]),
                sourcePointsMeters=source[[a, b]].tolist(),
                mappedPointsSvg=displayed[[a, b]].tolist(),
                candidateFaces=ids[np.array([a, b])//3].astype(int).tolist(),
                controlParents=control_parents[np.array([a, b])//3].astype(int).tolist())
    report = dict(scope=__doc__, sourceToleranceMeters=1e-9,
        generatedVertexRecords=len(source), sharedCrossFamilyPairs=len(pairs),
        groups=sorted(groups.values(), key=lambda r: -r['maximumMappedGapSvg']),
        maximumMappedGapSvg=float(target_gaps.max(initial=0)),
        sourcePackSha256=hashlib.sha256(before_path.read_bytes()).hexdigest(),
        candidatePackSha256=hashlib.sha256(after_path.read_bytes()).hexdigest(),
        provenanceSha256=hashlib.sha256((candidate/'normalized-face-provenance.npz').read_bytes()).hexdigest(),
        warpSha256=hashlib.sha256(warp_path.read_bytes()).hexdigest(),
        scriptSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        acceptance='Diagnostic only. An empty pair set is not proof of closure.')
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: report[k] for k in [
        'generatedVertexRecords', 'sharedCrossFamilyPairs', 'maximumMappedGapSvg', 'groups']}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['candidate', 'warp', 'output']:
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    run(args.candidate, args.warp, args.output)
