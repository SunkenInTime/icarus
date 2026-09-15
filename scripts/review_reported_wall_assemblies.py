"""Apply reviewed source-assembly heights without moving painted map walls."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from compile_reviewed_svg_height_map import polygon, rings
from review_icebox_gameplay_openings import vertical_intervals

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REVIEW = Path('scripts/data/fracture-reported-walls-2026-09-14.json')


def read(path):
    raw = path.read_bytes()
    return json.loads(gzip.decompress(raw) if path.suffix == '.gz' else raw)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(output, review_path=REVIEW):
    review = read(review_path)
    output.mkdir(parents=True, exist_ok=True)
    paths = {key: Path(value['path']) for key, value in review['sources'].items()}
    for key, path in paths.items():
        assert sha(path) == review['sources'][key]['sha256'], (key, 'source changed')
    standing_source = None
    if review.get('standingSource'):
        source_path = Path(review['standingSource']['path'])
        assert sha(source_path) == review['standingSource']['sha256']
        standing_source = read(source_path)
    objects = read(paths['metadata'])['objects']
    g = np.load(paths['geometry'])
    alignment = read(paths['alignment'])
    matrices = {side: np.asarray(alignment[f'nativeTo{side.title()}Svg']) for side in ['attack', 'defense']}
    a, b = matrices.values()
    linear = b[:, :2] @ np.linalg.inv(a[:, :2])
    offset = b[:, 2] - linear @ a[:, 2]
    reflection = [*linear[0], *linear[1], *offset]
    corrections = []
    for correction in review['corrections']:
        ids = np.concatenate([np.arange(objects[i]['firstFace'], objects[i]['firstFace'] + objects[i]['faceCount']) for i in correction['sourceObjects']])
        triangles = g['points'][g['faces'][ids]].astype(float)
        if correction.get('sectionSpace', 'attack-svg') == 'attack-svg':
            triangles[:, :, :2] = triangles[:, :, :2] @ a[:, :2].T + a[:, 2]
        measured = [vertical_intervals(triangles, s['axis'], s['cross'], s['along']) for s in correction['sections']]
        assert all(measured), correction['id']
        if correction['mode'] == 'complete-solid-facade':
            bands = [[0., max(band[1] for section in measured for band in section)]]
        elif correction['mode'] in ('framed-opening', 'open-measured-gap'):
            eye = correction['openingEyeMeters']
            lower = [band for section in measured for band in section if band[0] < eye]
            upper = [band for section in measured for band in section if band[1] >= eye]
            sill = max(band[1] for band in lower)
            header = min(band[0] for band in upper)
            top = max(band[1] for band in upper)
            assert sill < eye < header, (correction['id'], measured)
            bands = [[0., sill], [header, top]]
        else:
            raise ValueError(('Unknown reviewed mode', correction['mode']))
        corrections.append({**correction, 'measuredSections': measured, 'bands': bands,
                            'sourcePaths': [objects[i]['path'] for i in correction['sourceObjects']],
                            'sourceFaces': ids.tolist()})
    results = []
    for side in matrices:
        source = Path(review['baseline'][side]['path'])
        assert sha(source) == review['baseline'][side]['sha256']
        baseline = read(source)
        model = copy.deepcopy(baseline)
        changed = []
        for correction in corrections:
            clip = polygon(correction)
            if side == 'defense':
                clip = affine_transform(clip, reflection)
            if correction.get('sideRings'):
                clip = polygon(dict(rings=correction['sideRings'][side], fillRule='evenodd'))
            clip = shapely.set_precision(clip, 1e-8)
            parent = correction['parents'][side]
            walls = []
            selected = []
            for wall in model['walls']:
                if wall['id'] != parent and not wall['id'].startswith(parent + '-'):
                    walls.append(wall)
                    continue
                shape = polygon(wall)
                inside = shape.intersection(clip)
                if inside.area == 0:
                    walls.append(wall)
                    continue
                # Exact authored cell reflections are allowed only at the
                # common source overlay precision, never a visible buffer.
                if shape.difference(clip).area < 1e-10 and shape.hausdorff_distance(inside) < 1e-7:
                    inside = shape
                changed.append(inside)
                selected.append(inside)
                for label, domain in [('retained', shape.difference(inside)), ('reviewed', inside)]:
                    for part in shapely.get_parts(domain):
                        if part.geom_type != 'Polygon' or part.area == 0:
                            continue
                        record = dict(wall, id=f'{parent}-reported-{correction["id"]}-{label}-{len(walls)}', rings=rings(part), fillRule='evenodd')
                        if label == 'reviewed':
                            bands = correction['bands']
                            if correction['mode'] == 'open-measured-gap':
                                # Remove only the measured opening. Keep each
                                # cell's existing base and varying upper facade.
                                assert not wall['unknownHeight'] and wall['floorElevationMeters'] == 0.
                                sill, header = bands[0][1], bands[1][0]
                                bands = [piece for lo, hi in wall['bands']
                                         for piece in ([lo, min(hi, sill)], [max(lo, header), hi])
                                         if piece[1] > piece[0]]
                            record.update(floorElevationMeters=0., bands=bands, unknownHeight=False)
                        walls.append(record)
            model['walls'] = walls
            assert selected, (correction['id'], side, 'No wall matched')
            assert clip.difference(shapely.union_all(selected)).area < 1e-7, (
                correction['id'], side, 'Correction footprint was not fully assigned')
        assert changed
        from svg_wall_footprint_integrity import remove_collapsed_walls
        model['walls'], collapsed = remove_collapsed_walls(model['walls'])
        before = shapely.union_all([polygon(w) for w in baseline['walls']])
        after = shapely.union_all([polygon(w) for w in model['walls']])
        assert before.symmetric_difference(after).area < 1e-7
        restored = []
        if standing_source is not None:
            from source_geometry_projection import project_source
            from verify_icebox_regional_floors import applicable_domain, area_shape, svg_plane
            changed_area = shapely.union_all(changed)
            receiver = shapely.union_all([polygon(r) for r in model['receiver']])
            old_shapes = [polygon(w) for w in baseline['walls']]
            new_shapes = [polygon(w) for w in model['walls']]
            old_tree, new_tree = shapely.STRtree(old_shapes), shapely.STRtree(new_shapes)
            matrix = matrices[side]
            for item in standing_source['domains']:
                native = shapely.from_geojson(json.dumps(item['nativeGeometry']))
                domain = project_source(native, [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]])
                if not domain.intersects(changed_area):
                    continue
                domain = area_shape(domain.intersection(receiver).intersection(changed_area))
                plane = svg_plane(item['nativePlane'], matrix)
                old_ids = old_tree.query(domain, predicate='intersects')
                new_ids = new_tree.query(domain, predicate='intersects')
                old = applicable_domain(domain, plane, [baseline['walls'][i] for i in old_ids], [old_shapes[i] for i in old_ids])
                new = applicable_domain(domain, plane, [model['walls'][i] for i in new_ids], [new_shapes[i] for i in new_ids])
                added = area_shape(new.difference(old))
                if added.area < 1e-7:
                    continue
                sid = f'{review["map"]}-measured-{item["id"]}'
                support = next((s for s in model['supports'] if s['id'] == sid), None)
                if support is None:
                    p = added.representative_point()
                    z = float(plane @ [p.x, p.y, 1.])
                    support = dict(id=sid, label='Platform', fillRule='evenodd', floorElevationMeters=0.,
                                   heightAboveFloorMeters=z, surfaceElevationMeters=z, surfacePlane=plane.tolist(),
                                   automaticStandingAllowed=True)
                    model['supports'].append(support)
                    prior = shapely.Polygon()
                else:
                    prior = polygon(support)
                support['rings'] = [ring for part in shapely.get_parts(prior.union(added))
                                    if part.geom_type == 'Polygon' for ring in rings(part)]
                restored.append(dict(sourceDomain=item['id'], supportId=sid, addedAreaSvg=added.area))
        assert model['ground'] == baseline['ground'] and model['receiver'] == baseline['receiver']
        model['sourceReportedWallReviewSha256'] = sha(review_path)
        target = output / f'candidate-{side}.json.gz'
        target.write_bytes(gzip.compress(json.dumps(model, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
        results.append(dict(side=side, sha256=sha(target), changedAreaSvg=shapely.union_all(changed).area,
                            collapsedOverlayFragments=collapsed,
                            restoredStanding=restored))
    (output/'wall-review.json').write_text(json.dumps(dict(reviewSha256=sha(review_path), algorithmSha256=sha(Path(__file__)), corrections=corrections, results=results), indent=2)+'\n')
    print(json.dumps(results))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--review', type=Path, default=REVIEW)
    args = parser.parse_args()
    build(args.output, args.review)
