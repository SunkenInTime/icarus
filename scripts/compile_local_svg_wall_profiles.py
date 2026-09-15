"""Partition only unresolved painted ink using measured local source profiles.

Existing finite gameplay corrections, map artwork, standing surfaces and saved
coordinate systems remain the inputs. Output is an external candidate pair.
"""
import argparse
from collections import defaultdict
import gzip
import hashlib
import json
import math
from pathlib import Path
import shutil

import numpy as np
import shapely
from shapely.affinity import affine_transform
from scipy.spatial import Voronoi

from audit_all_map_gameplay_levels import MAPS, ROOT, read
from compile_reviewed_svg_height_map import polygon, rings
from inventory_assumed_svg_heights import DESTINATION
from resolve_local_svg_wall_profiles import OUTPUT


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def unresolved(wall):
    return wall.get('unknownHeight', True) or any(high is None for _, high in wall['bands'])


def components(shape):
    pending = [shapely.make_valid(shape)]
    result = []
    while pending:
        part = pending.pop()
        if part.geom_type == 'Polygon':
            if part.area > 1e-12:
                result.append(part)
        elif part.geom_type in ['MultiPolygon', 'GeometryCollection']:
            pending.extend(shapely.get_parts(part))
    return result


def intersection(left, right):
    try:
        return left.intersection(right)
    except shapely.errors.GEOSException:
        # Authored mirrors can put a partition vertex within floating-point
        # noise of an edge. Retain ten decimal places for this overlay; the
        # whole-map painted-area invariant below still has to pass.
        left, right = shapely.make_valid(left), shapely.make_valid(right)
        return shapely.intersection(left, right, grid_size=1e-10)


def profile_height(sample, fallback_floor):
    if sample['status'] == 'navigation-passage':
        return 0., [b for b in sample['sourceBands'] if b[1] > b[0]], False
    if sample['status'] not in ['measured-facade', 'measured-ground-boundary']:
        return fallback_floor, [[0., None]], True
    floor = min(sample['measuredBottomMeters'], sample['floorElevationMeters'])
    top = sample['measuredTopMeters']
    if top < floor or (top == floor and sample['status'] != 'measured-ground-boundary'):
        raise ValueError('Source section has no positive extent')
    passages = sample.get('passageIntervalsMeters') or (
        [sample['passageIntervalMeters']] if sample.get('passageIntervalMeters') else [])
    if passages:
        navigation_floor = sample.get('navigationCrossing', {}).get('centerFloorMeters')
        if navigation_floor is not None and abs(navigation_floor - floor) <= .5:
            floor = min(floor, navigation_floor)
        measured_floor = floor
        # A passage starting exactly at ground still has a solid base below it.
        # Encode that base with a positive interval; runtime bands cannot have
        # zero thickness. The absolute opening and top elevations stay exact.
        floor -= 1.
        bands = []
        bottom = floor
        for below, above in sorted(passages):
            if not measured_floor <= below < above <= top or below < bottom:
                raise ValueError('Invalid or overlapping reviewed opening intervals')
            if below > bottom:
                bands.append([bottom - floor, below - floor])
            bottom = above
        if top > bottom:
            bands.append([bottom - floor, top - floor])
    else:
        # Zero-based bands already block below their base in the runtime.
        # Express a closed facade by its absolute top so interpolated floor
        # noise does not split one flat wall into hundreds of identical parts.
        # Round upward by at most 0.01 mm, below float32 mesh precision at
        # typical map coordinates. Exact measurements remain in the review.
        top = math.ceil(top * 100000) / 100000
        floor = 0. if top > 0. else top - 1.
        bands = [[0., top - floor]]
    return floor, bands, False


def nearest_sample_cells(points, shape):
    """Clip convex nearest-sample cells by their actual perpendicular bisectors.

    GEOS can return overlapping cells for almost coincident samples on opposite
    stroke edges. Qhull supplies only neighbor identities here; this explicit
    clipping computes each cell and retains the original artwork separately.
    """
    points = np.asarray(points, dtype=float)
    lower, upper = np.asarray(shape.bounds[:2]) - 1, np.asarray(shape.bounds[2:]) + 1
    origin = (lower + upper) / 2
    points = points - origin
    lower, upper = lower - origin, upper - origin
    rectangle = np.array([lower, [upper[0], lower[1]], upper, [lower[0], upper[1]]])
    neighbors = [set() for _ in points]
    if len(points) > 1:
        _, singular, axes = np.linalg.svd(points - points.mean(0), full_matrices=False)
        if len(points) < 3 or len(singular) < 2 or singular[1] < 1e-9:
            order = np.argsort(points @ axes[0])
            pairs = zip(order[:-1], order[1:])
        else:
            pairs = Voronoi(points).ridge_points
        for a, b in pairs:
            neighbors[a].add(b)
            neighbors[b].add(a)
    cells = []
    for i, point in enumerate(points):
        vertices = rectangle.copy()
        for j in sorted(neighbors[i]):
            normal = points[j] - point
            normal /= np.linalg.norm(normal)
            midpoint = (points[j] + point) / 2
            values = (vertices - midpoint) @ normal
            clipped = []
            for k, a in enumerate(vertices):
                b = vertices[(k + 1) % len(vertices)]
                va, vb = values[k], values[(k + 1) % len(vertices)]
                if va <= 0:
                    clipped.append(a)
                if (va <= 0) != (vb <= 0):
                    clipped.append(a + va / (va - vb) * (b - a))
            vertices = np.asarray(clipped)
            if len(vertices) < 3:
                break
        cells.append(shapely.Polygon(vertices + origin) if len(vertices) >= 3 else shapely.Polygon())
    return cells


def station_cells(profile, shape, fallback_floor):
    by_point = defaultdict(list)
    for index, sample in enumerate(profile['stations']):
        xy = sample.get('associationSvg', sample['svg'])
        by_point[tuple(round(value, 4) for value in xy)].append(index)
    points, samples, references = [], [], []
    for point, ids in by_point.items():
        # Coincident samples arise from opposite edges of one painted strip.
        # A measured source section supplies the same physical location when
        # the other edge's narrow source clipping missed that face.
        index = min(ids, key=lambda i: (
            profile['stations'][i]['status'] not in ['measured-facade', 'navigation-passage', 'measured-ground-boundary'],
            profile['stations'][i].get('registrationDistanceMeters', float('inf'))))
        points.append(point)
        samples.append(profile_height(profile['stations'][index], fallback_floor))
        references.append(ids)
    cells = nearest_sample_cells(points, shape)
    if len(cells) != len(points):
        raise ValueError('Incomplete source-height partition')
    return list(zip(cells, samples, references))


def encode(model, path):
    path.write_bytes(gzip.compress(json.dumps(model, separators=(',', ':'), allow_nan=False).encode(), mtime=0))


def compile_map(name, output=OUTPUT):
    directory = output / name
    for side in ['attack', 'defense']:
        seed = directory / f'seed-{side}.json.gz'
        if not seed.exists():
            shutil.copyfile(DESTINATION / name / f'candidate-{side}.json.gz', seed)
        frozen = directory / f'before-{side}.json.gz'
        if not frozen.exists():
            shutil.copyfile(DESTINATION / name / f'before-{side}.json.gz', frozen)
    for filename in ['assumed-height-review.json', 'assumed-height-sections.json',
                     'specific-height-review.json', 'defense-height-review.json']:
        origin = DESTINATION / name / filename
        target = directory / filename
        if origin.exists() and not target.exists():
            shutil.copyfile(origin, target)
    models = {side: read(directory / f'seed-{side}.json.gz') for side in ['attack', 'defense']}
    before = {side: read(directory / f'seed-{side}.json.gz') for side in models}
    inventory = read(directory / 'assumed-height-review.json')['records']
    by_id = {r['wallId']: r for r in inventory}
    profiles = read(directory / 'local-source-profiles.json')
    measured = {r['wallId']: r for r in profiles['records']}
    original_shapes = [polygon(r) for r in inventory]
    original_tree = shapely.STRtree(original_shapes)
    compiled, decisions, cells = [], [], {}
    for wall in models['attack']['walls']:
        if not unresolved(wall):
            compiled.append(wall)
            continue
        shape = polygon(wall)
        parents = [key for key in by_id if wall['id'] == key or wall['id'].startswith(key + '-')]
        if parents:
            parent = max(parents, key=len)
        else:
            possible = original_tree.query(shape, predicate='intersects')
            if not len(possible):
                raise ValueError((name, wall['id'], 'No original source review'))
            owner = max(possible, key=lambda i: shape.intersection(original_shapes[i]).area)
            parent = inventory[owner]['wallId']
        if parent not in cells:
            cells[parent] = station_cells(measured[parent], polygon(by_id[parent]), by_id[parent]['floorElevationMeters'])
        groups = defaultdict(list)
        references = defaultdict(list)
        for cell, height, source_indices in cells[parent]:
            piece = shape.intersection(cell)
            if piece.is_empty or piece.area <= 1e-12:
                continue
            key = json.dumps(height, separators=(',', ':'))
            groups[key].append(piece)
            references[key].extend(source_indices)
        assigned = []
        for group_index, (key, pieces) in enumerate(groups.items()):
            floor, bands, unknown = json.loads(key)
            domain = shapely.union_all(pieces)
            for part_index, part in enumerate(components(domain)):
                wid = f'{wall["id"]}-local-{group_index}-{part_index}'
                compiled.append(dict(id=wid, rings=rings(part), fillRule='evenodd',
                                     floorElevationMeters=floor, bands=bands, unknownHeight=unknown))
                decisions.append(dict(wallId=wid, parentWallId=parent,
                    sourceStationIndices=sorted(set(references[key])),
                    status='unresolved-source-section' if unknown else 'candidate-local-source-profile'))
                assigned.append(part)
        remaining = shape.difference(shapely.union_all(assigned))
        if remaining.area > 1e-7:
            raise ValueError((name, wall['id'], 'Unassigned literal ink', remaining.area))
        if abs(sum(p.area for p in assigned) - shape.area) > 1e-7:
            raise ValueError((name, wall['id'], 'Overlapping height partitions'))
    models['attack']['walls'] = compiled
    matrix = read(ROOT / f'tactical-alignment-sides-v1/{name}.json')
    a, b = [np.asarray(matrix[f'nativeTo{side}Svg']) for side in ['Attack', 'Defense']]
    linear = b[:, :2] @ np.linalg.inv(a[:, :2])
    shift = b[:, 2] - linear @ a[:, 2]
    transform = [*linear[0], *linear[1], *shift]
    reflected = [affine_transform(polygon(w), transform) for w in compiled]
    tree = shapely.STRtree(reflected)
    defense = []
    for wall in models['defense']['walls']:
        if not unresolved(wall):
            defense.append(wall)
            continue
        shape = polygon(wall)
        domains = []
        counter = 0
        for padding in [0., .01]:
            remaining = shape.difference(shapely.union_all(domains)) if domains else shape
            if remaining.area < 1e-10:
                break
            for index in tree.query(remaining.buffer(padding), predicate='intersects'):
                domain = reflected[index].buffer(padding) if padding else reflected[index]
                piece = intersection(remaining, domain)
                for part in components(piece):
                    source_wall = compiled[index]
                    wid = f'{wall["id"]}-local-{counter}'
                    counter += 1
                    defense.append(dict(id=wid, rings=rings(part), fillRule='evenodd',
                        floorElevationMeters=source_wall['floorElevationMeters'],
                        bands=source_wall['bands'], unknownHeight=source_wall['unknownHeight']))
                    decisions.append(dict(wallId=wid, side='defense',
                        attackWallId=source_wall['id'], correspondencePaddingSvg=padding))
                    domains.append(part)
        leftover = shape.difference(shapely.union_all(domains)) if domains else shape
        for part in components(leftover):
            # Mirrored authored paths and overlay arithmetic can leave a
            # sub-nanounit sliver against an already paired strip. Preserve
            # that ink and inherit the touching source section, rather than
            # manufacture an infinite-height record out of numerical noise.
            nearest = int(tree.nearest(part))
            numerical = (part.area <= 1e-9 or
                         (part.area <= 1e-7 and part.area / max(part.length, 1e-12) <= 1e-8))
            if numerical and part.distance(reflected[nearest]) <= .01:
                source_wall = compiled[nearest]
                wid = f'{wall["id"]}-local-numerical-{counter}'
                defense.append(dict(id=wid, rings=rings(part), fillRule='evenodd',
                    floorElevationMeters=source_wall['floorElevationMeters'],
                    bands=source_wall['bands'], unknownHeight=source_wall['unknownHeight']))
                decisions.append(dict(wallId=wid, side='defense',
                    attackWallId=source_wall['id'], correspondencePaddingSvg=.01,
                    numericalRemainderAreaSvg=part.area))
                counter += 1
                continue
            defense.append({**wall, 'id': f'{wall["id"]}-unpaired-{counter}', 'rings': rings(part)})
            counter += 1
    models['defense']['walls'] = defense
    from review_shared_svg_wall_edges import apply as apply_shared_edges
    decisions.extend(apply_shared_edges(name, models, directory, transform))
    from svg_wall_footprint_integrity import remove_collapsed_walls
    for side, model in models.items():
        model['walls'], remnants = remove_collapsed_walls(model['walls'])
        decisions.extend(dict(side=side, status='removed-numerical-remnant', **row)
                         for row in remnants)
    integrity = []
    for side, model in models.items():
        for key in before[side]:
            if key != 'walls' and before[side][key] != model[key]:
                raise ValueError((name, side, 'Non-wall data changed', key))
        union = lambda rows: shapely.union_all([shapely.make_valid(polygon(w)) for w in rows])
        difference = union(before[side]['walls']).symmetric_difference(union(model['walls'])).area
        if difference > 1e-7:
            raise ValueError((name, side, 'Painted ink changed', difference))
        path = directory / f'candidate-{side}.json.gz'
        encode(model, path)
        integrity.append(dict(side=side, walls=len(model['walls']),
            unresolvedRecords=sum(unresolved(w) for w in model['walls']),
            unresolvedPaintedAreaSvg=union([w for w in model['walls'] if unresolved(w)]).area,
            paintedAreaDifferenceSvg=difference, sha256=sha(path), compressedBytes=path.stat().st_size))
    (directory / 'compiled-height-profile-review.json').write_text(json.dumps(dict(
        schemaVersion=1, map=name, status='candidate-awaiting-source-and-gameplay-verification',
        sourceProfilesSha256=sha(directory / 'local-source-profiles.json'),
        records=decisions, integrity=integrity), separators=(',', ':')))
    print(name, json.dumps(integrity), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=MAPS)
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()
    for name in args.maps:
        compile_map(name, args.output)
