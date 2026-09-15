"""Measure bounded coordinate storage precision in a separate candidate pack.

Only native XYZ coordinates change. Alpha UVs, material thresholds and texture
bytes remain exact. BVH bounds expand outward to contain every rounded vertex.
No candidate produced here is installed automatically.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct
import numpy as np


def build(source_path, output, bits=17):
    if output.exists():
        raise ValueError('Preserving existing candidate')
    source = gzip.decompress(source_path.read_bytes())
    if source[:4] != b'IHD1':
        raise ValueError('Expected IHD1')
    size = struct.unpack_from('<I', source, 4)[0]
    header = json.loads(source[8:8 + size])
    base = (8 + size + 7) // 8 * 8
    payload = bytearray(source[base:])
    def array(name):
        meta = header['arrays'][name]
        return np.frombuffer(payload, dtype=meta['dtype'], count=meta['count'], offset=meta['offset']).reshape(meta['shape'])
    grid = 2. ** -bits
    points = array('vertices')
    original = points.copy()
    points[:] = np.rint(points / grid) * grid
    error = float(np.abs(points - original).max())
    if error > grid / 2:
        raise ValueError('Rounding exceeded the declared coordinate bound')
    bounds = array('bounds')
    bounds[:, :3] = np.floor(bounds[:, :3] / grid) * grid
    bounds[:, 3:] = np.ceil(bounds[:, 3:] / grid) * grid
    faces, nodes = array('faces'), array('nodes')
    # Check every leaf directly and every parent-child containment relation.
    for index, node in enumerate(nodes):
        start, count, left, right = node
        if left < 0:
            triangle = points[faces[start:start + count]]
            lower, upper = triangle.min(axis=(0, 1)), triangle.max(axis=(0, 1))
        else:
            lower = bounds[[left, right], :3].min(0)
            upper = bounds[[left, right], 3:].max(0)
        if np.any(lower < bounds[index, :3]) or np.any(upper > bounds[index, 3:]):
            raise ValueError(f'Rounded geometry escapes BVH node {index}')
    header['coordinateQuantization'] = dict(gridMeters=grid, maximumAxisErrorMeters=error,
        inputPackSha256=hashlib.sha256(source_path.read_bytes()).hexdigest(),
        alphaCoordinatesChanged=False, bvhBoundsRoundedOutward=True,
        acceptance='Storage experiment; requires source rays and rendered comparisons before adoption')
    encoded = json.dumps(header, separators=(',', ':'), allow_nan=False).encode()
    new_base = (8 + len(encoded) + 7) // 8 * 8
    raw = bytearray(new_base) + payload
    raw[:8] = struct.pack('<4sI', b'IHD1', len(encoded))
    raw[8:8 + len(encoded)] = encoded
    output.mkdir(parents=True)
    target = output / source_path.name
    target.write_bytes(gzip.compress(raw, compresslevel=9, mtime=0))
    report = dict(header['coordinateQuantization'], map=header['map'],
        inputCompressedBytes=source_path.stat().st_size, compressedBytes=target.stat().st_size,
        rawBytes=len(raw), packSha256=hashlib.sha256(target.read_bytes()).hexdigest())
    (output / 'quantization.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--bits', type=int, default=17)
    args = parser.parse_args()
    if args.bits < 15 or args.bits > 30:
        parser.error('Expected15–30 binary fractional bits')
    build(args.source, args.output, args.bits)
