"""Compare a bounded native floor atlas against independent source-backed rays."""
import argparse
import ctypes
import json
import time
from pathlib import Path
import numpy as np
from probe_source_floor_regressions import load_support, source_model
from source_floor_piece_cast import cast_floor_piece


class NativeAtlas:
    def __init__(self, revision, source=None, transit=False):
        data = np.load(revision / 'local-floor-atlas-v1' / ('split-with-transit.npz' if transit else 'split.npz'))
        self.arrays = {key: np.ascontiguousarray(data[key]) for key in data.files}
        self.arrays['sourceFaces'] = np.ascontiguousarray(data['sourceFaces'], dtype=np.int64)
        self.arrays['terrain'] = np.zeros(len(data['sourceFaces']), dtype=np.uint8)
        if not transit:
            self.arrays.update(transitPolygons=np.empty((0,2)), transitRanges=np.empty((0,2),dtype=np.int32),
                               transitGroups=np.empty(0,dtype=np.int32),transitSheets=np.empty(0,dtype=np.int32),
                               transitCellGroups=np.full(len(data['sourceFaces']),-1,dtype=np.int32),
                               transitAdjacency=np.empty((0,0),dtype=np.uint8))
        if source is None:
            source = source_model(revision, 'split', True)
        points = source.arrays['vertices'][source.arrays['faces'][data['segmentFaces']]]
        self.arrays['endpointTolerance'] = np.ascontiguousarray(np.linalg.norm(points[:, :, :2].max(1)-points[:, :, :2].min(1), axis=1)*3e-7+1e-10)
        self.dll = ctypes.CDLL(str(revision / 'native-tactical-rays-build/Release/tactical_floor_atlas.dll'))
        self.fn = self.dll.cast_floor_atlas
        self.fn.argtypes = [ctypes.c_int, ctypes.c_int] + [ctypes.c_void_p] * 23 + [ctypes.c_double, ctypes.c_double, ctypes.c_void_p, ctypes.c_int]
        self.fn.restype = ctypes.c_int
        self.buffer = np.zeros((10000, 8), dtype=float)

    def cast(self, source, origin, direction, distance):
        origin, direction = np.asarray(origin, dtype=float), np.asarray(direction, dtype=float)
        keys = ['polygons', 'polygonRanges', 'planes', 'originalTriangles', 'sourceFaces', 'terrain', 'segments', 'segmentRanges', 'segmentFaces', 'segmentEndpointClosed', 'endpointTolerance', 'fallback', 'bvhBounds', 'bvhNodes', 'bvhCells', 'transitPolygons', 'transitRanges', 'transitGroups', 'transitSheets', 'transitCellGroups', 'transitAdjacency']
        pointers = [self.arrays[key].ctypes.data for key in keys] + [origin.ctypes.data, direction.ctypes.data]
        native_begin = time.perf_counter()
        count = self.fn(len(self.arrays['planes']), len(self.arrays['transitRanges']), *pointers, distance, .35, self.buffer.ctypes.data, len(self.buffer))
        native_seconds = time.perf_counter() - native_begin
        if count < 0:
            raise RuntimeError('Native atlas piece capacity exceeded')
        rows = self.buffer[:count].copy()
        best = distance
        hit_face = None
        fallbacks = 0
        for lo, hi, ground0, ground1, cell, hit, face, fallback in rows:
            if hit < best:
                best, hit_face = hit, int(face)
            if fallback:
                fallbacks += 1
                plane = self.arrays['planes'][int(cell)] if cell >= 0 else np.array([0., 0., ground0])
                source_hit = cast_floor_piece(source, origin[:2], direction, distance, plane, lo, hi)
                if source_hit:
                    value = (np.array(source_hit['point'][:2]) - origin[:2]) @ direction
                    if value < best:
                        best, hit_face = value, source_hit.get('face', -999)
            if best < hi:
                break
        return dict(distanceMeters=float(best), face=hit_face, fallbacks=fallbacks, rows=rows, nativeSeconds=native_seconds,
                    transitPieces=int(np.sum(rows[:,6] == -2)))


def run(revision, rays):
    source = source_model(revision, 'split', True)
    support = load_support(revision, 'split', True)
    atlas = NativeAtlas(revision, source)
    rng = np.random.default_rng(918264)
    center = np.array([20.599371111492427, 39.59257844288108, 6.781631480113873])
    failures, errors, timings, fallback_counts, native_timings, row_counts = [], [], [], [], [], []
    blocked = clear = 0
    for i in range(rays):
        origin = center + np.r_[rng.uniform(-.1, .1, 2), 0]
        angle = rng.uniform(0, 2 * np.pi)
        direction = np.array([np.cos(angle), np.sin(angle)])
        distance = 5.
        expected = support.cast(source, origin, direction, distance, True, True, True, .35, True)
        begin = time.perf_counter()
        actual = atlas.cast(source, origin, direction, distance)
        timings.append(time.perf_counter() - begin)
        error = abs(actual['distanceMeters'] - expected['distanceMeters'])
        errors.append(error)
        fallback_counts.append(actual['fallbacks'])
        native_timings.append(actual['nativeSeconds'])
        row_counts.append(len(actual['rows']))
        blocked += expected['hit'] is not None
        clear += expected['hit'] is None
        if error > 1e-5 or (actual['face'] is None) != (expected['hit'] is None):
            failures.append(dict(origin=origin.tolist(), direction=direction.tolist(), errorMeters=error,
                                 actual={**actual, 'rows': actual['rows'].tolist()}, expected=expected))
        if i % 100 == 0:
            print(i, 'rays', len(failures), 'failures', flush=True)
    result = dict(scope=__doc__, rays=rays, blocked=blocked, clear=clear, failures=failures,
                  maxDistanceErrorMeters=max(errors), sourceFallbackCalls=sum(fallback_counts),
                  sourceFallbackRays=sum(c > 0 for c in fallback_counts),
                  nativeOnlyMilliseconds={label: float(np.quantile(native_timings, q) * 1000) for label, q in [('p50', .5), ('p95', .95), ('p99', .99)]},
                  maximumPieces=max(row_counts), meanPieces=float(np.mean(row_counts)),
                  nativePlusFallbackMilliseconds={label: float(np.quantile(timings, q) * 1000) for label, q in [('p50', .5), ('p95', .95), ('p99', .99)]},
                  limitation='Local arbitrary-ray proof only. No final cone mesh, angular event completeness, all-map floor roles, or production performance claim.')
    (revision / 'local-floor-atlas-v1/split-verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: value if key != 'failures' else len(value) for key, value in result.items()}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('--rays', type=int, default=1000)
    args = parser.parse_args()
    run(args.revision, args.rays)
