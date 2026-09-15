"""Register Pearl's vertical A arch planes without filling its opening."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from tactical_alignment_composite import explicit_warp


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    evidence = args.audit_root / 'tactical-visibility-revision/gallery-pearl-edge36-probe-v1/source-horizontal-rays.json'
    source = json.loads(evidence.read_text())
    hits = [source['cases'][i]['sourceHorizontalHit'] for i in [0, 2, 3]]
    if any('ASiteArchC/' not in hit['sourceObject'] for hit in hits):
        raise ValueError('Unexpected source facade')
    target_x = source['targetLineSvg'][0][0]
    top_offset = target_x - hits[0]['hitSvg'][0]
    lower_offset = target_x - hits[1]['hitSvg'][0]
    if abs(lower_offset - (target_x - hits[2]['hitSvg'][0])) > 1e-8:
        raise ValueError('Lower arch contacts disagree')
    ys = np.unique(np.r_[112.156, 113.5, 116, 122, 129, 159.286, 162,
                         [hit['hitSvg'][1] for hit in hits], np.arange(114, 161, 2)])
    points, delta, triangles = [], [], []
    for y in ys:
        d = np.interp(y, [112.156, 113.5, 116, 122, 129, 159.286, 162],
                      [0, 0, top_offset, top_offset, lower_offset, lower_offset, 0])
        for x in [434, target_x - d, 447]:
            points.append([x, y])
            delta.append([d, 0] if x == target_x - d else [0, 0])
    # An explicit strip topology keeps consecutive source profile points from
    # becoming one triangle that collapses when its target is a straight line.
    for row in range(len(ys) - 1):
        for column in range(2):
            a = row * 3 + column
            triangles.extend([[a, a + 1, a + 3], [a + 1, a + 4, a + 3]])
    warp = explicit_warp(points, delta, triangles)
    if warp.jacobians.min() <= .5 or warp.jacobians.max() >= 2:
        raise ValueError('Arch warp folds or exceeds the local deformation bound')
    args.output.mkdir(parents=True, exist_ok=False)
    np.savez_compressed(args.output / 'warp.npz', points=warp.points,
                        displacements=warp.delta, triangles=warp.tri.simplices,
                        explicitTriangles=np.array([1]))
    report = {'map': 'pearl', 'svgLineId': 36, 'adopted': False,
              'sourceEvidence': str(evidence), 'sourceEvidenceSha256': hashlib.sha256(evidence.read_bytes()).hexdigest(),
              'minimumCellJacobian': float(warp.jacobians.min()),
              'maximumCellJacobian': float(warp.jacobians.max()),
              'limits': ['Compose after the audited diagonal correction.',
                         'Y113.5 top guard preserves the diagonal corner.',
                         'No new faces are added; the source opening remains open.',
                         'Foreground ruins at X432.73 remain outside the fixed X434 guard.',
                         'Source-ray and rendered endpoint verification required before adoption.']}
    (args.output / 'candidate.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
