"""Narrow competing-support review to walk-like source planes in climb band."""
import argparse
import json
from pathlib import Path
import numpy as np
import shapely
from audit_competing_floor_assemblies import clip_above
from probe_source_floor_regressions import load_support


def main(name):
    revision = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    directory = revision / 'competing-floor-assemblies-v3'
    path = directory / f'{name}.json'
    report = json.loads(path.read_text())
    support = load_support(revision, name, True)
    data = np.load(directory / report['pairFile'])
    pairs = data['supportIndices']
    normals = np.cross(support.points[:, 1] - support.points[:, 0], support.points[:, 2] - support.points[:, 0])
    normals /= np.linalg.norm(normals, axis=1)[:, None]
    eligible = (support.source_ids[pairs[:, 1]] >= 0) & (np.abs(normals[pairs[:, 0], 2]) >= .65) & (np.abs(normals[pairs[:, 1], 2]) >= .65)
    pair_ids = np.flatnonzero(eligible)
    a, b = pairs[pair_ids].T
    shapes = shapely.intersection(support.polygons[a], support.polygons[b])
    difference = support.planes[a] - support.planes[b]
    xy, owners = shapely.get_coordinates(shapes, return_index=True)
    gap = np.sum(xy * difference[owners, :2], axis=1) + difference[owners, 2]
    low, high = np.full(len(a), np.inf), np.full(len(a), -np.inf)
    np.minimum.at(low, owners, gap); np.maximum.at(high, owners, gap)
    shapes = clip_above(shapes, difference, .05, low, high)
    shapes = clip_above(shapes, -difference, -.35, -high, -low)
    lookup = {int(pair): i for i, pair in enumerate(pair_ids)}
    for row in report['records']:
        selected = [lookup[i] for i in row['pairIndices'] if i in lookup]
        footprint = shapely.union_all(shapes[selected], grid_size=1e-8) if selected else shapely.GeometryCollection()
        progression = row.get('connectedNavProgression', {}).get('maximumConnectedHeightSpanMeters', row['detailedNavMatchedHeightSpanMeters'])
        area = float(footprint.area)
        exemplars = []
        for index in sorted(selected, key=lambda i: shapes[i].area, reverse=True)[:5]:
            upper, lower = int(a[index]), int(b[index])
            xy = np.array(shapes[index].representative_point().coords[0])
            exemplars.append({'upperSupportIndex': upper, 'lowerSupportIndex': lower, 'upperFullPackFace': int(support.source_ids[upper]), 'lowerFullPackFace': int(support.source_ids[lower]), 'lowerObject': support.objects[lower], 'nativeXY': xy.tolist(), 'upperHeightMeters': float(xy @ support.planes[upper, :2] + support.planes[upper, 2]), 'lowerHeightMeters': float(xy @ support.planes[lower, :2] + support.planes[lower, 2]), 'overlapAreaMeters2': float(shapes[index].area), 'gapRangeMeters': [max(float(low[index]), .05), min(float(high[index]), .35)]})
        row['terrainReviewQueue'] = {'priority': area >= .01 and progression >= .25, 'sourceSourceClimbBandPairs': len(selected), 'sourceSourceClimbBandAreaMeters2': area, 'sourceSourceClimbBandFootprint': shapely.to_geojson(footprint), 'connectedNavHeightSpanMeters': progression, 'examples': exemplars, 'scope': 'Review prioritization only: both competing faces are actual source with abs(normalZ)>=.65, actual height gap5–35cm, overlap area>=.01m2, connected matched nav span>=.25m. The geometric slope and area cutoffs are diagnostic, not Valorant rules. Raised props can still qualify and require explicit role review.'}
    report['records'].sort(key=lambda row: (row['terrainReviewQueue']['priority'], row['terrainReviewQueue']['sourceSourceClimbBandAreaMeters2'] * min(row['terrainReviewQueue']['connectedNavHeightSpanMeters'], 2)), reverse=True)
    path.write_text(json.dumps(report, indent=2))
    rows = [{'sourceObjectIndex': row['sourceObjectIndex'], 'path': row['objectPath'], 'sourceFirstFace': row['sourceObject']['firstFace'], 'nativeMesh': row['native'].get('mesh'), 'priority': row['terrainReviewQueue']['priority'], 'sourceSourceBandAreaMeters2': row['terrainReviewQueue']['sourceSourceClimbBandAreaMeters2'], 'connectedNavHeightSpanMeters': row['terrainReviewQueue']['connectedNavHeightSpanMeters'], 'admittedFaces': len(row['admittedSupportIndices'])} for row in report['records']]
    (directory / f'{name}-review-queue.json').write_text(json.dumps(rows, indent=2))
    print(name, 'priority', sum(row['priority'] for row in rows), 'of', len(rows), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('maps', nargs='+'); args = parser.parse_args()
    for name in args.maps:
        main(name)
