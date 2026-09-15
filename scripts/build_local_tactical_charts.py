"""Separate independent standing-height overlaps into local reference charts.

Each chart changes only a connected component of upper-minus-lower vertices.
The shared triangulation makes every combination continuous, without blending
between unrelated upper floors or anchoring disconnected props as ground.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components
from build_global_tactical_candidate import GroundField, build


def prepare(revision, name, bake=False):
    lower = GroundField(revision / 'global-ground-v1' / f'{name}.tactical-ground.json.gz')
    upper = GroundField(revision / 'upper-ground-v2' / f'{name}.tactical-ground.json.gz')
    if not np.array_equal(lower.triangles, upper.triangles) or not np.array_equal(lower.vertices[:, :2], upper.vertices[:, :2]):
        raise ValueError('Local charts require identical lower/upper XY topology')
    delta = upper.vertices[:, 2] - lower.vertices[:, 2]
    active = np.flatnonzero(delta > 1.75)
    edges = np.concatenate([lower.triangles[:, [0, 1]], lower.triangles[:, [1, 2]], lower.triangles[:, [2, 0]]])
    edges = edges[np.all(np.isin(edges, active), axis=1)]
    graph = coo_matrix((np.ones(len(edges)), (edges[:, 0], edges[:, 1])), shape=(len(delta), len(delta))).tocsr()
    _, labels = connected_components(graph, directed=False)
    groups = [active[labels[active] == label] for label in np.unique(labels[active])]
    groups.sort(key=lambda ids: -float(lower.vertices[ids, 1].mean()))
    if len(groups) > 4:
        raise ValueError('More than four independent overlaps; do not expand charts exponentially')
    output = revision / 'local-ground-charts-v1' / name
    output.mkdir(parents=True, exist_ok=True)
    regions = [dict(index=i, vertices=ids.tolist(), bounds=[*lower.vertices[ids, :2].min(0), *lower.vertices[ids, :2].max(0)],
                    minimumFloorSeparationMeters=float(delta[ids].min()), maximumFloorSeparationMeters=float(delta[ids].max()))
               for i, ids in enumerate(groups)]
    records = []
    for mask in range(1 << len(groups)):
        folder = output / str(mask)
        folder.mkdir(exist_ok=True)
        path = folder / f'{name}.tactical-ground.json.gz'
        data = dict(lower.data)
        vertices = lower.vertices.copy()
        for i, ids in enumerate(groups):
            if mask & (1 << i):
                vertices[ids, 2] += delta[ids]
        data.update(vertices=vertices.reshape(-1).tolist(), observerVariant=f'local-{mask}',
                    policy='independent-standing-overlap-reference-v1', localChartMask=mask,
                    localChartRegions=regions,
                    scope='Continuous tactical floor reference. Floor separation is not a standing-clearance certificate; seed ray validation remains required.')
        encoded = gzip.compress(json.dumps(data, separators=(',', ':'), allow_nan=False).encode(), compresslevel=9, mtime=0)
        path.write_bytes(encoded)
        record = dict(mask=mask, field=str(path), sha256=hashlib.sha256(encoded).hexdigest())
        if bake and mask and not (folder / 'native/height-source.raw').exists():
            build(revision / 'full-height-input-v1' / name / f'{name}.height.bin.gz', path, folder)
        records.append(record)
    report = dict(map=name, regions=regions, charts=records,
                  ignoredSmallDifferences=int(np.sum((delta > 1e-7) & (delta <= 1.75))))
    (output / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(map=name, regions=len(groups), charts=len(records))), flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('map')
    parser.add_argument('--bake', action='store_true')
    args = parser.parse_args()
    prepare(args.revision, args.map, args.bake)
