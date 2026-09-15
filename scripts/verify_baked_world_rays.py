"""Compare baked 2D sections with held-out, material-aware 3D reference rays."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import shapely

from world_visibility_binary import decode_world


class PlaneSource:
    """Read one exact plane at a time without materializing the entire map."""
    def __init__(self, path):
        self.path = Path(path)
        self.content = self.path.read_bytes()
        self.data = json.loads(gzip.decompress(self.content) if self.content[:2] == b'\x1f\x8b' else self.content)
        self.last_chunk = None
        self.chunk = None

    def segments(self, index):
        layer = self.data['layers'][index]
        units = np.asarray(self.data['uvUnitsPerMeter'])
        scale = self.data['coordinateScale']
        if self.data.get('format') == 'plane-cache-v1':
            cache = json.loads(gzip.decompress(Path(layer['cacheFile']).read_bytes()))
            return np.asarray(cache['segments']).reshape(-1, 2, 2) / scale / units
        data = self.data
        if data.get('format') == 'chunked-v1':
            chunk_index = layer['chunkIndex']
            if chunk_index != self.last_chunk:
                record = data['chunks'][chunk_index]
                payload = (self.path.parent / record['asset']).read_bytes()
                if hashlib.sha256(payload).hexdigest() != record['sha256']:
                    raise ValueError('Chunk checksum does not match manifest.')
                self.chunk = decode_world(gzip.decompress(payload), allow_no_global=True)
                self.last_chunk = chunk_index
            data = self.chunk
            child = data['layers'][layer['localLayerIndex']]
            if child['elevationCm'] != layer['elevationCm'] or child['globalOrigins'] != layer['globalOrigins']:
                raise ValueError('Chunk plane does not match manifest.')
            layer = child
        vertices = np.asarray(data['vertices']).reshape(-1, 2) / scale / units
        edges = np.asarray(data['edges'], dtype=np.int32).reshape(-1, 2)
        return vertices[edges[np.asarray(layer['edges'], dtype=np.int32)]]


def nearest_layers(elevations, targets):
    values = np.asarray(elevations)
    right = np.searchsorted(values, targets).clip(0, len(values) - 1)
    left = (right - 1).clip(0)
    return np.where(abs(values[left] - targets) <= abs(values[right] - targets), left, right)


def ray_distances(segments, starts, ends):
    """Independent analytic ray/segment intersections, with a spatial broad phase."""
    spans = ends - starts
    lengths = np.linalg.norm(spans, axis=1)
    directions = spans / lengths[:, None]
    result = lengths.copy()
    if not len(segments):
        return result
    tree = shapely.STRtree(shapely.linestrings(segments))
    rays, edges = tree.query(shapely.linestrings(np.stack([starts, ends], axis=1)))
    if not len(rays):
        return result
    delta = segments[edges, 0] - starts[rays]
    edge = segments[edges, 1] - segments[edges, 0]
    direction = directions[rays]
    cross = lambda a, b: a[:, 0] * b[:, 1] - a[:, 1] * b[:, 0]
    denominator = cross(direction, edge)
    ordinary = abs(denominator) > 1e-12
    t = np.full(len(rays), np.inf)
    u = np.full(len(rays), np.inf)
    t[ordinary] = cross(delta[ordinary], edge[ordinary]) / denominator[ordinary]
    u[ordinary] = cross(delta[ordinary], direction[ordinary]) / denominator[ordinary]
    hit = ordinary & (t >= 1e-7) & (t <= lengths[rays]) & (u >= -1e-9) & (u <= 1 + 1e-9)
    np.minimum.at(result, rays[hit], t[hit])
    # Collinear overlap: the nearest forward endpoint is the first obstruction.
    collinear = ~ordinary & (abs(cross(delta, direction)) < 1e-10)
    if collinear.any():
        rows = np.flatnonzero(collinear)
        a = np.sum(delta[rows] * direction[rows], axis=1)
        b = a + np.sum(edge[rows] * direction[rows], axis=1)
        begin, end = np.minimum(a, b), np.maximum(a, b)
        valid = end >= 1e-7
        distances = np.maximum(begin[valid], 1e-7)
        np.minimum.at(result, rays[rows[valid]], distances)
    return result


def verify(asset_path, reference_path, output_path, tolerance_meters=.02):
    started = time.perf_counter()
    source = PlaneSource(asset_path)
    asset_bytes = source.content
    reference_bytes = Path(reference_path).read_bytes()
    asset = source.data
    reference = json.loads(reference_bytes)
    if (asset['map'] != reference['map'] or
            asset['source']['geometrySha256'] != reference['source']['geometrySha256']):
        raise ValueError('Reference and baked world source do not match.')
    if asset['observerHeightCm'] != reference['eyeHeightCm']:
        raise ValueError('Reference and baked standing height do not match.')
    if asset.get('maxDistanceMeters') is not None and reference['rangeMeters'] > asset['maxDistanceMeters']:
        raise ValueError('Reference rays exceed the baked range contract.')
    units = np.asarray(asset['uvUnitsPerMeter'])
    rays = reference['rays']
    starts = np.asarray([ray['startUv'] for ray in rays]) / units
    ends = np.asarray([ray['endUv'] for ray in rays]) / units
    heights = np.asarray([ray['startMeters'][2] * 100 for ray in rays])
    elevations = np.asarray([layer['elevationCm'] for layer in asset['layers']])
    selected = nearest_layers(elevations, heights)
    actual = np.empty(len(rays))
    for index in np.unique(selected):
        rows = np.flatnonzero(selected == index)
        segments = source.segments(int(index))
        actual[rows] = ray_distances(segments, starts[rows], ends[rows])
    expected = np.asarray([ray['distanceMeters'] for ray in rays])
    delta = actual - expected
    errors = abs(delta)
    failed = np.flatnonzero(errors > tolerance_meters)
    details = [{'ray': rays[int(i)]['id'], 'sample': rays[int(i)]['sample'],
                'expectedMeters': float(expected[i]), 'bakedMeters': float(actual[i]),
                'errorMeters': float(delta[i]), 'elevationCm': float(heights[i]),
                'layerElevationCm': float(elevations[selected[i]]), 'layerIndex': int(selected[i]),
                'heightErrorCm': float(elevations[selected[i]] - heights[i]),
                'materialCertain': rays[int(i)].get('materialCertain', True)}
               for i in failed[np.argsort(-errors[failed])]]
    summary = {'rays': len(rays), 'origins': len(reference['origins']),
               'toleranceMeters': tolerance_meters, 'withinTolerance': int((errors <= tolerance_meters).sum()),
               'withinTolerancePercent': float((errors <= tolerance_meters).mean() * 100),
               'within10cmPercent': float((errors <= .1).mean() * 100),
               'medianErrorMeters': float(np.median(errors)), 'p95ErrorMeters': float(np.percentile(errors, 95)),
               'p99ErrorMeters': float(np.percentile(errors, 99)), 'maxErrorMeters': float(errors.max()),
               'maxHeightErrorCm': float(abs(elevations[selected] - heights).max()),
               'seconds': time.perf_counter() - started}
    report = {'map': asset['map'], 'status': 'independent-3d-versus-baked-2d', 'gameplayCertified': False,
              'assetSha256': hashlib.sha256(asset_bytes).hexdigest(),
              'referenceSha256': hashlib.sha256(reference_bytes).hexdigest(),
              'summary': summary, 'failures': details}
    if rays and all('planeReference' in ray for ray in rays):
        reference_planes = np.asarray([ray['planeElevationCm'] for ray in rays])
        matches = abs(reference_planes - elevations[selected]) < 1e-6
        plane_expected = np.asarray([ray['planeReference']['distanceMeters'] for ray in rays])
        plane_errors = abs(actual - plane_expected)
        report['planeSummary'] = {
            'rays': int(matches.sum()), 'differentSelectedPlanes': int((~matches).sum()),
            'within2cmPercent': float((plane_errors[matches] <= .02).mean() * 100) if matches.any() else None,
            'within10cmPercent': float((plane_errors[matches] <= .1).mean() * 100) if matches.any() else None,
            'maxErrorMeters': float(plane_errors[matches].max()) if matches.any() else None}
        report['planeFailures'] = [{'ray': rays[int(i)]['id'], 'errorMeters': float(plane_errors[i]),
                                    'referenceMeters': float(plane_expected[i]), 'bakedMeters': float(actual[i]),
                                    'elevationCm': float(elevations[selected[i]]),
                                    'sourceFace': rays[int(i)]['planeReference'].get('sourceFace')}
                                   for i in np.flatnonzero(matches & (plane_errors > .02))]
    Path(output_path).write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({'map': asset['map'], **summary}), flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('asset')
    parser.add_argument('reference')
    parser.add_argument('output')
    parser.add_argument('--tolerance-meters', type=float, default=.02)
    args = parser.parse_args()
    verify(args.asset, args.reference, args.output, args.tolerance_meters)
