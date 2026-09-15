"""Diagnostic convex floor edge index. Never writes application assets.

An observer sees one exit edge of a convex polygon from inside, or an entry
and exit edge from outside. Vertex directions partition those edge choices.
The query retains the original half-plane arithmetic on the selected edges.
Uncertain angular boundaries fall back to every edge. This experiment does
not establish floating-point equivalence for arbitrary inputs or change the
floor policy; the recorded differential checks determine its bounded result.
"""
import argparse
import bisect
import hashlib
import json
import math
from pathlib import Path
import numpy as np

TAU = 2 * math.pi


def cross(a, b):
    return float(a[0] * b[1] - a[1] * b[0])


class SectorIndex:
    def __init__(self, polygon, origin):
        self.polygon = np.asarray(polygon, dtype=float)
        self.origin = np.asarray(origin, dtype=float)
        self.edges = np.roll(self.polygon, -1, axis=0) - self.polygon
        sign = 1 if sum(cross(a, b) for a, b in zip(
            self.polygon, np.roll(self.polygon, -1, axis=0))) >= 0 else -1
        self.sign = sign
        self.values = [sign * cross(e, self.origin-a)
                       for a, e in zip(self.polygon, self.edges)]
        self.angles = []
        self.sectors = []
        n = len(self.polygon)
        if n < 8:
            return
        rays = self.polygon - self.origin
        scale = max(1., float(np.max(np.abs(self.polygon))),
                    float(np.max(np.abs(self.origin))))
        # Disable indexing for observer/edge coincidences and nonconvex inputs.
        uncertainty = 128 * np.finfo(float).eps * scale * scale
        if any(abs(v) <= uncertainty for v in self.values):
            return
        if any(sign * cross(self.edges[i], self.edges[(i+1) % n]) < -uncertainty
               for i in range(n)):
            return
        angles = [math.atan2(v[1], v[0]) % TAU for v in rays]
        self.angles = sorted(set(angles))
        starts = {a: set() for a in self.angles}
        ends = {a: set() for a in self.angles}
        arcs = []
        for i in range(n):
            a, b = angles[i], angles[(i+1) % n]
            if cross(rays[i], rays[(i+1) % n]) < 0:
                a, b = b, a
            if a == b:
                self.angles = []
                return
            starts[a].add(i)
            ends[b].add(i)
            arcs.append((a, b))
        first_mid = (self.angles[0] + self.angles[1]) / 2
        active = {i for i, (a, b) in enumerate(arcs)
                  if (first_mid-a) % TAU < (b-a) % TAU}
        self.sectors.append(tuple(sorted(active)))
        for a in self.angles[1:]:
            active.difference_update(ends[a])
            active.update(starts[a])
            self.sectors.append(tuple(sorted(active)))
        if any(len(s) > 2 for s in self.sectors):
            self.angles = []
            self.sectors = []

    def clip(self, direction, indexed=False):
        chosen = range(len(self.edges))
        used_index = False
        if indexed and self.angles:
            angle = math.atan2(direction[1], direction[0]) % TAU
            sector = (bisect.bisect_right(self.angles, angle)-1) % len(self.angles)
            lo = self.angles[sector]
            hi = self.angles[(sector+1) % len(self.angles)]
            # Query exact vertex directions with ordinary clipping. This is a
            # numerical fallback, never a change to geometry or an acceptance
            # tolerance for output distance.
            if min((angle-lo) % TAU, (hi-angle) % TAU) > 1e-12:
                chosen = self.sectors[sector]
                used_index = True
                if not chosen:
                    return None, used_index, 0
        low, high, tested = 0., 1., 0
        for i in chosen:
            tested += 1
            slope = self.sign * cross(self.edges[i], direction)
            value = self.values[i]
            if abs(slope) < 1e-14:
                if value < 0:
                    return None, used_index, tested
            elif slope > 0:
                low = max(low, -value/slope)
            else:
                high = min(high, -value/slope)
            if high < low:
                return None, used_index, tested
        return (low, high), used_index, tested


def run(atlas_path, frozen_path, output):
    atlas = np.load(atlas_path)
    frozen = json.loads(frozen_path.read_text())
    rng = np.random.default_rng(983172)
    failures, queries, indexed, ordinary_edges, indexed_edges = [], 0, 0, 0, 0
    positive, max_error = 0, 0.
    origins = [np.array(r['origin'][:2]) for r in frozen['records']]
    for origin_index, origin in enumerate(origins):
        for cell, (first, size) in enumerate(atlas['polygonRanges']):
            if size < 8:
                continue
            polygon = atlas['polygons'][first:first+size]
            index = SectorIndex(polygon, origin)
            center = np.mean(polygon, axis=0) - origin
            theta = math.atan2(center[1], center[0])
            # Full-circle, toward-cell, vertex, and adjacent-direction probes.
            angles = list(rng.uniform(0, TAU, 12)) + [theta]
            vertices = polygon[[0, size//2, size-1]] - origin
            for v in vertices:
                a = math.atan2(v[1], v[0])
                angles.extend(a+d for d in [0, -1e-13, 1e-13, -1e-9, 1e-9])
            for angle in angles:
                direction = np.array([math.cos(angle), math.sin(angle)]) * 150
                expected, _, before = index.clip(direction)
                actual, fast, after = index.clip(direction, True)
                queries += 1
                indexed += int(fast)
                ordinary_edges += before
                indexed_edges += after
                positive += expected is not None
                error = 0 if expected is None or actual is None else max(
                    abs(expected[i]-actual[i]) * 150 for i in range(2))
                max_error = max(max_error, error)
                if ((expected is None) != (actual is None) or error != 0):
                    failures.append(dict(originIndex=origin_index, cell=cell,
                        angle=angle, expected=expected, actual=actual,
                        indexed=fast, errorMeters=error))
        print(f'Origin {origin_index}: {queries} queries, {len(failures)} differences', flush=True)
    report = dict(queries=queries, positiveIntervals=positive, indexedQueries=indexed,
        ordinaryEdgesTested=ordinary_edges, indexedEdgesTested=indexed_edges,
        edgeReductionFraction=1-indexed_edges/ordinary_edges,
        maxEndpointErrorMeters=max_error, failures=failures,
        atlasSha256=hashlib.sha256(atlas_path.read_bytes()).hexdigest(),
        scriptSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        scope='Convex floor clipping only, 8 frozen Split observers. No full cone or timing claim.',
        limitation='Python sector selection prototype. Numerical guards need native verification before runtime use.')
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'failures'}), flush=True)
    assert not failures, f'{len(failures)} interval differences; see {output}'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('atlas', type=Path)
    parser.add_argument('frozen', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    run(args.atlas, args.frozen, args.output)
