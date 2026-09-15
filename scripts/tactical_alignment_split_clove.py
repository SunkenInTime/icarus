"""Add the audited Split vent doorway correspondence without flattening its pipe."""
import argparse
import json
from pathlib import Path

import numpy as np

from tactical_alignment_candidate import Warp, plateau
from tactical_alignment_warps import from_controls


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(args.output)
    old = Warp()
    xs = np.unique(np.r_[np.arange(208, 247, 2), 210, 214, 221, 225, 220.87977448701395, 234.12715823427257])
    ys = np.unique(np.r_[199, 202, 204, 207, np.arange(210, 214.1, .5), 212.64363698566504, 212.7, 213.7, 215, 216])
    patch_points = np.array([(x, y) for x in xs for y in ys])
    x, y = patch_points.T
    dx = np.interp(x, [214, 220.87977448701395, 234.12715823427257, 244],
                   [0, 222.445 - 220.87977448701395, 236.012 - 234.12715823427257, 0])
    dy = (211.513 - 212.64363698566504) * plateau(x, [210, 214, 221, 225]) * plateau(y, [207, 210, 212.7, 215])
    patch_delta = np.column_stack((dx * plateau(y, [202, 204, 212.7, 213.7]), dy))
    warp = from_controls(np.vstack((old.points, patch_points)),
                         np.vstack((np.zeros_like(old.delta), patch_delta)))
    samples = old.points[old.tri.simplices].mean(1)
    outside = (samples[:, 0] < 208) | (samples[:, 0] > 246) | (samples[:, 1] < 199) | (samples[:, 1] > 216)
    change = float(np.linalg.norm(warp.apply(samples[outside]) - samples[outside], axis=1).max())
    pipe_points = np.array([[236.68958783, 213.72607279], [238.92997158, 215.96645654]])
    pipe_shift = float(np.linalg.norm(warp.apply(pipe_points) - pipe_points, axis=1).max())
    if warp.jacobians.min() <= .5 or change > 1e-8 or pipe_shift > 1e-8:
        raise ValueError(f'Clove warp failed: jac={warp.jacobians.min()}, outside={change}, pipe={pipe_shift}')
    args.output.mkdir(parents=True)
    np.savez_compressed(args.output / 'warp.npz', points=warp.points, displacements=warp.delta, triangles=warp.tri.simplices)
    report = {'map': 'split', 'adopted': False, 'prior': 'Compose AFTER the manual Deadlock + Iso warp, preserving its exact tessellation; do not apply this alone to unwarped source',
              'newConstraints': ['Vent frame left walkable edge220.879774487→SVG222.445', 'Vent frame right walkable edge234.127158234→SVG236.012', 'Left doorway front lipY212.643636986→SVG211.513'],
              'heightScopeSvg': [204, 212.7], 'unchangedRoundedPipeBeginsSvgY': 213.72607279,
              'minimumCellJacobian': float(warp.jacobians.min()), 'maximumCellJacobian': float(warp.jacobians.max()),
              'maximumPriorOutsideCellCentroidChangeSvg': change, 'pipeControlPointShiftSvg': pipe_shift,
              'maximumControlDisplacementSvg': float(np.linalg.norm(warp.delta, axis=1).max()),
              'limitations': ['Static door-frame profile retained. Authored curve/pipe correspondence below213.7 remains separately auditable.', 'Re-run all annotated scene and bounded corner tests before adoption.']}
    (args.output / 'candidate.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
