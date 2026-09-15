"""Find navigation-backed standing levels absent from SVG ground/supports."""
import gzip
import json
import numpy as np
import shapely

from audit_svg_source_height_associations import ROOT, REV
from compile_reviewed_svg_height_map import polygon


def planes(triangles):
    return np.linalg.solve(np.concatenate([triangles[:, :, :2], np.ones((len(triangles), 3, 1))], axis=2), triangles[:, :, 2, None])[:, :, 0]


def main():
    output = REV / 'icebox-gameplay-audit-v3'
    model = json.loads((output / 'models/icebox-attack.json').read_text())
    nav = json.loads(gzip.decompress((REV / 'baseline-world/icebox_navigation.json.gz').read_bytes()))
    ui = json.loads((REV / 'baseline-world/height_catalog.json').read_text())['maps']['icebox']['uiTransform']
    detail = nav['floorMesh']
    vertices = np.array(detail['vertices'], dtype=float).reshape(-1, 3)
    uv = vertices[:, :2] / detail['coordinateScale']
    vertices[:, 0] = (uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier'])
    vertices[:, 1] = -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])
    vertices[:, 2] /= 100
    faces = np.array(detail['triangles']).reshape(-1, 4)
    triangles = vertices[faces[np.array(nav['walkable'])[faces[:, 0]], 1:]]
    centers = triangles.mean(1)
    matrix = np.array(json.loads((ROOT / 'tactical-alignment-sides-v1/icebox.json').read_text())['nativeToAttackSvg'])
    svg = centers[:, :2] @ matrix[:, :2].T + matrix[:, 2]
    receiver = shapely.union_all([polygon(r) for r in model['receiver']])
    inside = shapely.contains_xy(receiver, svg[:, 0], svg[:, 1])
    centers, svg = centers[inside], svg[inside]
    ground = model['ground']
    print('ground keys',list(ground),flush=True)
    gv = np.array(ground['vertices']).reshape(-1, 3)
    gt = gv[np.array(ground['triangles']).reshape(-1, 3)]
    ground_tree = shapely.STRtree(shapely.polygons(gt[:, :, :2]))
    gp = planes(gt)
    covered = np.zeros(len(centers), dtype=bool)
    points = shapely.points(svg)
    sample_ids, ids = ground_tree.query(points, predicate='intersects')
    heights = np.sum(svg[sample_ids] * gp[ids, :2], axis=1) + gp[ids, 2]
    covered[sample_ids[abs(heights - centers[sample_ids, 2]) <= .15]] = True
    for support in model['supports']:
        covered |= shapely.contains_xy(polygon(support), svg[:, 0], svg[:, 1]) & (abs(centers[:, 2] - support['surfaceElevationMeters']) <= .15)
    missing, missing_svg = centers[~covered], svg[~covered]
    archive = np.load(ROOT / 'supplemented-v2/world/icebox/geometry.npz')
    objects = json.loads((ROOT / 'supplemented-v2/world/icebox/geometry.json').read_text())['objects']
    source = archive['points'][archive['faces']]
    normal = np.cross(source[:, 1] - source[:, 0], source[:, 2] - source[:, 0])
    selected = np.flatnonzero((abs(normal[:, 2]) > .7 * np.linalg.norm(normal, axis=1)) & (abs(normal[:, 2]) > 1e-9))
    source = source[selected]
    tree = shapely.STRtree(shapely.polygons(source[:, :, :2]))
    source_planes = planes(source)
    records = []
    ends = np.array([o['firstFace'] + o['faceCount'] for o in objects])
    for p, xy in zip(missing, missing_svg):
        ids = tree.query(shapely.Point(p[:2]), predicate='intersects')
        if not len(ids):
            continue
        heights = source_planes[ids, :2] @ p[:2] + source_planes[ids, 2]
        nearest = int(np.argmin(abs(heights - p[2])))
        if abs(heights[nearest] - p[2]) > .15:
            continue
        face = int(selected[ids[nearest]])
        oid = int(np.searchsorted(ends, face, side='right'))
        records.append(dict(sourceObject=oid, sourcePath=objects[oid]['path'], sourceFace=face,
            svg=xy.tolist(), sourceZ=float(heights[nearest]), navigationZ=float(p[2])))
    groups = []
    for oid in sorted({r['sourceObject'] for r in records}):
        rows = [r for r in records if r['sourceObject'] == oid]
        xy = np.array([r['svg'] for r in rows])
        groups.append(dict(sourceObject=oid, path=objects[oid]['path'], samples=len(rows),
            heightRange=[min(r['sourceZ'] for r in rows), max(r['sourceZ'] for r in rows)],
            svgBounds=[*xy.min(0), *xy.max(0)]))
    groups.sort(key=lambda r: -r['samples'])
    (output / 'missing-level-candidates.json').write_text(json.dumps(dict(scope='Walkable detailed navigation centroids within SVG receiver, absent within 15 cm from primary ground and explicit supports, corroborated by source triangles within 15 cm. This flags missing levels and source/art registration differences; review before adding.',
        navigationSamples=len(centers), uncoveredSamples=len(missing), sourceCorroborated=len(records), groups=groups, records=records), indent=2))
    print(json.dumps(dict(samples=len(centers), uncovered=len(missing), corroborated=len(records), objects=len(groups))),flush=True)
    for row in groups[:30]:
        print(row,flush=True)


if __name__ == '__main__':
    main()
