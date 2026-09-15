"""Offline alpha-test intervals along an affine UV section.

Bilinear alpha along a line is quadratic within each texture cell. Split at
cell boundaries and solve threshold crossings, retaining opaque intervals.
This matches the frozen sampler policy, not arbitrary animated game shaders.
"""
import math
from dataclasses import dataclass
import numpy as np

from world_visibility_ray_reference import sample_alpha


@dataclass(frozen=True)
class AlphaSection:
    # Intervals describe positive-length interiors. Knots preserve threshold
    # tangencies and discontinuous border samples that closed segments cannot.
    intervals: np.ndarray
    knots: np.ndarray
    knot_opacity: np.ndarray

    def contains(self, t):
        if not math.isfinite(t) or not 0 <= t <= 1:
            return False
        index = int(np.searchsorted(self.knots, t))
        if index < len(self.knots) and self.knots[index] == t:
            return bool(self.knot_opacity[index])
        index = int(np.searchsorted(self.intervals[:, 1], t))
        return bool(index < len(self.intervals) and self.intervals[index, 0] <= t <= self.intervals[index, 1])

    def pieces(self):
        """Return parameter intervals and explicit endpoint inclusion flags.

        A repeated endpoint is an isolated opaque sample. Transparent knots
        split otherwise opaque intervals so neither adjoining segment owns it.
        """
        pieces, closed = [], []
        for left, right in self.intervals:
            cuts = np.r_[left, self.knots[(self.knots > left) & (self.knots < right)], right]
            for start, finish in zip(cuts[:-1], cuts[1:]):
                pieces.append([start, finish])
                closed.append([self.contains(start), self.contains(finish)])
        for knot, opaque in zip(self.knots, self.knot_opacity):
            if opaque and not np.any((self.intervals[:, 0] <= knot) & (knot <= self.intervals[:, 1])):
                pieces.append([knot, knot])
                closed.append([True, True])
        return np.array(pieces, dtype=float).reshape(-1, 2), np.array(closed, dtype=np.uint8).reshape(-1, 2)


def build_alpha_section(alpha, uv0, uv1, policy, *, maximum_cells=1000000):
    uv0, uv1 = np.asarray(uv0, dtype=float), np.asarray(uv1, dtype=float)
    if uv0.shape != (2,) or uv1.shape != (2,) or not np.isfinite([uv0, uv1]).all():
        raise ValueError('Expected finite UV endpoints')
    delta = uv1 - uv0
    events = [0., 1.]
    for axis, size, mode in [(0, alpha.shape[1], policy['wrapS']),
                             (1, alpha.shape[0], policy['wrapT'])]:
        if delta[axis] == 0:
            continue
        begin, end = uv0[axis] * size - .5, uv1[axis] * size - .5
        low, high = sorted((begin, end))
        first, last = math.ceil(low), math.floor(high)
        if last - first > maximum_cells:
            raise ValueError('Alpha section exceeds offline cell budget')
        events.extend((np.arange(first, last + 1) - begin) / (end - begin))
        if mode == 'black':
            events.extend((boundary - uv0[axis]) / delta[axis] for boundary in (0., 1.))
    events = np.unique(np.clip(events, 0, 1))
    intervals = []
    knots = list(events)
    threshold = policy['threshold']
    for left, right in zip(events[:-1], events[1:]):
        if right <= left:
            continue
        # Interior samples avoid a black-border discontinuity exactly at an
        # endpoint. In local q coordinates the polynomial is A*q*q+B*q+C.
        values = [sample_alpha(alpha, uv0 + (left + q * (right - left)) * delta, policy)
                  - threshold for q in (.25, .5, .75)]
        a = 8 * (values[0] - 2 * values[1] + values[2])
        b = 2 * (values[2] - values[0]) - a
        c = values[1] - .25 * a - .5 * b
        cuts = [0., 1.]
        if abs(a) < 1e-13:
            if abs(b) > 1e-13:
                cuts.append(-c / b)
        else:
            discriminant = b * b - 4 * a * c
            if discriminant >= 0:
                root = math.sqrt(discriminant)
                stable = -.5 * (b + math.copysign(root, b))
                if stable:
                    cuts.extend((stable / a, c / stable))
                else:
                    cuts.append(-b / (2 * a))
        cuts = np.unique(np.clip(cuts, 0, 1))
        knots.extend(left if q == 0 else right if q == 1 else left + q * (right - left) for q in cuts)
        for start, finish in zip(cuts[:-1], cuts[1:]):
            q = (start + finish) / 2
            if a * q * q + b * q + c >= 0:
                lo = left if start == 0 else left + start * (right - left)
                hi = right if finish == 1 else left + finish * (right - left)
                if intervals and lo == intervals[-1][1]:
                    intervals[-1][1] = hi
                else:
                    intervals.append([lo, hi])
    intervals = np.array(intervals, dtype=float).reshape(-1, 2)
    retained_knots, opacity = [], []
    for knot in np.unique(knots):
        left_index = int(np.searchsorted(intervals[:, 1], knot, side='left'))
        right_index = int(np.searchsorted(intervals[:, 1], knot, side='right'))
        left_state = left_index < len(intervals) and intervals[left_index, 0] < knot
        right_state = right_index < len(intervals) and intervals[right_index, 0] <= knot
        state = sample_alpha(alpha, uv0 + knot * delta, policy) >= threshold
        if state != left_state or state != right_state:
            retained_knots.append(knot); opacity.append(state)
    return AlphaSection(intervals, np.array(retained_knots), np.array(opacity, dtype=bool))


def opaque_intervals(alpha, uv0, uv1, policy, *, maximum_cells=1000000):
    """Positive-length pieces only; use build_alpha_section for event points."""
    return build_alpha_section(alpha, uv0, uv1, policy, maximum_cells=maximum_cells).intervals


def masked_section_segments(alpha, endpoints, uvs, policy):
    intervals = opaque_intervals(alpha, *uvs, policy)
    endpoints = np.asarray(endpoints)
    return endpoints[0] + intervals[:, :, None] * (endpoints[1] - endpoints[0])


def masked_section_events(alpha, endpoints, uvs, policy):
    """Preserve alpha event samples in ordinary, open-ended, and point sections."""
    intervals, closed = build_alpha_section(alpha, *uvs, policy).pieces()
    endpoints = np.asarray(endpoints, dtype=float)
    segments = endpoints[0] + intervals[:, :, None] * (endpoints[1] - endpoints[0])
    return segments, closed
