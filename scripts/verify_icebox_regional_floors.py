"""Compare source-defined regional levels with both bundled SVG height models."""
import hashlib
import argparse
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from audit_all_map_gameplay_levels import ROOT, read, planes
from build_all_map_gameplay_supports import plane_region
from compile_reviewed_svg_height_map import polygon
from polygonal_area import polygonal
from source_geometry_projection import project_source

OUT = Path('work/icebox-acceptance')
# Less than half a millimeter in this registration. The native correspondence
# audit allows about 0.12 mm, and derived polygons have their own coordinate
# rounding. A gap must be near a matching level, not merely thin, to qualify.
BOUNDARY_TOLERANCE_SVG = .001
# Overlay operands use a 10-nanounit grid. This is 100,000 times smaller
# than the declared boundary tolerance and avoids mixed-dimensional seams.
OVERLAY_PRECISION_SVG = 1e-8


def area_shape(shape):
    return shapely.set_precision(polygonal(shape), OVERLAY_PRECISION_SVG)


def svg_plane(native_plane, matrix):
    native_plane = np.asarray(native_plane)
    gradient = native_plane[:2] @ np.linalg.inv(matrix[:, :2])
    return np.r_[gradient, native_plane[2] - gradient @ matrix[:, 2]]


def applicable_domain(domain, expected_plane, walls, wall_shapes=None):
    blocked = []
    if wall_shapes is None:
        wall_shapes = [polygon(wall) for wall in walls]
    for wall, shape in zip(walls, wall_shapes):
        local = shape.intersection(domain)
        if local.is_empty:
            continue
        if wall.get('unknownHeight'):
            blocked.append(local)
            continue
        eye = expected_plane + [0, 0, 1.75 - wall['floorElevationMeters']]
        for low, high in wall['bands']:
            blocked.append(plane_region(local, eye, -1e6 if low == 0 else low, high))
    return polygonal(domain.difference(shapely.union_all(blocked)))


def compare(source, model, matrix, side):
    ground = np.asarray(model['ground']['vertices']).reshape(-1, 3)
    triangles = ground[np.asarray(model['ground']['triangles'], dtype=np.int64).reshape(-1, 3)]
    ground_shapes = shapely.set_precision(shapely.polygons(triangles[:, :, :2]), OVERLAY_PRECISION_SVG)
    ground_planes = planes(triangles)
    physical_ground = set(model['ground'].get('standingTriangles', [])) if model.get('version') == 3 else set(range(len(triangles)))
    tree = shapely.STRtree(ground_shapes)
    # Ground lookup uses the first covering triangle. Resolve that ownership
    # locally once, rather than subtracting thousands of triangles from each
    # large source floor again in both level and default checks.
    owned_ground = []
    for index, shape in enumerate(ground_shapes):
        earlier = [ground_shapes[i] for i in tree.query(shape, predicate='intersects') if i < index]
        owned_ground.append(polygonal(shape.difference(shapely.union_all(earlier))) if earlier else shape)
    receiver = area_shape(shapely.union_all([polygon(r) for r in model['receiver']]))
    supports = [(area_shape(polygon(s)), np.asarray(s.get('surfacePlane') or [0, 0, s['surfaceElevationMeters']]))
                for s in model['supports'] if s.get('automaticStandingAllowed')]
    support_tree = shapely.STRtree([s[0] for s in supports])
    wall_shapes = [area_shape(polygon(w)) for w in model['walls']]
    wall_tree = shapely.STRtree(wall_shapes)

    def clear(domain, plane):
        ids = wall_tree.query(domain, predicate='intersects')
        return applicable_domain(domain, plane, [model['walls'][i] for i in ids], [wall_shapes[i] for i in ids])

    expected_domains = []
    for item in source['domains']:
        native = shapely.from_geojson(json.dumps(item['nativeGeometry']))
        domain = area_shape(project_source(native, [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]]))
        plane = svg_plane(item['nativePlane'], matrix)
        required = domain.intersection(receiver)
        expected_domains.append((domain, required, clear(required, plane), plane))
    expected_tree = shapely.STRtree([d[2] for d in expected_domains])
    rows = []
    for item, (domain, required, applicable, expected) in zip(source['domains'], expected_domains):
        matching = []
        for index in sorted(tree.query(applicable, predicate='intersects')):
            local = applicable.intersection(owned_ground[index])
            matching.append(plane_region(local, ground_planes[index] - expected, -.02, .02))
        for index in support_tree.query(applicable, predicate='intersects'):
            shape, plane = supports[index]
            matching.append(plane_region(applicable.intersection(shape), plane - expected, -.02, .02))
        matched = shapely.union_all(matching)
        raw_missing = applicable.difference(matched)
        missing = applicable.difference(matched.buffer(BOUNDARY_TOLERANCE_SVG))
        samples = []
        for part in shapely.get_parts(missing):
            if part.area <= 1e-6:
                continue
            p = part.representative_point()
            samples.append(dict(svg=[p.x, p.y], expectedFloorMeters=float(expected[:2] @ [p.x, p.y] + expected[2])))

        # Establish the highest local physical level from source domains.
        # This expectation never uses the candidate's ground or supports.
        higher = []
        for i in expected_tree.query(applicable, predicate='intersects'):
            other = expected_domains[i]
            higher.append(plane_region(applicable.intersection(other[2]), other[3] - expected, 1e-7, 1e6))
        default_domain = applicable.difference(shapely.union_all(higher))
        correct, too_high = [], []
        for index in sorted(tree.query(default_domain, predicate='intersects')):
            if index not in physical_ground:
                continue
            local = default_domain.intersection(owned_ground[index])
            local = clear(local, ground_planes[index])
            delta = ground_planes[index] - expected
            correct.append(plane_region(local, delta, -.02, .02))
            too_high.append(plane_region(local, delta, .02, 1e6))
        for index in support_tree.query(default_domain, predicate='intersects'):
            shape, plane = supports[index]
            local = clear(default_domain.intersection(shape), plane)
            delta = plane - expected
            correct.append(plane_region(local, delta, -.02, .02))
            too_high.append(plane_region(local, delta, .02, 1e6))
        # Height-band clipping can retain isolated lines and points. They do
        # not cover floor area, and mixed-dimensional overlays are unstable.
        default_matched = polygonal(shapely.union_all(correct)).difference(polygonal(shapely.union_all(too_high)))
        default_missing = default_domain.difference(default_matched.buffer(BOUNDARY_TOLERANCE_SVG))
        default_samples = []
        for part in shapely.get_parts(default_missing):
            if part.area > 1e-6:
                p = part.representative_point()
                default_samples.append(dict(svg=[p.x, p.y], expectedFloorMeters=float(expected[:2] @ [p.x, p.y] + expected[2])))
        rows.append(dict(id=item['id'], side=side,
            sourceObject=item.get('sourceObject'), sourceCollision=item.get('sourceCollision'),
            sourceAreaSvg=domain.area, withinReceiverAreaSvg=required.area,
            excludedByActiveSvgWallAreaSvg=required.area - applicable.area,
            applicableAreaSvg=applicable.area, rawMissingAreaSvg=raw_missing.area, missingAreaSvg=missing.area,
            status='passed' if missing.area <= 1e-6 else 'missing-level',
            missingGeometry=json.loads(shapely.to_geojson(missing)), samples=samples,
            defaultAreaSvg=default_domain.area, defaultMissingAreaSvg=default_missing.area,
            defaultStatus='passed' if default_missing.area <= 1e-6 else 'wrong-default',
            defaultMissingGeometry=json.loads(shapely.to_geojson(default_missing)), defaultSamples=default_samples))
    return rows


def verify(output_dir=OUT, candidate_dir=None):
    algorithm_sha256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    source_path = output_dir / 'regional-floors.json'
    source = read(source_path)
    assert len({d['id'] for d in source['domains']}) == len(source['domains'])
    map_name = read(output_dir/'source-inventory.json').get('map', 'icebox')
    alignment = read(ROOT / f'tactical-alignment-sides-v1/{map_name}.json')
    rows, hashes = [], {}
    for side in ['attack', 'defense']:
        path = candidate_dir/f'candidate-{side}.json.gz' if candidate_dir else Path(f'assets/maps/{map_name}_svg_height_{side}.json.gz')
        hashes[side] = hashlib.sha256(path.read_bytes()).hexdigest()
        rows.extend(compare(source, read(path), np.array(alignment[f'nativeTo{side.title()}Svg']), side))
    failed = [r for r in rows if r['status'] != 'passed']
    default_failed = [r for r in rows if r['defaultStatus'] != 'passed']
    output = dict(map=map_name, status='passed' if not failed and not default_failed else 'floor-differences',
        heightToleranceMeters=.02, boundaryToleranceSvg=BOUNDARY_TOLERANCE_SVG,
        overlayPrecisionSvg=OVERLAY_PRECISION_SVG,
        sourceSha256=hashlib.sha256(source_path.read_bytes()).hexdigest(), assetSha256=hashes,
        algorithmSha256=algorithm_sha256,
        domainChecks=len(rows), failedDomainChecks=len(failed), failedDefaultDomainChecks=len(default_failed), rows=rows)
    ((candidate_dir or output_dir) / 'regional-floor-comparison.json').write_text(json.dumps(output, indent=2) + '\n')
    print(json.dumps({k: v for k, v in output.items() if k != 'rows'}), flush=True)
    for row in failed:
        print(json.dumps({k: row[k] for k in ['id', 'side', 'sourceCollision', 'missingAreaSvg', 'samples']}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=OUT)
    parser.add_argument('--candidate-dir', type=Path)
    args = parser.parse_args()
    verify(args.output, args.candidate_dir)
