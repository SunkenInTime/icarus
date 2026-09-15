"""Quantify steep admitted source support against actual detailed nav planes."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from probe_source_floor_regressions import load_support


def audit(name, revision, out):
    support = load_support(revision, name, True)
    source_count = int(np.count_nonzero(support.source_ids >= 0))
    points = support.points[:source_count]
    normals = np.cross(points[:, 1] - points[:, 0], points[:, 2] - points[:, 0])
    lengths = np.linalg.norm(normals, axis=1)
    normals /= lengths[:, None]
    steep = np.flatnonzero(normals[:, 2] < .65)
    nav_ids = support.detailed_navigation_indices
    tree = shapely.STRtree(support.polygons[nav_ids])
    local_source, local_nav = tree.query(support.polygons[steep])
    source_ids, matched_nav = steep[local_source], nav_ids[local_nav]
    overlap = shapely.intersection(support.polygons[source_ids], support.polygons[matched_nav])
    area = shapely.area(overlap)
    good = area > 1e-10
    source_ids, matched_nav, overlap, area = source_ids[good], matched_nav[good], overlap[good], area[good]
    xy, owners = shapely.get_coordinates(overlap, return_index=True)
    difference = support.planes[source_ids] - support.planes[matched_nav]
    height_gap = np.sum(xy * difference[owners, :2], axis=1) + difference[owners, 2]
    low, high = np.full(len(source_ids), np.inf), np.full(len(source_ids), -np.inf)
    np.minimum.at(low, owners, height_gap); np.maximum.at(high, owners, height_gap)
    closest_gap = np.where((low <= 0) & (high >= 0), 0, np.minimum(abs(low), abs(high)))
    gradients = np.linalg.norm(difference[:, :2], axis=1)
    world = next(row for row in json.loads((revision.parent / 'completeness/combined-manifest-release-inputs-v2.json').read_text()) if row['map'] == name)
    metadata = json.loads((Path(world['combinedWorldFolder']) / 'geometry.json').read_text())
    correspondence = np.load(revision / f'full-height-input-v1/{name}/source-correspondence.npz')['sourceFaces']
    object_starts = np.asarray([row['firstFace'] for row in metadata['objects']])
    rows = []
    for source_index in np.unique(source_ids):
        pair_indices = np.flatnonzero(source_ids == source_index)
        face = int(support.source_ids[source_index]); original = int(correspondence[face])
        object_index = int(np.searchsorted(object_starts, original, side='right') - 1)
        index = int(pair_indices[np.argmin(closest_gap[pair_indices])])
        locally_close = pair_indices[closest_gap[pair_indices] <= .35]
        row = {'fullPackFace': face, 'originalSourceFace': original, 'supportIndex': int(source_index), 'sourceObjectIndex': object_index, 'objectPath': metadata['objects'][object_index]['path'], 'sourceFirstFace': metadata['objects'][object_index]['firstFace'], 'normalZ': float(normals[source_index, 2]), 'sourceGradient': support.planes[source_index, :2].tolist(), 'sourceGradientMagnitude': float(np.linalg.norm(support.planes[source_index, :2])), 'verticesNativeMeters': points[source_index].tolist(), 'projectedAreaMeters2': float(lengths[source_index] * abs(normals[source_index, 2]) / 2), 'navOverlapPairs': len(pair_indices), 'navOverlapAreaSumUpperBoundMeters2': float(area[pair_indices].sum()), 'minimumAbsoluteNavHeightGapMeters': float(closest_gap[index]), 'hasNavWithin35cm': bool(len(locally_close)), 'maximumGradientMismatchNearNav': float(gradients[locally_close].max()) if len(locally_close) else None, 'minimumGradientMismatchNearNav': float(gradients[locally_close].min()) if len(locally_close) else None, 'closestHeightNavPair': {'detailedNavSupportIndex': int(matched_nav[index]), 'navGradient': support.planes[matched_nav[index], :2].tolist(), 'gradientMismatch': float(gradients[index]), 'heightGapRangeMeters': [float(low[index]), float(high[index])], 'overlapGeojson': shapely.to_geojson(overlap[index])}}
        rows.append(row)
    rows.sort(key=lambda row: (row['hasNavWithin35cm'], row['maximumGradientMismatchNearNav'] or 0), reverse=True)
    support_meta_path = revision / f'source-floor-support-all-walkable-v1/{name}.floor-support.json'
    support_meta = json.loads(support_meta_path.read_text())
    summary = {'map': name, 'sourceSupportFaces': source_count, 'normalZBelow065': len(steep), 'negativeNormalZ': int(np.sum(normals[:, 2] < 0)), 'steepFacesOverlappingDetailedNav': len(rows), 'steepFacesWithin35cmOfDetailedNav': sum(row['hasNavWithin35cm'] for row in rows), 'nearNavGradientMismatchOver4': sum(row['hasNavWithin35cm'] and row['maximumGradientMismatchNearNav'] > 4 for row in rows), 'nearNavGradientMismatchOver10': sum(row['hasNavWithin35cm'] and row['maximumGradientMismatchNearNav'] > 10 for row in rows), 'nearNavGradientMismatchOver100': sum(row['hasNavWithin35cm'] and row['maximumGradientMismatchNearNav'] > 100 for row in rows), 'maximumNearNavGradientMismatch': max((row['maximumGradientMismatchNearNav'] or 0 for row in rows), default=0)}
    report = {'schemaVersion': 1, 'sourceGeometrySha256': metadata['geometrySha256'], 'fullHeightSourcePackSha256': support_meta['fullHeightSourcePackSha256'], 'supportSha256': support_meta['dataSha256'], 'productionMutation': False, 'scope': 'Source geometric normalZ<.65 is a diagnostic category only, not a recovered Valorant walkability limit. Exact positive-area intersections with all detailed nav layers; within35cm means height separation reaches that band somewhere on intersection. Gradient mismatch is meters of rise per horizontal meter. Repeated object paths remain separate by exact source object index.', 'summary': summary, 'rows': rows}
    (out / f'{name}.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(summary), flush=True)
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('maps', nargs='+'); args = parser.parse_args()
    revision = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    out = revision / 'steep-floor-support-audit-v1'; out.mkdir(exist_ok=True)
    summaries = [audit(name, revision, out) for name in args.maps]
    (out / 'summary.json').write_text(json.dumps(summaries, indent=2))
