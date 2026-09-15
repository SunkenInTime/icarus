"""Compare steep source floors with independent extracted Recast triangles."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely


def audit(name, revision):
    directory = revision / 'steep-floor-support-audit-v1'
    path = directory / f'{name}.json'
    report = json.loads(path.read_text())
    raw_path = revision.parent / f'nav/baked/{name}_source_xyz.json'
    nav_path = revision.parent / f'nav/baked/{name}_navigation.json'
    raw = json.loads(raw_path.read_text()); nav = json.loads(nav_path.read_text())
    assert raw['navigationSha256'] == hashlib.sha256(nav_path.read_bytes()).hexdigest()
    vertices = np.asarray(raw['vertices']).reshape(-1, 3) / 100
    vertices[:, 1] *= -1
    triangles = np.asarray(raw['triangles']).reshape(-1, 4)
    valid = np.asarray(nav['walkable'])[triangles[:, 0]]
    original_triangles = np.flatnonzero(valid)
    parents = triangles[valid, 0]
    points = vertices[triangles[valid, 1:]]
    shapes = shapely.polygons(points[:, :, :2])
    good = shapely.area(shapes) > 1e-12
    points, shapes, parents, original_triangles = points[good], shapes[good], parents[good], original_triangles[good]
    planes = np.linalg.solve(np.concatenate((points[:, :, :2], np.ones((len(points), 3, 1))), axis=2), points[:, :, 2, None])[:, :, 0]
    tree = shapely.STRtree(shapes)
    source_points = np.asarray([row['verticesNativeMeters'] for row in report['rows']])
    source_shapes = shapely.polygons(source_points[:, :, :2])
    source_planes = np.linalg.solve(np.concatenate((source_points[:, :, :2], np.ones((len(source_points), 3, 1))), axis=2), source_points[:, :, 2, None])[:, :, 0]
    a, b = tree.query(source_shapes)
    overlap = shapely.intersection(source_shapes[a], shapes[b])
    good = shapely.area(overlap) > 1e-10
    a, b, overlap = a[good], b[good], overlap[good]
    xy, owners = shapely.get_coordinates(overlap, return_index=True)
    differences = source_planes[a] - planes[b]
    delta = np.sum(xy * differences[owners, :2], axis=1) + differences[owners, 2]
    low, high = np.full(len(a), np.inf), np.full(len(a), -np.inf)
    np.minimum.at(low, owners, delta); np.maximum.at(high, owners, delta)
    height_gap = np.where((low <= 0) & (high >= 0), 0, np.minimum(abs(low), abs(high)))
    gradient = np.linalg.norm(differences[:, :2], axis=1)
    for index, row in enumerate(report['rows']):
        ids = np.flatnonzero(a == index)
        close = ids[height_gap[ids] <= .35]
        if len(ids):
            chosen = int(ids[np.argmin(height_gap[ids])])
            closest = {'rawTriangleIndex': int(original_triangles[b[chosen]]), 'nativeNavParent': int(parents[b[chosen]]), 'navVerticesNativeMeters': points[b[chosen]].tolist(), 'navGradient': planes[b[chosen], :2].tolist(), 'sourceMinusNavHeightRangeMeters': [float(low[chosen]), float(high[chosen])], 'gradientMismatch': float(gradient[chosen])}
        else:
            closest = None
        row['nativeRecastComparison'] = {'overlapPairs': len(ids), 'minimumHeightGapMeters': float(height_gap[ids].min()) if len(ids) else None, 'within35cm': bool(len(close)), 'minimumGradientMismatchWithin35cm': float(gradient[close].min()) if len(close) else None, 'maximumGradientMismatchWithin35cm': float(gradient[close].max()) if len(close) else None, 'closestHeightPair': closest}
    summary = {'map': name, 'sourceSteepRowsCompared': len(report['rows']), 'overlapNativeRecast': sum(row['nativeRecastComparison']['overlapPairs'] > 0 for row in report['rows']), 'within35cmNativeRecast': sum(row['nativeRecastComparison']['within35cm'] for row in report['rows'])}
    for threshold in [4, 10, 100]:
        summary[f'minimumGradientMismatchOver{threshold}'] = sum(row['nativeRecastComparison']['within35cm'] and row['nativeRecastComparison']['minimumGradientMismatchWithin35cm'] > threshold for row in report['rows'])
    report['independentNativeRecastEvidence'] = {'rawXYZPath': str(raw_path), 'rawXYZSha256': hashlib.sha256(raw_path.read_bytes()).hexdigest(), 'navigationPath': str(nav_path), 'navigationSha256': raw['navigationSha256'], 'scope': 'Original extracted Recast coarse vertices/triangles, with native Y-axis reflection and centimeters-to-meters only. No source floor refinement. Coarse voxel navigation is independent extraction, but is not exact game render geometry or a recovered walkability-angle rule.'}
    report['detailedComparisonLimitation'] = 'The existing detailed floorMesh was refined using source geometry. Its agreement is source-correlated and describes a selector input, not independent game walkability evidence.'
    report['nativeRecastSummary'] = summary
    path.write_text(json.dumps(report, indent=2))
    print(json.dumps(summary), flush=True)
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('maps', nargs='+'); args = parser.parse_args()
    revision = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    summary = [audit(name, revision) for name in args.maps]
    (revision / 'steep-floor-support-audit-v1/native-recast-summary.json').write_text(json.dumps(summary, indent=2))
