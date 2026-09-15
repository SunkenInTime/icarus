"""Check rebuilt triangles against their recorded source or original parent."""
import argparse
from collections import defaultdict
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from audit_all_map_gameplay_levels import ROOT, read
from compile_icebox_physical_ground import lowest_domains
from compile_icebox_ramp_ground import sha
from compile_reviewed_svg_height_map import polygon
from polygonal_area import polygonal
from source_geometry_projection import project_source
from verify_icebox_regional_floors import svg_plane

DISTANCE_TOLERANCE = .001
HEIGHT_TOLERANCE = 1e-5


def original_heights(triangle, xy):
    """Evaluate from local edge vectors, without fitting a global plane."""
    edges = triangle[1:, :2] - triangle[0, :2]
    weights = np.linalg.solve(edges.T, (xy - triangle[0, :2]).T).T
    return triangle[0, 2] + weights @ (triangle[1:, 2] - triangle[0, 2])


def geometry_error(actual, expected):
    if actual.is_empty or expected.is_empty:
        return actual.symmetric_difference(expected).area
    return (actual.difference(expected.buffer(DISTANCE_TOLERANCE)).area
            + expected.difference(actual.buffer(DISTANCE_TOLERANCE)).area)


def verify_ground(before, after, domains, parents):
    old = np.asarray(before['vertices']).reshape(-1, 3)[np.asarray(before['triangles']).reshape(-1, 3)]
    new = np.asarray(after['vertices']).reshape(-1, 3)[np.asarray(after['triangles']).reshape(-1, 3)]
    assert len(parents) == len(new)
    assert parents == sorted(parents), 'Original triangle priority changed.'
    old_shapes = shapely.polygons(old[:, :, :2])
    shapes = [d[0] for d in domains]
    tree = shapely.STRtree(shapes)
    groups = defaultdict(list)
    original_standing = set(before.get('standingTriangles', []))
    standing = set(after['standingTriangles'])
    maximum_height_error = 0.
    for i, (triangle, parent) in enumerate(zip(new, parents)):
        kind, index = parent
        assert kind in (0, 1)
        footprint = shapely.Polygon(triangle[:, :2])
        assert footprint.is_valid and footprint.area > 0
        if kind == 0:
            expected = original_heights(old[index], triangle[:, :2])
            physical = index in original_standing
        else:
            plane = domains[index][1]
            expected = triangle[:, :2] @ plane[:2] + plane[2]
            physical = True
        error = float(np.max(np.abs(triangle[:, 2] - expected)))
        maximum_height_error = max(maximum_height_error, error)
        assert error < HEIGHT_TOLERANCE, (i, parent, error)
        assert (i in standing) == physical, (i, parent, 'physical flag')
        groups[tuple(parent)].append(footprint)
    maximum_area_error = 0.
    for kind, sources in [(0, old_shapes), (1, shapes)]:
        for index, shape in enumerate(sources):
            overlaps = [shapes[j] for j in tree.query(shape, predicate='intersects')
                        if kind == 0 or j < index]
            expected = polygonal(shape.difference(shapely.union_all(overlaps))) if overlaps else shape
            actual = polygonal(shapely.union_all(groups.pop((kind, index), [])))
            error = geometry_error(actual, expected)
            maximum_area_error = max(maximum_area_error, error)
            assert error < 1e-6, (kind, index, error, expected.area, actual.area)
    assert not groups
    return dict(triangles=len(new), maximumVertexHeightErrorMeters=maximum_height_error,
                maximumParentCoverageErrorSvgSquared=maximum_area_error)


def verify_supports(before, after, region, label_sources=None):
    old = {s['id']: s for s in before}
    new = {s['id']: s for s in after}
    label_sources = label_sources or {}
    assert len(old) == len(before) and len(new) == len(after)
    for sid, support in old.items():
        if not support.get('automaticStandingAllowed'):
            assert new.get(sid) == support, sid
            continue
        original_outside = polygonal(polygon(support).difference(region))
        if sid not in new:
            assert original_outside.is_empty, sid
            continue
        current = new[sid]
        excluded = {'rings'}
        if sid in label_sources:
            assert support.get('label') in [None, 'Platform'], sid
            assert polygonal(polygon(current).difference(region)).is_empty, sid
            assert current['label'] == old[label_sources[sid]]['label'], sid
            excluded.add('label')
        assert {k: v for k, v in support.items() if k not in excluded} == {
            k: v for k, v in current.items() if k not in excluded}, sid
        actual_outside = polygonal(polygon(current).difference(region))
        assert geometry_error(actual_outside, original_outside) < 1e-6, sid
    for sid in new.keys() - old.keys():
        assert geometry_error(polygonal(polygon(new[sid]).difference(region)), shapely.Polygon()) < 1e-6, sid
    assert label_sources.keys() <= old.keys() & new.keys()
    return dict(originalSupports=len(old), candidateSupports=len(new), inheritedSupportLabels=len(label_sources))


def verify(source_dir, candidate_dir):
    review = read(candidate_dir/'source-review.json')
    assert review['sourceSha256'] == sha(source_dir/'regional-floors.json')
    assert review['sourceInventorySha256'] == sha(source_dir/'source-inventory.json')
    source = read(source_dir/'regional-floors.json')
    inventory = read(source_dir/'source-inventory.json')
    by_id = {d['id']: d for d in source['domains']}
    selected = [by_id[sid] for sid in review['groundSourceDomains']]
    map_name = inventory.get('map', 'icebox')
    alignment = read(ROOT/f'tactical-alignment-sides-v1/{map_name}.json')
    results = []
    for record in review['records']:
        side = record['side']
        paths = [candidate_dir/f'before-{side}.json.gz', candidate_dir/f'candidate-{side}.json.gz',
                 candidate_dir/f'ground-triangle-parents-{side}.json']
        for path, key in zip(paths, ['beforeSha256', 'candidateSha256', 'groundTriangleParentsSha256']):
            assert sha(path) == record[key], (path, key)
        before, after, parents = map(read, paths)
        assert all(before[k] == after[k] for k in before if k not in ('ground', 'supports', 'version'))
        assert before.keys() == after.keys() and after['version'] == 3
        matrix = np.array(alignment[f'nativeTo{side.title()}Svg'])
        transform = [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]]
        receiver = shapely.union_all([polygon(r) for r in before['receiver']])
        domains = lowest_domains([(project_source(shapely.from_geojson(json.dumps(d['nativeGeometry'])),
            transform).intersection(receiver), svg_plane(d['nativePlane'], matrix)) for d in selected])
        result = verify_ground(before['ground'], after['ground'], domains, parents)
        region = affine_transform(shapely.from_geojson(json.dumps(inventory['sourceRegion'])), transform)
        labels = {r['id']: r['labelSourceSupportId'] for r in record['supportChanges']['existing']
            if r.get('labelSourceSupportId')}
        result.update(verify_supports(before['supports'], after['supports'], region, labels))
        result.update(side=side, candidateSha256=record['candidateSha256'])
        results.append(result)
        print(json.dumps(result), flush=True)
    report = dict(passed=True, sourceReviewSha256=sha(candidate_dir/'source-review.json'),
        algorithmSha256=sha(Path(__file__)), boundaryToleranceSvg=DISTANCE_TOLERANCE,
        heightToleranceMeters=HEIGHT_TOLERANCE, records=results)
    (candidate_dir/'preservation-verification.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--candidate-dir', type=Path, required=True)
    args = parser.parse_args()
    verify(args.source, args.candidate_dir)
