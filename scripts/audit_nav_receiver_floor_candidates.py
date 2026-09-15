"""Measure competing rendered-floor heights at frozen native navigation samples.

The 15 cm association band is a diagnostic window, not a certified error bound.
All matches are retained. No candidate floor or upper/lower layer is selected.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def audit(revision, out, name):
    nav_path = revision.parent / 'nav/baked' / f'{name}_navigation.json'
    raw_path = nav_path.with_name(f'{name}_source_xyz.json')
    nav, raw = json.loads(nav_path.read_bytes()), json.loads(raw_path.read_bytes())
    if raw['navigationSha256'] != sha(nav_path):
        raise ValueError('Native navigation provenance changed')
    vertices = np.asarray(raw['vertices'], dtype=float).reshape(-1, 3) / 100
    vertices[:, 1] *= -1
    refs = np.asarray(raw['triangles']).reshape(-1, 4)
    xyz = vertices[refs[:, 1:]]
    eligible = np.flatnonzero(np.asarray(nav['walkable'])[refs[:, 0]] &
                              (shapely.area(shapely.polygons(xyz[:, :, :2])) > 0))
    # Strictly interior positions avoid giving shared triangle seams extra votes.
    bary = np.asarray([[1/3]*3, [.6, .2, .2], [.2, .6, .2], [.2, .2, .6]])
    samples = np.einsum('ki,nij->nkj', bary, xyz[eligible]).reshape(-1, 3)
    meta_path = revision / 'source-floor-support-all-walkable-v1' / f'{name}.floor-support.json'
    meta = json.loads(meta_path.read_bytes())
    support_path = meta_path.parent / meta['dataFile']
    if sha(support_path) != meta['dataSha256']:
        raise ValueError('Source floor evidence changed')
    with np.load(support_path) as data:
        source_faces = data['sourceFaces']
        support = data['vertices'][data['triangles']]
    source_ids = np.flatnonzero(source_faces >= 0)
    support = support[source_ids]
    planes = np.linalg.solve(np.concatenate([support[:, :, :2], np.ones((len(support), 3, 1))], 2),
                             support[:, :, 2, None])[:, :, 0]
    tree = shapely.STRtree(shapely.polygons(support[:, :, :2]))
    sample_ids, floor_ids = tree.query(shapely.points(samples[:, :2]), predicate='intersects')
    heights = np.einsum('ni,ni->n', samples[sample_ids, :2], planes[floor_ids, :2]) + planes[floor_ids, 2]
    delta = heights - samples[sample_ids, 2]
    near = np.abs(delta) <= .15
    sid, fid, z = sample_ids[near], floor_ids[near], heights[near]
    count = np.bincount(sid, minlength=len(samples))
    low, high = np.full(len(samples), np.inf), np.full(len(samples), -np.inf)
    np.minimum.at(low, sid, z)
    np.maximum.at(high, sid, z)
    supported = count > 0
    spread = np.zeros(len(samples)); spread[supported] = high[supported]-low[supported]
    distances = np.full(len(samples), np.inf)
    np.minimum.at(distances, sample_ids, np.abs(delta))
    target = out / f'{name}.floor-candidates.npz'
    np.savez_compressed(target, samples=samples, nativeTriangles=np.repeat(eligible, 4),
        nativeParents=np.repeat(refs[eligible, 0], 4), sampleIds=sid,
        supportIds=source_ids[fid], fullHeightPackFaces=source_faces[source_ids[fid]],
        sourceHeights=z, count=count, minimumHeight=low, maximumHeight=high,
        nearestSourceHeightDistance=distances)
    report = dict(map=name, samples=len(samples), associationBandMeters=.15,
        samplesWithoutNearbySource=int((~supported).sum()),
        samplesWithoutAnySourceXY=int(np.isinf(distances).sum()),
        samplesWithHeightSpreadAbove1mm=int((spread > .001).sum()),
        samplesWithHeightSpreadAbove1cm=int((spread > .01).sum()),
        maximumNearbyHeightSpreadMeters=float(spread.max()),
        ambiguousExamples=[dict(sample=int(i), position=samples[i].tolist(),
            nativeTriangle=int(eligible[i//4]), minHeight=float(low[i]), maxHeight=float(high[i]))
            for i in np.argsort(-spread, kind='stable')[:12] if spread[i] > .001],
        navigationSha256=sha(nav_path), nativeXYZSha256=sha(raw_path),
        supportMetadataSha256=sha(meta_path), supportSha256=sha(support_path),
        outputSha256=sha(target), outputBytes=target.stat().st_size)
    (out / f'{name}.json').write_text(json.dumps(report, indent=2)+'\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--maps', nargs='+', default=['split'])
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    reports = []
    for name in args.maps:
        report = audit(args.revision, args.output, name)
        reports.append(report)
        print(json.dumps({k: report[k] for k in ['map', 'samples', 'samplesWithoutNearbySource',
            'samplesWithoutAnySourceXY', 'samplesWithHeightSpreadAbove1mm',
            'maximumNearbyHeightSpreadMeters']}), flush=True)
    (args.output/'report.json').write_text(json.dumps(dict(scope=__doc__,
        scriptSha256=sha(Path(__file__)), maps=reports, productionPromotion=False,
        limitations=['Finite interior samples do not prove continuous footprint coverage.',
                     'Source support classification is provisional and may contain props or buried floor faces.',
                     'Height disagreement is not itself evidence of a visibility disagreement.',
                     'No XY buffer was used; only actual source triangle footprints were queried.']), indent=2)+'\n')


if __name__ == '__main__':
    main()
