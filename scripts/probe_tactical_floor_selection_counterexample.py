"""A synthetic uphill counterexample for the experimental floor follower.

The ground plane continues under a solid ramp. Main navigation follows the
ramp. A tactical flattening must reach the far wall without selecting the buried
base floor. This tool records failure without accepting the candidate policy.
"""
import argparse
import json
from pathlib import Path
import numpy as np
import shapely
from probe_source_floor_support import SourceSupport


class RampAndWall:
    def cast(self, start, end, min_distance=1e-5, end_padding=1e-5):
        start, end = np.asarray(start), np.asarray(end)
        vector = end - start
        length = np.linalg.norm(vector)
        hits = []
        for normal, constant, kind in [(np.array([-.5, 0., 1.]), 0., 'ramp'),
                                        (np.array([1., 0., 0.]), 6., 'wall')]:
            denominator = normal @ vector
            if abs(denominator) < 1e-12:
                continue
            factor = (constant - normal @ start) / denominator
            distance = factor * length
            if distance < min_distance or distance > length - end_padding:
                continue
            point = start + factor * vector
            if not 0 <= point[1] <= 2:
                continue
            if kind == 'ramp' and not 0 <= point[0] <= 4:
                continue
            if kind == 'wall' and not 2 <= point[2] <= 5:
                continue
            hits.append(dict(point=point.tolist(), object=kind,
                             normal=(normal / np.linalg.norm(normal)).tolist(),
                             distanceMeters=float(distance)))
        return min(hits, key=lambda row: row['distanceMeters']) if hits else None


def probe():
    points = []
    for x0, x1, slope, intercept in [(-2, 6, 0, 0), (0, 4, .5, 0), (4, 6, 0, 2)]:
        corners = np.array([[x0, 0], [x1, 0], [x1, 2], [x0, 2]], dtype=float)
        vertices = np.c_[corners, corners[:, 0] * slope + intercept]
        points.extend([vertices[[0, 1, 2]], vertices[[0, 2, 3]]])
    support = SourceSupport.__new__(SourceSupport)
    support.points = np.array(points)
    support.source_ids = np.arange(len(points))
    support.objects = ['buried base', 'buried base', 'ramp', 'ramp', 'upper floor', 'upper floor']
    support.planes = np.linalg.solve(
        np.concatenate([support.points[:, :, :2], np.ones((len(points), 3, 1))], axis=2),
        support.points[:, :, 2, None])[:, :, 0]
    support.polygons = shapely.polygons(support.points[:, :, :2])
    support.tree = shapely.STRtree(support.polygons)
    origin = [-1., 1., 1.75]
    observed = support.cast(RampAndWall(), origin, [1., 0.], 8., allow_floor_transitions=True)
    return dict(scope=__doc__, expectedBlocker='wall', expectedDistanceMeters=7.,
                actual=observed, passed=observed['hit']['object'] == 'wall',
                navigationGround='z=0 before x=0; z=x/2 on ramp 0..4; z=2 beyond x=4. No navigation below the ramp.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    result = probe()
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(passed=result['passed'], expected=result['expectedDistanceMeters'],
                          actual=result['actual']['distanceMeters'], blocker=result['actual']['hit']['object'])))
