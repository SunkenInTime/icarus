"""Bake measured ordinary floors and distinguish them from reference ground."""
import argparse
from collections import defaultdict
import gzip
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from audit_all_map_gameplay_levels import ROOT, read
from build_all_map_gameplay_supports import plane_region
from compile_icebox_ramp_ground import replace_ground, sha
from compile_reviewed_svg_height_map import polygon, rings
from verify_icebox_regional_floors import svg_plane, applicable_domain, area_shape, OVERLAY_PRECISION_SVG
from polygonal_area import polygonal
from source_geometry_projection import project_source

FLOOR_OBJECTS = {
    4567: 'Port_Art_DefSpawn/Floor_1_DefenderA/StaticMeshComponent0.1076',
    4697: 'Port_Art_Mid/Floor_4_MidADU/StaticMeshComponent0.1206',
    4835: 'Port_Art_SnowAll/Snow_0_SnowPileGroundA21/StaticMeshComponent0.1348',
    4836: 'Port_Art_SnowAll/Snow_0_SnowPileGroundA22/StaticMeshComponent0.1349',
}
LANDINGS = {f'volume-{i}-0' for i in [121, 126, 127, 129, 133]}
# Source plane constants are rounded to 0.1 mm. Admit half that rounding step.
# The 2 cm source-validation tolerance must never merge selectable levels.
MATCHING_HEIGHT_TOLERANCE = .00005
# The reviewed local pipe faces sit below this player collider. Carry the
# existing display name to the measured level; this does not admit a surface.
SOURCE_SUPPORT_NAMES = {
    '/Port_BVPawn/BP_BlockingVolume134/Cube#0': 'icebox-a-boost-pipes-low-step',
    '/Port_BVPawn/BP_BlockingVolume2/Cube#0': 'icebox-a-boost-pipes-top',
    '/Port_BVPawn/BP_BlockingVolume73/Cube#0': 'icebox-a-stacked-b-interior-floor',
    '/Port_BVPawn/BP_BlockingVolume78/Cube#0': 'icebox-a-stacked-interior-floor',
}


def lowest_domains(domains):
    """Retain the lower ordinary floor when source-defined levels overlap."""
    domains = [(area_shape(shape), plane) for shape, plane in domains]
    tree = shapely.STRtree([shape for shape, _ in domains])
    result = []
    for shape, plane in domains:
        lower = []
        for i in tree.query(shape, predicate='intersects'):
            other, other_plane = domains[i]
            lower.append(plane_region(shape.intersection(other), other_plane - plane, -1e6, -1e-7))
        result.append((area_shape(shape.difference(shapely.union_all(lower))), plane))
    return result


def emitted_ground_domains(ground, triangle_parents, domains):
    """Only triangles in the baked ground can replace a selectable support."""
    vertices = np.asarray(ground['vertices']).reshape(-1, 3)
    triangles = vertices[np.asarray(ground['triangles']).reshape(-1, 3)]
    assert len(triangles) == len(triangle_parents)
    shapes = [area_shape(shapely.Polygon(triangle[:, :2])) for triangle in triangles]
    tree = shapely.STRtree(shapes)
    parts = defaultdict(list)
    for index, (shape, parent) in enumerate(zip(shapes, triangle_parents)):
        if parent[0] == 1:
            # Runtime returns the first covering triangle, including reference
            # ground. An obscured physical triangle cannot supply its level.
            earlier = [shapes[i] for i in tree.query(shape, predicate='intersects') if i < index]
            owned = polygonal(shape.difference(shapely.union_all(earlier))) if earlier else shape
            parts[parent[1]].append(owned)
    # Projection and partitioning each round to the overlay grid. Keep source
    # level choices along those edges; only the stable ground interior replaces
    # them. This removes coverage credit, never expands a standing domain.
    return [(polygonal(shapely.union_all(parts[i])).buffer(
                -2 * OVERLAY_PRECISION_SVG, join_style='mitre').intersection(shape), plane)
            for i, (shape, plane) in enumerate(domains) if i in parts]


def reconcile_supports(model, source_domains, ground_domains, region, ground_objects=FLOOR_OBJECTS, map_name='icebox'):
    """Use measured levels inside the audited region, retaining saved IDs."""
    # All operands share the SVG overlay grid. A floating intersection at
    # coincident floor edges can otherwise invent coverage outside either input.
    source_domains = [(item, area_shape(shape), plane) for item, shape, plane in source_domains]
    ground_domains = [(area_shape(shape), plane) for shape, plane in ground_domains]
    region = area_shape(region)
    source_tree = shapely.STRtree([shape for _, shape, _ in source_domains])
    supports, evidence = [], []
    original_supports = {s['id']: s for s in model['supports']}

    def encoded(shape):
        def area(ring):
            xy = np.array(ring).reshape(-1, 2)
            xy -= xy[0].copy()
            total = 0.
            for i in range(len(xy)):
                a, b = xy[i], xy[(i + 1) % len(xy)]
                total += a[0] * b[1] - a[1] * b[0]
            return total
        result = []
        for part in shapely.get_parts(polygonal(shape)):
            contours = rings(part)
            if area(contours[0]) == 0:
                continue
            result.extend(ring for ring in contours if area(ring) != 0)
        return result

    for support in model['supports']:
        if not support.get('automaticStandingAllowed'):
            supports.append(support)
            continue
        shape = area_shape(polygon(support))
        plane = np.asarray(support.get('surfacePlane') or [0., 0., support['surfaceElevationMeters']])
        inside = shape.intersection(region)
        matching = []
        named_matches = {}
        for i in source_tree.query(inside, predicate='intersects'):
            item, domain, expected = source_domains[i]
            matched = plane_region(inside.intersection(domain), plane - expected,
                -MATCHING_HEIGHT_TOLERANCE, MATCHING_HEIGHT_TOLERANCE)
            matching.append(matched)
            name_source = SOURCE_SUPPORT_NAMES.get(item.get('sourceCollision'))
            if original_supports.get(name_source, {}).get('label'):
                named_matches.setdefault(name_source, []).append(matched)
        kept = polygonal(shape.difference(region).union(shapely.union_all(matching)))
        removed = shape.difference(kept).area
        name_sources = [name for name, parts in named_matches.items()
            if not kept.is_empty and kept.difference(shapely.union_all(parts)).area <= 1e-10]
        label_source = None
        if support.get('label') in [None, 'Platform'] and len(name_sources) == 1:
            label_source = name_sources[0]
            support = dict(support, label=original_supports[label_source]['label'])
        if removed <= 1e-10:
            supports.append(support)
        elif not kept.is_empty:
            supports.append(dict(support, rings=encoded(kept)))
        evidence.append(dict(id=support['id'], removedAreaSvg=removed, retainedAreaSvg=kept.area,
            labelSourceSupportId=label_source))

    available = list(ground_domains)
    available.extend((area_shape(polygon(s)), np.asarray(s.get('surfacePlane') or [0., 0., s['surfaceElevationMeters']]))
        for s in supports if s.get('automaticStandingAllowed'))
    available_tree = shapely.STRtree([shape for shape, _ in available])
    added = []
    for item, shape, plane in source_domains:
        matched = []
        for i in available_tree.query(shape, predicate='intersects'):
            other, other_plane = available[i]
            matched.append(plane_region(shape.intersection(other), plane - other_plane,
                -MATCHING_HEIGHT_TOLERANCE, MATCHING_HEIGHT_TOLERANCE))
        remainder = polygonal(shape.difference(shapely.union_all(matched)))
        if remainder.is_empty:
            continue
        sid = f"{map_name}-measured-{item['id']}"
        contours = encoded(remainder)
        if not contours:
            continue
        name_source = SOURCE_SUPPORT_NAMES.get(item.get('sourceCollision'))
        label = original_supports.get(name_source, {}).get('label') or (
            'Ground' if item.get('sourceObject') in ground_objects else 'Platform')
        supports.append(dict(id=sid, label=label,
            rings=contours, fillRule='evenodd', floorElevationMeters=0.,
            heightAboveFloorMeters=float(plane[2]), surfaceElevationMeters=float(plane[2]),
            surfacePlane=plane.tolist(), automaticStandingAllowed=True))
        added.append(dict(id=sid, sourceDomain=item['id'], areaSvg=remainder.area,
            labelSourceSupportId=name_source if name_source in original_supports else None))
    return supports, dict(existing=evidence, added=added)


def build(source_dir, output, ground_review=None, baseline=None):
    algorithm_paths = [Path(__file__), Path(__file__).with_name('compile_icebox_ramp_ground.py'),
        Path(__file__).with_name('polygonal_area.py'), Path(__file__).with_name('source_geometry_projection.py'),
        Path(__file__).with_name('verify_icebox_regional_floors.py')]
    algorithm_hashes = {p.name: sha(p) for p in algorithm_paths}
    output.mkdir(parents=True, exist_ok=True)
    archive = output/'algorithm-sources'
    archive.mkdir(exist_ok=True)
    for path in algorithm_paths:
        archived = archive/path.name
        if archived.exists():
            assert sha(archived) == algorithm_hashes[path.name], 'Use a new output folder for a changed compiler.'
        else:
            archived.write_bytes(path.read_bytes())
        assert sha(archived) == algorithm_hashes[path.name]
    source_path = source_dir/'regional-floors.json'
    source = read(source_path)
    assert not source['unresolvedInfluencingCollision']
    inventory = read(source_dir/'source-inventory.json')
    map_name = inventory.get('map', 'icebox')
    assert source['sourceInventorySha256'] == sha(source_dir/'source-inventory.json')
    objects = {r['sourceObject']: r for r in inventory['inventory']}
    review = read(ground_review) if ground_review else None
    if review:
        assert review['sourceInventorySha256'] == sha(source_dir/'source-inventory.json')
        assert review['sourceCollidersSha256'] == sha(source_dir/'source-colliders.json')
    floor_objects = {int(k): v for k, v in review['sourceObjects'].items()} if review else (
        FLOOR_OBJECTS if map_name == 'icebox' else {})
    floor_collisions = set(review['sourceCollisions']) if review else set()
    for oid, path in floor_objects.items():
        assert objects[oid]['path'] == path
        assert objects[oid]['reason'] == 'declared-pawn-blocking-complex'
    selected = [d for d in source['domains'] if d.get('sourceObject') in floor_objects
        or d.get('sourceCollision') in floor_collisions
        or 'WalkableBlockingVolumeSlope' in d.get('sourceCollision', '')
        or (map_name == 'icebox' and d['id'] in LANDINGS)]
    assert selected
    alignment = read(ROOT/f'tactical-alignment-sides-v1/{map_name}.json')
    records = []
    for side in ['attack', 'defense']:
        asset = Path(f'assets/maps/{map_name}_svg_height_{side}.json.gz')
        before = output/f'before-{side}.json.gz'
        original = baseline/f'before-{side}.json.gz' if baseline else asset
        if not before.exists():
            before.write_bytes(original.read_bytes())
        elif baseline:
            assert sha(before) == sha(original), 'Frozen baseline changed.'
        model = read(before)
        assert not any(s['id'].startswith(f'{map_name}-measured-') for s in model['supports']), \
            'Rebuild measured supports from the original baseline, not a previous compiled candidate.'
        receiver = area_shape(shapely.union_all([polygon(r) for r in model['receiver']]))
        matrix = np.array(alignment[f'nativeTo{side.title()}Svg'])
        domains = [(area_shape(project_source(shapely.from_geojson(json.dumps(d['nativeGeometry'])),
            [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]])).intersection(receiver),
            svg_plane(d['nativePlane'], matrix)) for d in selected]
        domains = lowest_domains(domains)
        triangle_parents = []
        ground, count = replace_ground(model['ground'], domains, mark_standing=True, triangle_parents=triangle_parents)
        parent_path = output/f'ground-triangle-parents-{side}.json'
        parent_path.write_text(json.dumps(triangle_parents, separators=(',', ':'))+'\n')
        transform = [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]]
        source_domains = [(d, area_shape(project_source(shapely.from_geojson(json.dumps(d['nativeGeometry'])), transform)).intersection(receiver),
            svg_plane(d['nativePlane'], matrix)) for d in source['domains']]
        wall_shapes = [area_shape(polygon(w)) for w in model['walls']]
        wall_tree = shapely.STRtree(wall_shapes)
        applicable = []
        for item, shape, plane in source_domains:
            indices = wall_tree.query(shape, predicate='intersects')
            applicable.append((item, applicable_domain(shape, plane, [model['walls'][i] for i in indices],
                [wall_shapes[i] for i in indices]), plane))
        region = affine_transform(shapely.from_geojson(json.dumps(inventory['sourceRegion'])), transform)
        represented_ground = emitted_ground_domains(ground, triangle_parents, domains)
        supports, support_evidence = reconcile_supports(model, applicable, represented_ground, region, floor_objects, map_name)
        candidate = dict(model, version=3, ground=ground, supports=supports)
        path = output/f'candidate-{side}.json.gz'
        path.write_bytes(gzip.compress(json.dumps(candidate, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
        records.append(dict(side=side, beforeSha256=sha(before), candidateSha256=sha(path),
            replacedGroundTriangles=count, physicalGroundTriangles=len(ground['standingTriangles']),
            groundTriangles=len(ground['triangles'])//3, supportChanges=support_evidence))
        records[-1]['groundTriangleParentsSha256'] = sha(parent_path)
    report = dict(map=map_name, sourceSha256=sha(source_path), sourceInventorySha256=sha(source_dir/'source-inventory.json'),
        groundSourceDomains=[d['id'] for d in selected], groundSourceObjects=floor_objects,
        groundReviewSha256=sha(ground_review) if ground_review else None,
        matchingHeightToleranceMeters=MATCHING_HEIGHT_TOLERANCE,
        records=records, installed=False, algorithmSha256=algorithm_hashes,
        scope='Measured ordinary floors, snow and ramps. Reference interpolation retains explicit saved heights; only certified ground can outrank verified supports.')
    (output/'source-review.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(dict(sourceDomains=len(selected), records=[{k: v for k, v in r.items() if k != 'supportChanges'} for r in records])))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path('work/icebox-expanded-v2'))
    parser.add_argument('--output', type=Path, default=Path('work/icebox-expanded-v2/physical-ground'))
    parser.add_argument('--ground-review', type=Path)
    parser.add_argument('--baseline', type=Path, help='Folder containing the frozen before-attack/defense assets.')
    args = parser.parse_args()
    build(args.source, args.output, args.ground_review, args.baseline)
