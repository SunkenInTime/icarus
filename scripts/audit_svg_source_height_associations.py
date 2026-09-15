"""Measure source correspondence for authored SVG walls, without enabling them.

These are review candidates. Projected triangle proximity establishes a nearby
surface, not its gameplay role. Keep unmatched and mixed associations explicit.
"""
import argparse
from collections import Counter
from functools import lru_cache
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT / 'tactical-visibility-revision'
EXCLUDED = ('foliage', 'bush', 'grass', 'skydome', 'skybox', 'decal',
            'particle', 'vfx', 'ivy', 'flower', 'treeleaf')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def projected_distance(triangles, point):
    """Distance to the closed XY triangle, including vertical/degenerate faces."""
    a = triangles[:, :, :2]
    b = np.roll(a, -1, axis=1)
    delta = b - a
    lengths = np.sum(delta * delta, axis=2)
    fraction = np.sum((point - a) * delta, axis=2) / np.maximum(lengths, 1e-30)
    near = a + np.clip(fraction, 0, 1)[:, :, None] * delta
    distance = np.sqrt(np.sum((near - point) ** 2, axis=2).min(axis=1))
    cross = delta[:, :, 0] * (point[1] - a[:, :, 1]) - delta[:, :, 1] * (point[0] - a[:, :, 0])
    u, v = a[:, 1] - a[:, 0], a[:, 2] - a[:, 0]
    area = np.abs(u[:, 0] * v[:, 1] - u[:, 1] * v[:, 0])
    inside = ((cross >= -1e-12).all(axis=1) | (cross <= 1e-12).all(axis=1)) & (area > 1e-12)
    distance[inside] = 0
    return distance


def stations(wall, spacing=4):
    result = []
    for ring in wall['rings']:
        line = shapely.LineString(np.array(ring).reshape(-1, 2))
        count = max(1, int(np.ceil(line.length / spacing)))
        result.extend(line.interpolate((i + .5) * line.length / count).coords[0]
                      for i in range(count))
    return np.array(result)


def audit(name, source_model, out):
    model = json.loads(source_model.read_text())
    path = ROOT / f'supplemented-v2/world/{name}/geometry.npz'
    archive = np.load(path)
    points, faces = archive['points'], archive['faces']
    objects = json.loads(path.with_suffix('.json').read_text())['objects']
    eligible = [i for i, o in enumerate(objects)
                if o['faceCount'] and not any(x in o['path'].lower() for x in EXCLUDED)]
    bounds = np.array([objects[i]['boundsMeters'] for i in eligible])
    tree = shapely.STRtree(shapely.box(bounds[:, 0, 0], bounds[:, 0, 1],
                                      bounds[:, 1, 0], bounds[:, 1, 1]))
    alignment_path = ROOT / f'tactical-alignment-sides-v1/{name}.json'
    alignment = json.loads(alignment_path.read_text())
    matrix = np.array(alignment['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    radius = .6
    ground_path = REV / f'global-ground-v1/{name}.tactical-ground.json.gz'
    ground = json.loads(gzip.decompress(ground_path.read_bytes()))
    gv = np.array(ground['vertices']).reshape(-1, 3)
    gt = gv[np.array(ground['triangles']).reshape(-1, 3)]
    ground_polygons = shapely.polygons(gt[:, :, :2])
    ground_tree = shapely.STRtree(ground_polygons)
    ground_planes = np.linalg.solve(np.concatenate((gt[:, :, :2], np.ones((len(gt), 3, 1))), axis=2), gt[:, :, 2, None])[:, :, 0]

    def ground_height(xy):
        hits = ground_tree.query(shapely.Point(xy), predicate='intersects')
        if not len(hits):
            return None
        plane = ground_planes[int(hits.min())]
        return float(plane[:2] @ xy + plane[2])

    @lru_cache(maxsize=48)
    def geometry(oid):
        obj = objects[oid]
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        tri = points[faces[ids]].astype(float)
        return ids, tri, tri[:, :, :2].min(1), tri[:, :, :2].max(1)

    result = []
    for wall in model['walls']:
        svg_points = stations(wall)
        native_points = (svg_points - matrix[:, 2]) @ inverse.T
        samples = []
        for svg, native in zip(svg_points, native_points):
            candidates = []
            for index in tree.query(shapely.box(*(native - radius), *(native + radius))):
                oid = eligible[index]
                ids, tri, low, high = geometry(oid)
                near = np.flatnonzero((low <= native + radius).all(1) & (high >= native - radius).all(1))
                if not len(near):
                    continue
                distances = projected_distance(tri[near], native)
                near = near[distances <= radius]
                distances = distances[distances <= radius]
                if not len(near):
                    continue
                local = tri[near]
                normals = np.cross(local[:, 1] - local[:, 0], local[:, 2] - local[:, 0])
                norm = np.linalg.norm(normals, axis=1)
                upward = normals[:, 2] > .65 * norm
                vertical = (np.abs(normals[:, 2]) < .35 * norm) & (norm > 1e-12)
                candidates.append(dict(object=oid, nearestMeters=float(distances.min()),
                    nearbyMinimumZ=float(local[:, :, 2].min()),
                    nearbyMaximumZ=float(local[:, :, 2].max()),
                    upwardFaces=int(upward.sum()), verticalFaces=int(vertical.sum()),
                    verticalMinimumZ=float(local[vertical, :, 2].min()) if vertical.any() else None,
                    verticalMaximumZ=float(local[vertical, :, 2].max()) if vertical.any() else None,
                    faces=len(near),
                    nearestFace=int(ids[near[int(distances.argmin())]])))
            samples.append(dict(svg=svg.tolist(), native=native.tolist(),
                                primaryGroundZ=ground_height(native), candidates=candidates))
        counts = Counter(c['object'] for s in samples for c in s['candidates'])
        summary = [dict(object=oid, path=objects[oid]['path'], stations=count,
                        boundsMeters=objects[oid]['boundsMeters'])
                   for oid, count in counts.most_common()]
        result.append(dict(wallId=wall['id'], stations=samples, sourceObjects=summary,
                           unmatchedStations=sum(not s['candidates'] for s in samples),
                           decision='unreviewed'))
        print(f'{name}: {wall["id"]}, {len(samples)} stations, {len(counts)} objects', flush=True)
    output = dict(map=name, sourceModel=str(source_model), sourceModelSha256=sha(source_model),
                  geometrySha256=sha(path), alignmentSha256=sha(alignment_path),
                  groundSha256=sha(ground_path),
                  searchRadiusMeters=radius, stationSpacingSvg=4,
                  excludedNameTerms=EXCLUDED, walls=result,
                  policy='Triangle proximity evidence only. No automatic gameplay openings or runtime changes.')
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(gzip.compress(json.dumps(output, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
    print(json.dumps(dict(map=name, output=str(out), walls=len(result),
                         stations=sum(len(w['stations']) for w in result),
                         unmatched=sum(w['unmatchedStations'] for w in result))), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--map', required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    audit(args.map, args.model, args.out)
