"""Measure local source sections along every SVG footprint, without editing it.

This produces evidence for association review. A nearby triangle is not by
itself permission to create an opening or change a runtime wall.
"""
import argparse
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT / 'tactical-visibility-revision'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    model = json.loads((REV / 'split-svg-semantic-prototype-v6/split-attack.json').read_text())
    source = ROOT / 'supplemented-v2/world/split/geometry.npz'
    archive = np.load(source)
    points, faces = archive['points'], archive['faces']
    metadata = json.loads(source.with_suffix('.json').read_text())['objects']
    eligible = [i for i, o in enumerate(metadata) if not any(
        word in o['path'].lower() for word in ('foliage', 'bush', 'grass', 'skydome'))]
    boxes = np.array([metadata[i]['boundsMeters'] for i in eligible])
    tree = shapely.STRtree(shapely.box(boxes[:, 0, 0], boxes[:, 0, 1],
                                      boxes[:, 1, 0], boxes[:, 1, 1]))
    matrix = np.array(json.loads((ROOT / 'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    cache = {}

    def geometry(oid):
        if oid not in cache:
            o = metadata[oid]
            ids = np.arange(o['firstFace'], o['firstFace'] + o['faceCount'])
            tri = points[faces[ids]].astype(float)
            cache[oid] = (ids, tri)
        return cache[oid]

    rows = []
    for wall in model['walls']:
        stations = []
        for ri, ring in enumerate(wall['rings']):
            xy = np.array(ring).reshape(-1, 2)
            if np.array_equal(xy[0], xy[-1]):
                xy = xy[:-1]
            if np.linalg.norm(np.roll(xy, -1, axis=0) - xy, axis=1).max() < .5:
                # Sample curved ink for evidence only; do not alter model rings.
                curve = shapely.LineString(np.vstack((xy, xy[0])))
                count = max(8, int(np.ceil(curve.length / 4)))
                xy = np.array([curve.interpolate(t).coords[0] for t in np.arange(count) * curve.length / count])
            for ei, (a, b) in enumerate(zip(xy, np.roll(xy, -1, axis=0))):
                length = np.linalg.norm(b - a)
                if length < .5:
                    continue
                count = max(1, int(np.ceil(length / 8)))
                for t in (np.arange(count) + .5) / count:
                    svg = a + (b - a) * t
                    native = inverse @ (svg - matrix[:, 2])
                    tangent = inverse @ (b - a)
                    tangent /= np.linalg.norm(tangent)
                    normal = np.array([-tangent[1], tangent[0]])
                    near = tree.query(shapely.box(*(native - .6), *(native + .6)))
                    sections = []
                    for index in near:
                        oid = eligible[index]
                        ids, tri = geometry(oid)
                        along = (tri[:, :, :2] - native) @ tangent
                        # Intersect each triangle with the vertical plane
                        # perpendicular to the SVG edge at this station.
                        selected = np.flatnonzero((along.min(1) <= 0) & (along.max(1) >= 0))
                        if not len(selected):
                            continue
                        tr = tri[selected]
                        aa = along[selected]
                        samples = []
                        sample_faces = []
                        for j, k in [(0, 1), (1, 2), (2, 0)]:
                            denominator = aa[:, k] - aa[:, j]
                            ok = (aa[:, j] * aa[:, k] <= 0) & (abs(denominator) > 1e-12)
                            f = -aa[ok, j] / denominator[ok]
                            hit = tr[ok, j] + f[:, None] * (tr[ok, k] - tr[ok, j])
                            samples.extend(hit)
                            sample_faces.extend(ids[selected[ok]])
                        if not samples:
                            continue
                        samples = np.array(samples)
                        sample_faces = np.array(sample_faces)
                        offsets = (samples[:, :2] - native) @ normal
                        clipped = []
                        clipped_faces = []
                        nearest = []
                        for face in np.unique(sample_faces):
                            mask = sample_faces == face
                            ns, zs = offsets[mask], samples[mask, 2]
                            lo, hi = int(ns.argmin()), int(ns.argmax())
                            if ns[lo] > .6 or ns[hi] < -.6:
                                continue
                            if ns[hi] - ns[lo] < 1e-10:
                                heights = [float(zs.min()), float(zs.max())]
                            else:
                                ends = np.clip([ns[lo], ns[hi]], -.6, .6)
                                heights = (zs[lo] + (ends - ns[lo]) / (ns[hi] - ns[lo]) * (zs[hi] - zs[lo])).tolist()
                            clipped.extend(heights)
                            clipped_faces.append(int(face))
                            nearest.append(0. if ns[lo] <= 0 <= ns[hi] else min(abs(ns[lo]), abs(ns[hi])))
                        if not clipped:
                            continue
                        sections.append(dict(object=oid,
                            rawFaces=clipped_faces,
                            nearestMeters=float(min(nearest)),
                            heightRangeMeters=[min(clipped), max(clipped)]))
                    stations.append(dict(ring=ri, edge=ei, svg=svg.tolist(),
                                         native=native.tolist(), sections=sections))
        rows.append(dict(wallId=wall['id'], unknownHeight=wall['unknownHeight'], stations=stations))
        print(f"{wall['id']}: {len(stations)} stations", flush=True)
    result = dict(source=str(source), sourceObjects=metadata,
        policy='Source sections within 0.6 m of SVG ink. Evidence only; no automatic wall height or opening decisions.',
        spacingSvg=8, minimumEdgeLengthSvg=.5, walls=rows)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open('xb') as output:
        output.write(gzip.compress(json.dumps(result, separators=(',', ':')).encode(), mtime=0))
    print(json.dumps(dict(output=str(args.out), walls=len(rows),
                         stations=sum(len(r['stations']) for r in rows))))


if __name__ == '__main__':
    main()
