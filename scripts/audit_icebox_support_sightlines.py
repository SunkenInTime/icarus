"""Find SVG false-block candidates from explicit tops against raw mesh rays.

This is a discrepancy finder, not an automatic correction or gameplay proof.
Masked materials and source/art registration require review.
"""
import json
import math
import numpy as np
import shapely

from audit_svg_source_height_associations import ROOT, REV, EXCLUDED
from compile_reviewed_svg_height_map import polygon


def mesh_hit(triangles, origin, direction, limit):
    e1, e2 = triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0]
    h = np.cross(np.broadcast_to(direction, e2.shape), e2)
    det = np.einsum('ij,ij->i', e1, h)
    valid = abs(det) > 1e-10
    inv = np.zeros_like(det)
    inv[valid] = 1 / det[valid]
    s = origin - triangles[:, 0]
    u = inv * np.einsum('ij,ij->i', s, h)
    q = np.cross(s, e1)
    v = inv * np.einsum('ij,j->i', q, direction)
    t = inv * np.einsum('ij,ij->i', e2, q)
    valid &= (u >= -1e-7) & (v >= -1e-7) & (u + v <= 1 + 1e-7) & (t > 1e-5) & (t < limit)
    return float(t[valid].min()) if valid.any() else limit


def main():
    output = REV / 'icebox-gameplay-audit-v3'
    model = json.loads((output / 'models/icebox-attack.json').read_text())
    archive = np.load(ROOT / 'supplemented-v2/world/icebox/geometry.npz')
    objects = json.loads((ROOT / 'supplemented-v2/world/icebox/geometry.json').read_text())['objects']
    bounds = np.array([o['boundsMeters'] for o in objects])
    included = np.array([not any(s in o['path'].lower() for s in EXCLUDED) for o in objects])
    matrix = np.array(json.loads((ROOT / 'tactical-alignment-sides-v1/icebox.json').read_text())['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    scale = np.linalg.norm(matrix[0, :2])
    shapes = [polygon(w) for w in model['walls']]
    wall_tree = shapely.STRtree(shapes)
    records = []
    for support in model['supports']:
        origin = np.array(polygon(support).representative_point().coords)[0]
        native_xy = inverse @ (origin - matrix[:, 2])
        eye = support['surfaceElevationMeters'] + model['defaultCameraHeightMeters']
        limit = 40 / scale
        near = included & (bounds[:, 0, 2] <= eye) & (bounds[:, 1, 2] >= eye)
        near &= np.all(bounds[:, 0, :2] <= native_xy + limit, axis=1) & np.all(bounds[:, 1, :2] >= native_xy - limit, axis=1)
        triangles = np.concatenate([archive['points'][archive['faces'][objects[i]['firstFace']:objects[i]['firstFace'] + objects[i]['faceCount']]] for i in np.flatnonzero(near)])
        triangles = triangles[(triangles[:, :, 2].min(1) <= eye) & (triangles[:, :, 2].max(1) >= eye)]
        active = [any(lo + w['floorElevationMeters'] <= eye <= (float('inf') if hi is None else hi + w['floorElevationMeters']) for lo, hi in w['bands']) for w in model['walls']]
        for index in range(8):
            angle = index * math.pi / 4
            direction = np.array([math.cos(angle), math.sin(angle)])
            ray = shapely.LineString([origin, origin + direction * 40])
            first, wall_id = 40., None
            for wall_index in wall_tree.query(ray):
                if not active[wall_index]:
                    continue
                wall, shape = model['walls'][wall_index], shapes[wall_index]
                hit = shape.intersection(ray)
                if not hit.is_empty:
                    distance = shapely.Point(origin).distance(hit)
                    if distance < first:
                        first, wall_id = distance, wall['id']
            native_direction = inverse @ direction
            native_direction /= np.linalg.norm(native_direction)
            source_distance = mesh_hit(triangles, np.r_[native_xy, eye], np.r_[native_direction, 0.], limit) * scale
            records.append(dict(supportId=support['id'], label=support['label'], originSvg=origin.tolist(),
                eyeMeters=eye, directionRadians=angle, svgHit=first, wallId=wall_id, sourceMeshHit=source_distance,
                additionalSourceVisibilitySvg=source_distance-first))
        if len(records) % 160 == 0:
            print('checked', len(records), 'rays', flush=True)
    candidates = sorted([r for r in records if r['additionalSourceVisibilitySvg'] > 3], key=lambda r: -r['additionalSourceVisibilitySvg'])
    (output / 'support-sightline-discrepancies.json').write_text(json.dumps(dict(
        scope='Eight horizontal source-mesh rays from each explicit support. Differences over three SVG units are review candidates, not automatic fixes. Alpha-masked materials are not resolved by this probe.',
        rays=len(records), supports=len(model['supports']), candidates=candidates, records=records), indent=2))
    print(json.dumps(dict(rays=len(records), candidates=len(candidates), affectedSupports=len({r['supportId'] for r in candidates}))))
    for row in candidates[:20]:
        print(row['supportId'], row['wallId'], round(row['svgHit'], 2), round(row['sourceMeshHit'], 2))


if __name__ == '__main__':
    main()
