"""Find mapped wall vertices separated from retained source attachment vertices.

This is a diagnostic of shared source vertices, including retained outside
fragments. It does not infer whether an attachment is structural, check arbitrary
edge intersections, or certify a whole contour. No mapped-gap tolerance is used.
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


def neighbor_pairs(moved_source, retained_source, tolerance=1e-9):
    """Match original XYZ, so separate heights are never joined by their XY."""
    neighbors = cKDTree(moved_source).query_ball_point(retained_source, tolerance)
    return np.array([(a, b) for b, rows in enumerate(neighbors) for a in rows],
                    dtype=np.int64).reshape(-1, 2)


def run(candidate, warp_path, output):
    if output.exists():
        raise FileExistsError(output)
    bindings = json.loads((candidate / 'bindings.json').read_text())
    before_path = Path(bindings['sourceBackup'])
    after_path = candidate / (bindings.get('map', 'split') + '.height.bin.gz')
    _, before = pack(before_path)
    _, after = pack(after_path)
    provenance_path = candidate / 'normalized-face-provenance.npz'
    proof = np.load(provenance_path)
    parents = np.load(candidate / 'correspondence.npz')['sourceFaces']
    ids = proof['generatedFaceIds']
    original = before['vertices'][before['faces'][parents[ids]]]
    source = original[:, :1] + np.einsum('nij,njk->nik',
        proof['generatedBarycentrics'][:, :, 1:], original[:, 1:] - original[:, :1])
    changed = proof['generatedEdges'] >= 0
    moved_source = source[changed].reshape(-1, 3)
    moved_faces = np.repeat(ids[changed], 3)
    families = np.repeat(proof['generatedEdges'][changed], 3)
    moved_target = after['vertices'][after['faces'][ids[changed]]].reshape(-1, 3)
    tree = cKDTree(moved_source)
    untouched = np.ones(len(after['faces']), dtype=bool)
    untouched[ids] = False
    untouched_ids = np.flatnonzero(untouched)
    outside_ids = ids[~changed]
    w = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((w['projection']['axisU'], w['projection']['axisV']))
    origin = np.array(w['projection']['origin'])
    src_svg = np.array(w['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    dst_svg = np.array(w['targetAttackSvg']).reshape(-1, 2)
    forward = explicit_warp(src_svg, dst_svg - src_svg,
                            np.array(w['triangles']).reshape(-1, 3))
    display_moved = forward.apply(moved_target[:, :2] @ matrix.T + origin)
    groups = {}
    pair_count = 0

    def inspect(face_ids, reference, role):
        nonlocal pair_count
        for start in range(0, len(face_ids), 50000):
            chunk_ids = face_ids[start:start + 50000]
            points = reference(start, len(chunk_ids)).reshape(-1, 3)
            neighbors = tree.query_ball_point(points, 1e-9)
            matches = [(a, b) for b, rows in enumerate(neighbors) for a in rows]
            if not matches:
                continue
            pairs = np.array(matches, dtype=np.int64)
            retained_faces = chunk_ids[pairs[:, 1] // 3]
            retained_vertices = after['vertices'][after['faces'][retained_faces,
                                                pairs[:, 1] % 3]]
            displayed = forward.apply(retained_vertices[:, :2] @ matrix.T + origin)
            gaps = np.linalg.norm(display_moved[pairs[:, 0]] - displayed, axis=1)
            pair_count += len(pairs)
            for i, (a, b) in enumerate(pairs):
                # Keep separate parents so one large gap cannot hide another
                # attachment on the same wall family.
                key = (int(families[a]), int(parents[retained_faces[i]]), role)
                row = groups.setdefault(key, dict(family=key[0],
                    retainedControlParent=key[1], retainedRole=role,
                    sharedVertexPairs=0, maximumMappedGapSvg=-1.))
                row['sharedVertexPairs'] += 1
                if gaps[i] > row['maximumMappedGapSvg']:
                    row.update(maximumMappedGapSvg=float(gaps[i]),
                        sourceGapMeters=float(np.linalg.norm(moved_source[a] - points[b])),
                        sourcePointMeters=moved_source[a].tolist(),
                        mappedPointsSvg=[display_moved[a].tolist(), displayed[i].tolist()],
                        candidateFaces=[int(moved_faces[a]), int(retained_faces[i])],
                        movedControlParent=int(parents[moved_faces[a]]))

    inspect(untouched_ids, lambda start, count: before['vertices'][before['faces'][
        parents[untouched_ids[start:start + count]]]], 'unchanged-face')
    outside_source = source[~changed]
    inspect(outside_ids, lambda start, count: outside_source[start:start + count],
            'retained-outside-fragment')
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    report = dict(scope=__doc__, sourceToleranceMeters=1e-9,
        movedVertexRecords=len(moved_source), unchangedFaces=len(untouched_ids),
        retainedOutsideFragments=len(outside_ids), sharedVertexPairs=pair_count,
        groups=sorted(groups.values(), key=lambda r: -r['maximumMappedGapSvg']),
        sourcePackSha256=digest(before_path), candidatePackSha256=digest(after_path),
        provenanceSha256=digest(provenance_path), warpSha256=digest(warp_path),
        scriptSha256=digest(Path(__file__)),
        acceptance='Diagnostic only. Source ownership and visual review are still required.')
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(sharedVertexPairs=pair_count, groups=len(groups),
                         largest=report['groups'][:5])), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['candidate', 'warp', 'output']:
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    run(args.candidate, args.warp, args.output)
