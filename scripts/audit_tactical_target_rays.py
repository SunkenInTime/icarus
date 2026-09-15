"""Compare horizontal slices with straight eye-to-eye rays on native floors.

This is an offline diagnostic, not the product's flattening policy. It traces
3D triangles directly and reports both gains and losses from looking vertically.
"""
import argparse
import gzip
import heapq
import json
from pathlib import Path
import struct

import numpy as np

from world_visibility_ray_reference import ray_triangle, sample_alpha


class ReferenceModel:
    def __init__(self, path):
        self.raw = gzip.decompress(Path(path).read_bytes())
        magic, length = struct.unpack_from('<4sI', self.raw)
        if magic != b'IHD1':
            raise ValueError('Expected IHD1')
        self.header = json.loads(self.raw[8:8 + length])
        base = (8 + length + 7) // 8 * 8
        self.arrays = {
            key: np.frombuffer(self.raw, dtype=np.dtype(value['dtype']),
                               count=value['count'], offset=base + value['offset'])
                   .reshape(value['shape'])
            for key, value in self.header['arrays'].items()
        }
        self.textures = [np.frombuffer(self.raw, dtype=np.uint8,
                                      count=t['width'] * t['height'],
                                      offset=base + t['offset'])
                         .reshape(t['height'], t['width']) / 255.
                         for t in self.header['textures']]
        self.materials = {m['material']: m for m in self.header['materials']}

    def cast(self, origin, target, *, min_distance=1e-5, end_padding=1e-5, end_inclusive=False):
        """Return the nearest hit, including endpoints when their guard is zero.

        Piecewise rays must use zero padding at internal joins so a wall on a
        ground-cell edge is not omitted by both adjacent segments.
        """
        if not np.isfinite([min_distance, end_padding]).all() or min_distance < 0 or end_padding < 0:
            raise ValueError('Ray endpoint guards must be finite and nonnegative')
        origin, target = np.asarray(origin), np.asarray(target)
        delta = target - origin
        limit = float(np.linalg.norm(delta))
        if limit < 1e-6:
            return None
        direction = delta / limit
        end_limit = limit - end_padding
        def box(index):
            bounds = self.arrays['bounds'][index]
            low, high = 0., limit
            for axis in range(3):
                if abs(direction[axis]) < 1e-15:
                    if not bounds[axis] <= origin[axis] <= bounds[axis + 3]:
                        return None
                else:
                    a = (bounds[axis] - origin[axis]) / direction[axis]
                    b = (bounds[axis + 3] - origin[axis]) / direction[axis]
                    low, high = max(low, min(a, b)), min(high, max(a, b))
                    if high < low:
                        return None
            return low
        root = box(0)
        if root is None:
            return None
        pending = [(root, 0)]
        result = None
        while pending:
            distance, index = heapq.heappop(pending)
            if distance > limit:
                continue
            start, count, left, right = self.arrays['nodes'][index]
            if count == 0:
                for child in (left, right):
                    entry = box(child)
                    if entry is not None:
                        heapq.heappush(pending, (entry, int(child)))
                continue
            for face in range(start, start + count):
                triangle = self.arrays['vertices'][self.arrays['faces'][face]]
                hit = ray_triangle(origin, direction, triangle)
                if (hit is None or hit[0] < min_distance or hit[0] > end_limit
                        or (end_padding > 0 and not end_inclusive and hit[0] == end_limit)
                        or (result is not None and hit[0] >= limit)):
                    continue
                mask = self.arrays['faceMasks'][face]
                if mask >= 0:
                    material = self.materials[int(self.arrays['maskedMaterials'][mask])]
                    uv = np.asarray(hit[1]) @ self.arrays['maskedUvs'][mask]
                    if sample_alpha(self.textures[material['texture']], uv, material) < material['threshold']:
                        continue
                limit = hit[0]
                normal = np.cross(triangle[1] - triangle[0], triangle[2] - triangle[0])
                normal /= np.linalg.norm(normal)
                result = {'face': face, 'distanceMeters': limit,
                          'point': (origin + direction * limit).tolist(),
                          'normal': normal.tolist(), 'masked': bool(mask >= 0)}
        return result


def native_floor(nav, ui):
    mesh = nav['floorMesh']
    vertices = np.asarray(mesh['vertices'], dtype=float).reshape(-1, 3)
    uv = vertices[:, :2] / mesh['coordinateScale']
    vertices[:, 0] = (uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier'])
    vertices[:, 1] = -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])
    vertices[:, 2] /= 100
    indices = np.asarray(mesh['triangles']).reshape(-1, 4)
    valid = np.asarray(nav['walkable'])[indices[:, 0]]
    return vertices[indices[valid, 1:]].mean(axis=1)


def audit(root, name, samples, gallery=None):
    baseline = root / 'tactical-visibility-revision/baseline-world'
    if gallery:
        fixture = json.loads((gallery / f'{name}-fixtures.json').read_text())
        cases = [(c['id'], c['query']) for c in fixture['cases']]
        catalog = json.loads((baseline / 'height_catalog.json').read_text())
        ui = catalog['maps'][name]['uiTransform']
    else:
        fixture = json.loads((root / f'compact-prototype/native-walking-fixtures-v1/{name}/walking-144hz.json').read_text())
        cases = list(enumerate(fixture['frames'][0]['poses']))
        ui = fixture['projection']['uiTransform']
    model = ReferenceModel(baseline / f'{name}.height.bin.gz')
    nav = json.loads(gzip.decompress((baseline / f'{name}_navigation.json.gz').read_bytes()))
    targets = native_floor(nav, ui)
    targets[:, 2] += 1.75
    rng = np.random.default_rng(23471)
    rows = []
    checked = 0
    for agent, query in cases:
        origin = np.asarray(query[:3])
        delta = targets[:, :2] - origin[:2]
        distance = np.linalg.norm(delta, axis=1)
        angle = np.arccos(np.clip(delta @ query[3:5] / np.maximum(distance, 1e-8), -1, 1))
        indices = np.flatnonzero((distance > .25) & (distance < query[5]) & (angle < query[6] / 2))
        selected = rng.choice(indices, min(samples, len(indices)), replace=False)
        checked += len(selected)
        changed = 0
        for index in selected:
            target = targets[index]
            horizontal = target.copy(); horizontal[2] = origin[2]
            old = model.cast(origin, horizontal)
            pitched = model.cast(origin, target)
            if (old is None) != (pitched is None):
                changed += 1
                rows.append({'agent': agent, 'origin': origin.tolist(), 'target': target.tolist(),
                             'horizontalBlocked': old is not None, 'eyeToEyeBlocked': pitched is not None,
                             'horizontalHit': old, 'eyeToEyeHit': pitched})
        print(f'{name} agent {agent}: {len(selected)} targets, {changed} changed', flush=True)
    report = {'map': name, 'scope': 'Independent straight 3D triangle rays; tactical flattening not certified.',
              'targetPairs': checked,
              'gainedVisibility': sum(r['horizontalBlocked'] for r in rows),
              'lostVisibility': sum(r['eyeToEyeBlocked'] for r in rows), 'differences': rows}
    suffix = '-gallery' if gallery else ''
    output = root / f'tactical-visibility-revision/{name}{suffix}-eye-target-diagnostic.json'
    output.write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--map', default='split')
    parser.add_argument('--samples', type=int, default=40)
    parser.add_argument('--gallery', type=Path)
    args = parser.parse_args()
    if args.map == 'all':
        if args.gallery is None:
            parser.error('--map all requires --gallery')
        names = sorted(p.name.removesuffix('-fixtures.json') for p in args.gallery.glob('*-fixtures.json'))
    else:
        names = [args.map]
    for name in names:
        audit(args.root, name, args.samples, args.gallery)
