"""Subdivide authored cubic edges using a control-hull distance bound.

The bound applies to the curve and chord as geometric sets. A capsule around
the chord is convex, so it contains the full Bezier control hull and curve.
Every chord projection is reached by the continuous curve between its ends.
This is tessellation error only, never an allowed wall-registration gap.
"""
import numpy as np


def chord_bound(controls):
    controls = np.asarray(controls, dtype=float)
    delta = controls[-1] - controls[0]
    length_squared = delta @ delta
    if length_squared == 0:
        return float(np.linalg.norm(controls-controls[0], axis=1).max())
    t = np.clip((controls-controls[0]) @ delta / length_squared, 0, 1)
    return float(np.linalg.norm(controls-(controls[0]+t[:, None]*delta), axis=1).max())


def split_half(controls):
    a = (controls[:-1] + controls[1:]) / 2
    b = (a[:-1] + a[1:]) / 2
    center = (b[0] + b[1]) / 2
    return np.array([controls[0], a[0], b[0], center]), np.array([center, b[1], a[2], controls[3]])


def cubic_segments(controls, max_error_svg=1e-5):
    controls = np.asarray(controls, dtype=float)
    if controls.shape != (4, 2) or not np.isfinite(controls).all():
        raise ValueError('Expected four finite cubic control points')
    if not np.isfinite(max_error_svg) or max_error_svg <= 0:
        raise ValueError('Tessellation error must be positive')
    pending = [(controls, 0., 1., 0)]
    result = []
    while pending:
        points, start, end, depth = pending.pop()
        bound = chord_bound(points)
        if bound <= max_error_svg:
            result.append(dict(t0=start, t1=end, controls=points.tolist(),
                               startSvg=points[0].tolist(), endSvg=points[-1].tolist(),
                               controlHullDistanceBoundSvg=bound))
            continue
        if depth >= 30:
            raise ValueError('Could not meet curve tessellation bound')
        left, right = split_half(points)
        middle = (start+end)/2
        pending.extend([(right, middle, end, depth+1), (left, start, middle, depth+1)])
    return result
