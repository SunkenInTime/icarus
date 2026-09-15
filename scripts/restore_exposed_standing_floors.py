"""Restore measured standing domains exposed by a reviewed wall-height change.

Compiled supports can omit floor under a previously active SVG wall. Opening
that wall must restore the independently measured floor, rather than leave its
reference ground to choose the observer height. Manual-only source domains are
deliberately absent from the automatic source list and remain untouched.
"""
import json

import numpy as np
import shapely

from compile_reviewed_svg_height_map import polygon, rings
from source_geometry_projection import project_source
from verify_icebox_regional_floors import applicable_domain, area_shape, svg_plane


def restore_exposed_floors(name, before, after, source, matrix):
    matrix = np.asarray(matrix)
    old_by_id = {w['id']: w for w in before['walls']}
    new_by_id = {w['id']: w for w in after['walls']}
    changed = []
    for key in old_by_id.keys() | new_by_id.keys():
        a, b = old_by_id.get(key), new_by_id.get(key)
        if a != b:
            changed.extend(polygon(w) for w in [a, b] if w is not None)
    region = shapely.union_all(changed)
    receiver = shapely.union_all([polygon(r) for r in after['receiver']])
    old_shapes = [polygon(w) for w in before['walls']]
    new_shapes = [polygon(w) for w in after['walls']]
    old_tree, new_tree = shapely.STRtree(old_shapes), shapely.STRtree(new_shapes)
    restored = []
    for item in source['domains']:
        native = shapely.from_geojson(json.dumps(item['nativeGeometry']))
        domain = project_source(native, [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]])
        if not domain.intersects(region):
            continue
        domain = area_shape(domain.intersection(receiver).intersection(region))
        plane = svg_plane(item['nativePlane'], matrix)
        old_ids = old_tree.query(domain, predicate='intersects')
        new_ids = new_tree.query(domain, predicate='intersects')
        old = applicable_domain(domain, plane, [before['walls'][i] for i in old_ids],
                                [old_shapes[i] for i in old_ids])
        new = applicable_domain(domain, plane, [after['walls'][i] for i in new_ids],
                                [new_shapes[i] for i in new_ids])
        added = area_shape(new.difference(old))
        if added.area < 1e-7:
            continue
        sid = f'{name}-measured-{item["id"]}'
        support = next((s for s in after['supports'] if s['id'] == sid), None)
        if support is None:
            point = added.representative_point()
            z = float(plane @ [point.x, point.y, 1.])
            support = dict(id=sid, label='Platform', fillRule='evenodd',
                           floorElevationMeters=0., heightAboveFloorMeters=z,
                           surfaceElevationMeters=z, surfacePlane=plane.tolist(),
                           automaticStandingAllowed=True)
            after['supports'].append(support)
            prior = shapely.Polygon()
        else:
            assert support.get('automaticStandingAllowed') is True, (
                sid, 'Do not override a manual standing decision')
            prior = polygon(support)
        support['rings'] = [ring for part in shapely.get_parts(prior.union(added))
                            if part.geom_type == 'Polygon' for ring in rings(part)]
        restored.append(dict(sourceDomain=item['id'], supportId=sid,
                             addedAreaSvg=added.area))
    assert before['ground'] == after['ground']
    assert before['receiver'] == after['receiver']
    return restored
