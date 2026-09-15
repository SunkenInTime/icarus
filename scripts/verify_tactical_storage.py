"""Compare bounded coordinate storage against its exact input using native rays.

This checks storage effects only. Source geometry and tactical semantics need
their separate audits. No output from this tool is installed into the app.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct
import subprocess

import numpy as np


def unpack(pack, folder):
    raw = gzip.decompress(pack.read_bytes())
    magic, length = struct.unpack_from('<4sI', raw)
    if magic != b'IHD1':
        raise ValueError('Expected IHD1')
    header = json.loads(raw[8:8 + length])
    base = (8 + length + 7) // 8 * 8
    folder.mkdir()
    (folder / 'height-source.raw').write_bytes(raw)
    (folder / 'arrays.txt').write_text('\n'.join(
        f'{name} {base + item["offset"]} {item["count"]}'
        for name, item in header['arrays'].items()))
    (folder / 'alpha-textures.txt').write_text('\n'.join(
        f'{index} {item["width"]} {item["height"]} {base + item["offset"]}'
        for index, item in enumerate(header['textures'])))
    wraps = {'repeat': 0, 'clamp': 1, 'mirror': 2, 'black': 3}
    (folder / 'alpha-materials.txt').write_text('\n'.join(
        f'{m["material"]} {m["texture"]} {m["threshold"]:.17g} '
        f'{m["alphaScale"]:.17g} {m["alphaBias"]:.17g} '
        f'{wraps[m["wrapS"]]} {wraps[m["wrapT"]]}'
        for m in header['materials']))
    (folder / 'parameters.txt').write_text(' '.join(
        format(x, '.17g') for x in header['heightDomainMeters']))
    return header


def run(source, candidate, queries, native, output, directions):
    if output.exists():
        raise ValueError('Preserving existing storage verification')
    output.mkdir(parents=True)
    headers, rays = [], []
    for label, pack in [('source', source), ('candidate', candidate)]:
        folder = output / label
        headers.append(unpack(pack, folder))
        target = output / (label + '.rays.f64')
        subprocess.run([str(native), str(folder), str(queries), str(target),
                        str(directions), '65'], check=True)
        rays.append(np.fromfile(target, dtype='<f8').reshape(-1, directions))
    source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    if headers[1]['coordinateQuantization']['inputPackSha256'] != source_hash:
        raise ValueError('Candidate was not derived from this exact source pack')
    if rays[0].shape != rays[1].shape:
        raise ValueError('Native result counts differ')
    delta = np.abs(rays[0] - rays[1])
    rows, angles = np.where(delta > .001)
    report = {
        'scope': 'Native ray comparison of storage precision only; not gameplay acceptance',
        'sourceSha256': source_hash,
        'candidateSha256': hashlib.sha256(candidate.read_bytes()).hexdigest(),
        'queriesSha256': hashlib.sha256(queries.read_bytes()).hexdigest(),
        'poses': len(rays[0]), 'directions': directions, 'rays': int(delta.size),
        'maximumDistanceErrorMeters': float(delta.max()),
        'p999DistanceErrorMeters': float(np.percentile(delta, 99.9)),
        'raysBeyond1mm': len(rows),
        'raysBeyond1cm': int(np.sum(delta > .01)),
        'outliers': [dict(pose=int(row), direction=int(angle),
                          before=float(rays[0][row, angle]),
                          after=float(rays[1][row, angle]))
                     for row, angle in zip(rows, angles)],
    }
    (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'outliers'}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source', 'candidate', 'queries', 'native', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--directions', type=int, default=512)
    args = parser.parse_args()
    run(args.source, args.candidate, args.queries, args.native,
        args.output, args.directions)
