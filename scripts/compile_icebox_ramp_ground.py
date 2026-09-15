"""Replace interpolated ground on the two measured ordinary Icebox ramps.

The acceptance source inventory defines these ramp and landing domains before
the model is opened. Walls, supports, artwork, and unrelated ground are retained.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from audit_all_map_gameplay_levels import ROOT, read, planes
from verify_icebox_regional_floors import svg_plane, OVERLAY_PRECISION_SVG

OUT = Path('work/icebox-acceptance/ramp-ground')
DOMAINS = {'volume-5-0', 'volume-7-0', 'volume-126-0', 'volume-133-0',
           'volume-127-0', 'volume-121-0'}


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def triangles_in(shape):
    for part in shapely.get_parts(shape):
        if part.geom_type != 'Polygon' or part.area < 1e-12:
            continue
        for triangle in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
            xy = np.asarray(triangle.exterior.coords)[:3, :2]
            if abs(np.linalg.det(xy[1:] - xy[0])) > 1e-10:
                yield xy


def replace_ground(ground, domains, mark_standing=False, triangle_parents=None):
    vertices = np.asarray(ground['vertices']).reshape(-1, 3)
    faces = np.asarray(ground['triangles']).reshape(-1, 3)
    triangles = vertices[faces]
    shapes = shapely.set_precision(shapely.polygons(triangles[:, :, :2]), OVERLAY_PRECISION_SVG)
    domain_shapes = list(shapely.set_precision([d[0] for d in domains], OVERLAY_PRECISION_SVG))
    domain_tree = shapely.STRtree(domain_shapes)
    patch = shapely.union_all(domain_shapes)
    affected = set(shapely.STRtree(shapes).query(patch, predicate='intersects'))
    source_planes = planes(triangles)
    output_vertices = vertices.tolist()
    output_faces = []
    original_standing = set(ground.get('standingTriangles', []))
    output_standing = []

    def difference_local(shape, before=None):
        # Disjoint domains cannot remove any part of this shape. Query the
        # original polygons so small triangles never overlay the whole map.
        indices = domain_tree.query(shape, predicate='intersects')
        local = [domain_shapes[i] for i in indices if before is None or i < before]
        return shape.difference(shapely.union_all(local)) if local else shape

    def append(shape, plane, standing=False, parent=None):
        for xy in triangles_in(shape):
            start = len(output_vertices)
            output_vertices.extend(np.c_[xy, xy @ plane[:2] + plane[2]].tolist())
            if standing:
                output_standing.append(len(output_faces))
            output_faces.append([start, start + 1, start + 2])
            if triangle_parents is not None:
                triangle_parents.append(parent)

    for i, face in enumerate(faces):
        if i not in affected:
            if i in original_standing:
                output_standing.append(len(output_faces))
            output_faces.append(face.tolist())
            if triangle_parents is not None:
                triangle_parents.append([0, i])
        else:
            append(difference_local(shapes[i]), source_planes[i], i in original_standing, [0, i])
    for i, (_, plane) in enumerate(domains):
        shape = domain_shapes[i]
        # Standing-clearance measurement already removes competing bodies.
        # Shared numerical boundaries have zero area and one height owner.
        if shape.is_empty:
            continue
        append(difference_local(shape, before=i), plane, mark_standing, [1, i])
    result = dict(vertices=np.asarray(output_vertices).reshape(-1).tolist(),
                  triangles=np.asarray(output_faces).reshape(-1).tolist())
    if mark_standing or 'standingTriangles' in ground:
        result['standingTriangles'] = output_standing
    return result, len(affected)


def build(install=False):
    OUT.mkdir(parents=True, exist_ok=True)
    source_path = Path('work/icebox-acceptance/regional-floors.json')
    source = read(source_path)
    selected = [d for d in source['domains'] if d['id'] in DOMAINS]
    assert len(selected) == len(DOMAINS)
    alignment = read(ROOT / 'tactical-alignment-sides-v1/icebox.json')
    records = []
    for side in ['attack', 'defense']:
        asset = Path(f'assets/maps/icebox_svg_height_{side}.json.gz')
        before = OUT / f'before-{side}.json.gz'
        if not before.exists():
            before.write_bytes(asset.read_bytes())
        model = read(before)
        matrix = np.array(alignment[f'nativeTo{side.title()}Svg'])
        domains = [(affine_transform(shapely.from_geojson(json.dumps(d['nativeGeometry'])),
                       [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]]),
                    svg_plane(d['nativePlane'], matrix)) for d in selected]
        ground, count = replace_ground(model['ground'], domains)
        candidate = dict(model, ground=ground)
        path = OUT / f'candidate-{side}.json.gz'
        previous_candidate = sha(path) if path.exists() else None
        path.write_bytes(gzip.compress(json.dumps(candidate, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
        assert all(model[k] == candidate[k] for k in model if k != 'ground')
        if install:
            assert sha(asset) in [sha(before), sha(path), previous_candidate], 'Asset changed since this source correction was prepared.'
            asset.write_bytes(path.read_bytes())
        records.append(dict(side=side, beforeSha256=sha(before), candidateSha256=sha(path),
            replacedGroundTriangles=count, patchAreaSvg=shapely.union_all([d[0] for d in domains]).area))
    report = dict(sourceSha256=sha(source_path), sourceDomains=sorted(DOMAINS),
        scope='Measured ordinary ramps and their landing floors. Original ground interpolation retained outside these source domains.',
        records=records, installed=install)
    (OUT / 'source-review.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install', action='store_true')
    build(parser.parse_args().install)
