"""Compact extracted navigation planes for standing-target experiments.

This retains every walkable native layer and its original XY footprint. It does
not refine navigation height to rendered floors or extend inset navigation to
SVG walls. Overlapping levels remain separate receiver candidates.
"""
import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import shapely

from compact_tactical_floor_support import compact


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(root, out, name):
    started = time.perf_counter()
    source = root / f'{name}_source_xyz.json'
    navigation = root / f'{name}_navigation.json'
    raw = json.loads(source.read_bytes())
    nav = json.loads(navigation.read_bytes())
    if raw['navigationSha256'] != sha(navigation):
        raise ValueError('Navigation provenance changed')
    vertices = np.asarray(raw['vertices'], dtype=float).reshape(-1, 3) / 100
    vertices[:, 1] *= -1
    refs = np.asarray(raw['triangles'], dtype=int).reshape(-1, 4)
    xyz = vertices[refs[:, 1:]]
    areas = shapely.area(shapely.polygons(xyz[:, :, :2]))
    walkable = np.asarray(nav['walkable'], dtype=bool)[refs[:, 0]]
    ids = np.flatnonzero(walkable & (areas > 0))
    if not np.isfinite(xyz).all() or not len(ids):
        raise ValueError('Invalid navigation coordinates or no walkable triangles')
    arrays, report = compact(vertices, refs[ids, 1:], ids)
    # Check all original triangle vertices and four interior positions against
    # the resulting group plane. This independently replays source provenance;
    # exact per-group footprint and interior-overlap gates run in compact().
    offsets = arrays['groupSourceOffsets']
    triangle_group = np.full(len(refs), -1, dtype=int)
    maximum_error = 0.
    bary = np.array([[1, 0, 0], [0, 1, 0], [0, 0, 1],
                     [1/3, 1/3, 1/3], [.6, .2, .2], [.2, .6, .2], [.2, .2, .6]])
    for group, plane in enumerate(arrays['groupPlanes']):
        source_ids = arrays['groupSourceFaces'][offsets[group]:offsets[group+1]]
        if np.any(triangle_group[source_ids] >= 0):
            raise ValueError('A source triangle belongs to more than one receiver group')
        triangle_group[source_ids] = group
        samples = np.einsum('ki,nij->nkj', bary, xyz[source_ids])
        predicted = samples[..., :2] @ plane[:2] + plane[2]
        maximum_error = max(maximum_error, float(np.abs(predicted-samples[..., 2]).max()))
    if not np.array_equal(np.flatnonzero(triangle_group >= 0), ids):
        raise ValueError('Native walkable source coverage changed')
    if maximum_error > 1e-5:
        raise ValueError('Native floor plane replay exceeds the declared height bound')
    arrays['nativeTriangleParents'] = refs[:, 0].astype('<u4')
    arrays['nativeTriangleGroups'] = triangle_group.astype('<i4')
    target = out / f'{name}.nav-receivers.npz'
    np.savez_compressed(target, **arrays)
    report.update(map=name, sourceSha256=sha(source), navigationSha256=sha(navigation),
        inputSourceBytes=source.stat().st_size, outputBytes=target.stat().st_size,
        outputSha256=sha(target), rejectedZeroAreaWalkableTriangles=int((walkable & (areas == 0)).sum()),
        sourceTriangleProvenanceReplay=True, heightSamples=len(ids)*len(bary),
        maximumReplayedHeightErrorMeters=maximum_error,
        elapsedSeconds=time.perf_counter()-started)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('navigation_root', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--maps', nargs='+', default=['split'])
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    reports = []
    for name in args.maps:
        report = build(args.navigation_root, args.output, name)
        reports.append(report)
        (args.output / f'{name}.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps({k: report[k] for k in ['map', 'inputTriangles', 'outputTriangles',
              'planeGroups', 'outputBytes', 'maximumReplayedHeightErrorMeters']}), flush=True)
    result = dict(scope=__doc__, scriptSha256=sha(Path(__file__)),
        compactScriptSha256=sha(Path(__file__).with_name('compact_tactical_floor_support.py')),
        maps=reports, productionPromotion=False,
        limitations=[
            'Native navigation heights are approximate and can differ from the visible floor.',
            'No layer is silently selected. An origin/layer policy is still required.',
            'Navigation is inset from walls. These footprints cannot be the final SVG visibility mask.',
            'This is offline storage and geometry validation, not a frame-rate or gameplay result.',
        ])
    (args.output / 'report.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
