"""Check source ramp heights and preservation of the rest of the ground field."""
import json
from pathlib import Path
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import ROOT, read, planes
from compile_icebox_ramp_ground import DOMAINS, sha
from verify_icebox_regional_floors import svg_plane
from compile_reviewed_svg_height_map import polygon
from polygonal_area import polygonal


def verify(folder=Path('work/icebox-acceptance/ramp-ground'),
           source_path=Path('work/icebox-acceptance/regional-floors.json'),
           domain_ids=DOMAINS, removed_supports=(), candidate=False, physical_ground=False):
    source = read(source_path)
    alignment = read(ROOT / 'tactical-alignment-sides-v1/icebox.json')
    rows = []
    for side in ['attack', 'defense']:
        before = read(folder / f'before-{side}.json.gz')
        asset_path = folder/f'candidate-{side}.json.gz' if candidate else Path(f'assets/maps/icebox_svg_height_{side}.json.gz')
        current = read(asset_path)
        exclusions = ['ground', 'supports', 'version'] if physical_ground else ['ground', 'supports']
        assert all(current[k] == before[k] for k in before if k not in exclusions)
        if physical_ground:
            assert current['version'] == 3
        assert current['supports'] == [s for s in before['supports'] if s['id'] not in removed_supports]
        def mesh(model):
            vertices = np.array(model['ground']['vertices']).reshape(-1, 3)
            tri = vertices[np.array(model['ground']['triangles']).reshape(-1, 3)]
            return tri, shapely.polygons(tri[:, :, :2]), planes(tri)
        old_tri, old_shapes, old_planes = mesh(before)
        new_tri, new_shapes, new_planes = mesh(current)
        tree = shapely.STRtree(old_shapes)
        new_tree = shapely.STRtree(new_shapes)
        matrix = np.array(alignment[f'nativeTo{side.title()}Svg'])
        domains = [(affine_transform(shapely.from_geojson(json.dumps(d['nativeGeometry'])),
                       [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]]), svg_plane(d['nativePlane'], matrix))
                   for d in source['domains'] if d['id'] in domain_ids]
        if physical_ground:
            from compile_icebox_physical_ground import lowest_domains
            receiver = shapely.union_all([polygon(r) for r in current['receiver']])
            domains = lowest_domains([(shape.intersection(receiver), plane) for shape, plane in domains])
        domains = [(polygonal(shape), plane) for shape, plane in domains]
        domain_tree = shapely.STRtree([d[0] for d in domains])
        patch = shapely.union_all([d[0] for d in domains])
        old_union, new_union = shapely.union_all(old_shapes), shapely.union_all(new_shapes)
        expected_union = old_union.union(patch)
        missing = expected_union.symmetric_difference(new_union).area
        # Assess coordinate rounding by distance to the actual footprint,
        # rather than adding the areas of hundreds of nanometer-wide seams.
        missing_beyond_rounding = expected_union.difference(new_union.buffer(.001)).area + new_union.difference(expected_union.buffer(.001)).area
        assert missing_beyond_rounding < 1e-6, (missing, missing_beyond_rounding)
        errors = dict(outside=0., sourceDomains=0.)
        discrepancies = []
        boundary_remainder = []
        unchanged = {t.tobytes() for t in old_tri}
        standing_indices = set(current['ground'].get('standingTriangles', []))
        for index, (triangle, shape, plane) in enumerate(zip(new_tri, new_shapes, new_planes)):
            if triangle.tobytes() in unchanged and shape.intersection(patch).area < 1e-8:
                continue
            # Both ground models use the first covering triangle. Some old
            # triangles overlap at different heights; shadowed portions are
            # not observable and cannot establish an outside-field change.
            earlier = [new_shapes[i] for i in new_tree.query(shape, predicate='intersects') if i < index]
            shape = shape.difference(shapely.union_all(earlier))
            local_ids = sorted(domain_tree.query(shape, predicate='intersects'))
            local_patch = shapely.union_all([domains[i][0] for i in local_ids])
            outside = shape.difference(local_patch)
            if physical_ground and shape.area > 1e-10:
                marked = index in standing_indices
                if marked:
                    assert outside.difference(local_patch.buffer(.001)).area < 1e-8, (index, outside.area)
                else:
                    assert shape.intersection(local_patch.buffer(-.001)).area < 1e-8, index
            remaining = outside
            for i in sorted(tree.query(outside, predicate='intersects')):
                local = polygonal(remaining.intersection(old_shapes[i]))
                remaining = polygonal(remaining.difference(old_shapes[i]))
                if local.area > 1e-10:
                    xy = shapely.get_coordinates(local)
                    delta = plane - old_planes[i]
                    error = float(abs(xy @ delta[:2] + delta[2]).max())
                    if error > 1e-5 and local.difference(polygonal(patch).boundary.buffer(.001)).area < 1e-12:
                        boundary_remainder.append(local)
                        continue
                    errors['outside'] = max(errors['outside'], error)
                    if error > 1e-5 and len(discrepancies) < 20:
                        discrepancies.append(dict(kind='outside', newTriangle=index, oldTriangle=int(i),
                            area=local.area, error=error, geometry=json.loads(shapely.to_geojson(local)),
                            actualPlane=plane.tolist(), expectedPlane=old_planes[i].tolist()))
            remaining = polygonal(shape.intersection(local_patch))
            for domain, expected in [domains[i] for i in local_ids]:
                local = polygonal(remaining.intersection(domain))
                remaining = polygonal(remaining.difference(domain))
                if local.area > 1e-10:
                    xy = shapely.get_coordinates(local)
                    delta = plane - expected
                    error = float(abs(xy @ delta[:2] + delta[2]).max())
                    errors['sourceDomains'] = max(errors['sourceDomains'], error)
                    if error > 1e-5 and len(discrepancies) < 20:
                        discrepancies.append(dict(kind='source', newTriangle=index, area=local.area,
                            error=error, geometry=json.loads(shapely.to_geojson(local)),
                            actualPlane=plane.tolist(), expectedPlane=expected.tolist()))
        (folder/f'preservation-diagnostics-{side}.json').write_text(json.dumps(dict(errors=errors, discrepancies=discrepancies), indent=2)+'\n')
        assert max(errors.values()) < 1e-5, errors
        boundary_area = shapely.union_all(boundary_remainder).area
        assert boundary_area < 1e-6, boundary_area
        rows.append(dict(side=side, assetSha256=sha(asset_path), missingFootprintAreaSvg=missing,
            missingFootprintBeyondBoundaryToleranceAreaSvg=missing_beyond_rounding,
            maximumHeightErrorMeters=errors, trianglesBefore=len(old_tri), trianglesAfter=len(new_tri)))
        rows[-1].update(boundaryToleranceSvg=.001, boundaryRoundingRemainderAreaSvg=boundary_area)
    report = dict(status='passed', sourceSha256=sha(source_path), rows=rows)
    (folder / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    verify()
