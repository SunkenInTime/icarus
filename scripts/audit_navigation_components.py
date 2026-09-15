"""Classify disconnected navigation from encoded footprints and source proximity."""
import argparse
import csv
import gzip
import hashlib
import json
from pathlib import Path
import re

import numpy as np
import shapely

from tactical_alignment_receiver import receiver_domain
from verify_display_warp_scope import mapped_domain


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def nearest_triangle_point(triangles, point):
    a, u, v = triangles[:, 0], triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0]
    delta = point - a
    uu, uv, vv = np.einsum('ij,ij->i', u, u), np.einsum('ij,ij->i', u, v), np.einsum('ij,ij->i', v, v)
    du, dv = np.einsum('ij,ij->i', delta, u), np.einsum('ij,ij->i', delta, v)
    den = uu * vv - uv * uv
    b, c = np.zeros(len(a)), np.zeros(len(a))
    valid = den > 1e-24
    b[valid] = (du[valid] * vv[valid] - dv[valid] * uv[valid]) / den[valid]
    c[valid] = (dv[valid] * uu[valid] - du[valid] * uv[valid]) / den[valid]
    inside = valid & (b >= 0) & (c >= 0) & (b + c <= 1)
    closest = a + b[:, None] * u + c[:, None] * v
    distances = np.full(len(a), np.inf)
    distances[inside] = np.sum((closest[inside] - point) ** 2, axis=1)
    for edge in range(3):
        start, direction = triangles[:, edge], triangles[:, (edge + 1) % 3] - triangles[:, edge]
        length = np.einsum('ij,ij->i', direction, direction)
        t = np.zeros(len(a))
        good = length > 0
        t[good] = np.clip(np.einsum('ij,ij->i', point - start[good], direction[good]) / length[good], 0, 1)
        candidate = start + t[:, None] * direction
        d = np.sum((candidate - point) ** 2, axis=1)
        better = d < distances
        distances[better], closest[better] = d[better], candidate[better]
    return distances, closest


class SourceObjects:
    def __init__(self, world):
        self.metadata = json.loads((world / 'geometry.json').read_text())
        arrays = np.load(world / 'geometry.npz')
        self.vertices, self.faces, self.materials = arrays['points'], arrays['faces'], arrays['material_indices']
        self.objects = self.metadata['objects']
        self.bounds = np.array([o['boundsMeters'] for o in self.objects])
        expected = 0
        for index, obj in enumerate(self.objects):
            if obj['firstFace'] != expected:
                raise ValueError('Source object face ranges do not partition geometry')
            expected += obj['faceCount']
            if obj['faceCount']:
                points = self.vertices[self.faces[obj['firstFace']:expected]].reshape(-1, 3)
                if (np.any(points.min(0) < self.bounds[index, 0] - 1e-6) or
                        np.any(points.max(0) > self.bounds[index, 1] + 1e-6)):
                    raise ValueError('Source object AABB is not conservative')
        if expected != len(self.faces):
            raise ValueError('Some source faces have no object identity')

    def nearest(self, point):
        # Object AABBs provide a lower bound. Every object that could beat the
        # current exact triangle distance is visited; this is not centroid KNN.
        outside = np.maximum(np.maximum(self.bounds[:, 0] - point, point - self.bounds[:, 1]) - 1e-6, 0)
        lower = np.sum(outside ** 2, axis=1)
        best = np.inf
        result = None
        tested = 0
        for index in np.argsort(lower):
            if lower[index] > best + 1e-14:
                break
            obj = self.objects[index]
            if obj['faceCount'] == 0:
                continue
            ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
            triangles = self.vertices[self.faces[ids]]
            distances, closest = nearest_triangle_point(triangles, point)
            chosen = int(np.argmin(distances))
            tested += len(ids)
            if distances[chosen] < best:
                best = float(distances[chosen])
                face = int(ids[chosen])
                triangle = triangles[chosen]
                normal = np.cross(triangle[1] - triangle[0], triangle[2] - triangle[0])
                normal /= max(np.linalg.norm(normal), 1e-30)
                material = self.metadata['materials'][int(self.materials[face])]
                result = {'sourceObjectPath': obj['path'], 'sourceObjectIndex': int(index),
                          'sourceFirstFace': obj['firstFace'], 'sourceFace': face,
                          'closestSourcePointMeters': closest[chosen].tolist(),
                          'distanceMeters': float(np.sqrt(best)), 'sourceFaceNormal': normal.tolist(),
                          'materialIndex': int(self.materials[face]),
                          'materialName': material.get('blenderName', material.get('name', material.get('source'))),
                          'materialCategory': material['category']}
        result['exactSourceTrianglesTested'] = tested
        return result


def native_vertices(data, scale, ui):
    values = np.array(data, dtype=float).reshape(-1, 3)
    uv = values[:, :2].copy() / scale
    values[:, 0] = (uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier'])
    values[:, 1] = -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])
    values[:, 2] /= 100
    return values


def classify(samples, painted_area):
    matched = [s['nearestSource'] for s in samples if s['nearestSource']['distanceMeters'] <= .05]
    if not matched:
        return 'unresolved navigation/source mismatch'
    paths = ' '.join('/'.join(s['sourceObjectPath'].split('/')[-2:]) for s in matched)
    if re.search(r'treeroot|flowerbed|planter|rock|rubble', paths, re.I):
        return 'source-backed terrain or planter; standing role needs scene review'
    if re.search(r'foliage|bush|(?:^|[_/])tree|grass|leaf|snowman|gravel|decal|effect|vfx|cautiontape', paths, re.I):
        return 'decorative-source overlap; support decision unresolved'
    if re.search(r'floor|shell[^/]*ground|stair|ramp|platform|bridge|balcony|catwalk|landing|ledge', paths, re.I):
        return 'source-backed structural floor or raised platform'
    if re.search(r'box|crate|container|barrel|pallet|bench|furniture|table|cabinet|truck|car|generator|tank|bin|booth|fan', paths, re.I):
        return 'source-backed prop top; standing/access needs scene review'
    if painted_area <= 1:
        return 'small source-backed patch; extraction fragment not established'
    return 'source-backed surface; structural role needs scene review'


def classification_evidence(records):
    for row in records:
        for sample in row['samples']:
            sample['classification'] = classify([sample], row['paintedAreaMeters2'])
        row['sourceClassifications'] = sorted(set(s['classification'] for s in row['samples']))
        row['hasStructuralSourceSample'] = any(s['classification'].startswith('source-backed structural') for s in row['samples'])
        row['mixedSourceRoles'] = len(row['sourceClassifications']) > 1
        row['classification'] = classify(row['samples'], row['paintedAreaMeters2'])


def write_tables(output, rows):
    headings = ['map', 'component', 'painted_m2', 'footprint_m2', 'floor_min_m', 'floor_max_m',
                'mixed_source_roles', 'sample_x_m', 'sample_y_m', 'sample_z_m', 'source_distance_m',
                'source_face', 'source_object_path', 'classification']
    for filename, selected in [
        ('priority-evidence.csv', [r for r in rows if r['paintedAreaMeters2'] > 1]),
        ('structural-priority.csv', [r for r in rows if r['paintedAreaMeters2'] > 1 and r['hasStructuralSourceSample']])
    ]:
        with (output / filename).open('w', newline='', encoding='utf-8') as stream:
            writer = csv.writer(stream); writer.writerow(headings)
            for row in selected:
                structural = [s for s in row['samples'] if s['classification'].startswith('source-backed structural')]
                sample = (structural or row['samples'])[0] if row['samples'] else None
                nearest = sample['nearestSource'] if sample else {}
                writer.writerow([row['map'], row['component'], row['paintedAreaMeters2'], row['footprintAreaMeters2'],
                                 *row['floorHeightMeters'], row['mixedSourceRoles'],
                                 *(sample['nativeFeetMeters'] if sample else ['', '', '']),
                                 nearest.get('distanceMeters'), nearest.get('sourceFace'), nearest.get('sourceObjectPath'),
                                 row['classification']])


def audit(name, root, output, main, catalog, world):
    revision = root / 'tactical-visibility-revision'
    nav_path = revision / f'baseline-world/{name}_navigation.json.gz'
    nav = json.loads(gzip.decompress(nav_path.read_bytes()))
    ui = catalog[name]['uiTransform']
    vertices = native_vertices(nav['vertices'], nav['coordinateScale'], ui)
    vertices[:, 2] = np.array(nav['refinedFloorHeightsCm']) / 100
    detail = nav['floorMesh']
    dv = native_vertices(detail['vertices'], detail['coordinateScale'], ui)
    df = np.array(detail['triangles']).reshape(-1, 4)
    detail_triangles = dv[df[:, 1:]]
    coarse_faces = np.array(nav['triangles']).reshape(-1, 4)
    detail_area = shapely.area(shapely.polygons(detail_triangles[:, :, :2]))
    display_path = revision / f'display-warps-v1/{name}.display-warp.json.gz'
    display = json.loads(gzip.decompress(display_path.read_bytes()))
    p = display['projection']; matrix = np.column_stack((p['axisU'], p['axisV'])); origin = np.array(p['origin']); inverse = np.linalg.inv(matrix)
    source = np.array(display['sourceNativeMeters']).reshape(-1, 2)
    target = (np.array(display['targetAttackSvg']).reshape(-1, 2) - origin) @ inverse.T
    triangles = np.array(display['triangles']).reshape(-1, 3)
    receiver_parts = []
    for side, suffix in [('attack', ''), ('defense', '_defense')]:
        path = Path(f'assets/maps/{name}_map{suffix}.svg')
        if sha(path) != display['art'][side]['sha256']:
            raise ValueError('Artwork changed')
        shape = receiver_domain(path)
        if side == 'defense':
            translation = np.array(display['attackToDefenseSvg']['origin'])
            shape = shapely.transform(shape, lambda xy: translation - xy)
        receiver_parts.append(shapely.transform(shape, lambda xy: (xy - origin) @ inverse.T))
    receiver = mapped_domain(shapely.union_all(receiver_parts), target, source, triangles)
    objects = SourceObjects(world)
    if objects.metadata['geometrySha256'] != catalog[name]['sourceGeometrySha256']:
        raise ValueError('Source geometry mismatch')
    components = np.array(nav['components'])
    walkable = np.array(nav['walkable'])
    records = []
    for component in sorted(set(components[walkable]) - {main}):
        parents = np.flatnonzero(walkable & (components == component))
        polygons = [shapely.Polygon(vertices[nav['polygons'][parent], :2]) for parent in parents]
        footprint = shapely.union_all(polygons)
        overlap = footprint.intersection(receiver)
        face_ids = np.flatnonzero(np.isin(df[:, 0], parents))
        used = np.unique(df[face_ids, 1:])
        floor_z = dv[used, 2] if len(used) else vertices[np.unique(np.concatenate([nav['polygons'][p] for p in parents])), 2]
        samples = []
        # Every parent is sampled; small floor patches must not be hidden by
        # larger props elsewhere in the same disconnected component.
        ranked = sorted(zip(parents, polygons), key=lambda pair: pair[1].intersection(receiver).area, reverse=True)
        for parent, shape in ranked:
            ids = face_ids[df[face_ids, 0] == parent]
            if not len(ids):
                coarse_ids = np.flatnonzero(coarse_faces[:, 0] == parent)
                if not len(coarse_ids):
                    continue
                coarse = vertices[coarse_faces[coarse_ids, 1:]]
                pick = int(np.argmax(shapely.area(shapely.polygons(coarse[:, :, :2]))))
                point = coarse[pick].mean(0)
                face = None
            else:
                centers = detail_triangles[ids].mean(1)
                painted = shapely.covers(receiver, shapely.points(centers[:, :2]))
                pool = ids[painted] if np.any(painted) else ids
                face = int(pool[np.argmax(detail_area[pool])])
                point = detail_triangles[face].mean(0)
            samples.append({'navParent': int(parent), 'detailedFloorTriangle': face,
                            'sampleBasis': 'detailed-navigation-floor' if face is not None else 'coarse-navigation-fallback-missing-detail',
                            'nativeFeetMeters': point.tolist(), 'nativeStandingEyeMeters': (point + [0, 0, 1.75]).tolist(),
                            'painted': bool(receiver.covers(shapely.Point(point[:2]))),
                            'nearestSource': objects.nearest(point)})
        records.append({'map': name, 'component': int(component), 'parents': parents.tolist(),
                        'navPolygonCount': len(parents), 'footprintAreaMeters2': float(footprint.area),
                        'paintedAreaMeters2': float(overlap.area), 'paintedFraction': float(overlap.area / footprint.area),
                        'floorHeightMeters': [float(floor_z.min()), float(floor_z.max())],
                        'footprintNativeGeojson': json.loads(shapely.to_geojson(footprint)),
                        'classification': classify(samples, overlap.area), 'samples': samples,
                        'priority': 'painted-over-one-square-meter' if overlap.area > 1 else 'smaller-or-unpainted',
                        'standingValidityCertified': False})
    records.sort(key=lambda r: r['paintedAreaMeters2'], reverse=True)
    classification_evidence(records)
    report = {'map': name, 'mainComponent': int(main), 'navigationSha256': sha(nav_path),
              'sourceGeometrySha256': objects.metadata['geometrySha256'], 'sourceMetadataSha256': sha(world / 'geometry.json'),
              'displayWarpSha256': sha(display_path), 'components': records,
              'sourceObjectBoundsVerifiedAgainstEveryTriangle': True,
              'method': 'Exact encoded navigation polygon union and detailed floor elevation ranges. Painted overlap uses both actual SVG receivers, curves bounded to 1e-5 SVG units, inverse mapped through reviewed W. Source proximity is exact triangle distance with conservative object AABB pruning, sampled in every walkable parent using detailed floor triangles or an explicitly flagged coarse fallback. Name-based structural labels are triage, not proof of jump accessibility or standing collision.'}
    (output / f'{name}.json').write_text(json.dumps(report, indent=2))
    print(name, len(records), sum(r['paintedAreaMeters2'] > 1 for r in records), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--maps', nargs='*')
    parser.add_argument('--from-reports', type=Path)
    args = parser.parse_args()
    revision = args.root / 'tactical-visibility-revision'
    catalog = json.loads((revision / 'baseline-world/height_catalog.json').read_text())['maps']
    main_ids = {r['map']: r['main'] for r in json.loads((revision / 'source-support-component-scope-review.json').read_text())}
    worlds = {r['map']: Path(r['combinedWorldFolder']) for r in json.loads((args.root / 'completeness/combined-manifest-release-inputs-v2.json').read_text())}
    args.output.mkdir(parents=True, exist_ok=False)
    reports = []
    for name in args.maps or catalog:
        if args.from_reports:
            source = args.from_reports / f'{name}.json'
            report = json.loads(source.read_text())
            classification_evidence(report['components'])
            report['reclassifiedFrom'] = {'path': str(source), 'sha256': sha(source)}
            (args.output / f'{name}.json').write_text(json.dumps(report, indent=2))
            reports.append(report)
        else:
            reports.append(audit(name, args.root, args.output, main_ids[name], catalog, worlds[name]))
    rows = [{k: r[k] for k in ['map', 'component', 'navPolygonCount', 'footprintAreaMeters2', 'paintedAreaMeters2', 'floorHeightMeters', 'classification', 'sourceClassifications', 'hasStructuralSourceSample', 'mixedSourceRoles', 'samples']}
            for report in reports for r in report['components']]
    rows.sort(key=lambda r: r['paintedAreaMeters2'], reverse=True)
    (args.output / 'summary.json').write_text(json.dumps({'maps': len(reports), 'nonmainComponents': len(rows), 'paintedOverOneSquareMeter': sum(r['paintedAreaMeters2'] > 1 for r in rows), 'rows': rows}, indent=2))
    write_tables(args.output, rows)


if __name__ == '__main__':
    main()
