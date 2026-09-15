"""Order baked edge IDs for linear-time runtime BVH construction.

Every coordinate and edge membership is unchanged. The recursive spatial
partition happens offline; runtime only combines child bounds.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import time

import numpy as np


def median_leaf_order(segments, leaf_size=8):
    if leaf_size < 1:
        raise ValueError('BVH leaves must contain at least one edge.')
    order = np.arange(len(segments), dtype=np.int32)
    minimum, maximum = segments.min(axis=1), segments.max(axis=1)
    centers = (minimum + maximum) / 2

    def partition(start, end):
        if end - start <= leaf_size:
            return
        ids = order[start:end]
        span = maximum[ids].max(axis=0) - minimum[ids].min(axis=0)
        axis = int(span[1] > span[0])
        half = (end - start) // 2
        selected = np.argpartition(centers[ids, axis], half)
        order[start:end] = ids[selected]
        middle = start + half
        partition(start, middle)
        partition(middle, end)

    partition(0, len(order))
    return order


def prepare(data):
    if data.get('spatialOrder') == 'bvh-median-v1':
        return data
    units = np.asarray(data['uvUnitsPerMeter'])
    vertices = np.asarray(data['vertices']).reshape(-1, 2) / data['coordinateScale'] / units
    edges = np.asarray(data['edges']).reshape(-1, 2)
    for layer in data['layers']:
        ids = np.asarray(layer['edges'], dtype=np.int32)
        if len(ids):
            order = median_leaf_order(vertices[edges[ids]])
            layer['edges'] = ids[order].tolist()
    data['spatialOrder'] = 'bvh-median-v1'
    return data


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.source.resolve() == args.output.resolve():
        parser.error('Write prepared data to a separate path to preserve the source audit.')
    started = time.perf_counter()
    source = args.source.read_bytes()
    data = prepare(json.loads(gzip.decompress(source)))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    pending = args.output.with_suffix('.writing')
    pending.write_bytes(gzip.compress(json.dumps(data, separators=(',', ':')).encode(), compresslevel=9, mtime=0))
    pending.replace(args.output)
    print(json.dumps({'map': data['map'], 'layers': len(data['layers']),
                      'sourceSha256': hashlib.sha256(source).hexdigest(),
                      'seconds': time.perf_counter() - started}), flush=True)
