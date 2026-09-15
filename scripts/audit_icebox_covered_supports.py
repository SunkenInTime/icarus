"""Reject lower-box remnants occupied by another box and the player capsule."""
import json
import hashlib
import numpy as np
import shapely

from audit_svg_source_height_associations import ROOT, REV
from compile_reviewed_svg_height_map import polygon


def main():
    output = REV / 'icebox-gameplay-audit-v3'
    decisions = json.loads((REV / 'icebox-elevation-reviewed-v2/icebox-decisions.json').read_text())
    source = ROOT.parent / '2026-09-04/all-map-properties-13.05/properties/ShooterGame/Content/Characters/_Core/BasePawn.json'
    pawn = json.loads(source.read_text())
    capsule = next(r for r in pawn if r.get('Name') == 'CollisionCylinder')
    radius_meters = capsule['Properties']['CapsuleRadius'] / 100
    objects = json.loads((ROOT / 'supplemented-v2/world/icebox/geometry.json').read_text())['objects']
    archive = np.load(ROOT / 'supplemented-v2/world/icebox/geometry.npz')
    matrix = np.array(json.loads((ROOT / 'tactical-alignment-sides-v1/icebox.json').read_text())['nativeToAttackSvg'])
    radius = radius_meters * np.linalg.norm(matrix[0, :2])
    candidates = [(i, o, np.array(o['boundsMeters'])) for i, o in enumerate(objects)
                  if any(k in o['path'].lower() for k in ('crate', 'container', 'box'))]
    cache, rejected = {}, []
    for support in decisions['supports']:
        domain = polygon(support)
        z = support['surfaceElevationMeters']
        own = set(support.get('sourceObjects', support.get('selectedSourceObjects', [])))
        for oid, obj, bounds in candidates:
            # Restrict to a box resting on this level and extending through the
            # capsule's full-radius cross-section. Do not reject underpasses.
            if oid in own or abs(bounds[0, 2] - z) > .1 or bounds[1, 2] < z + radius_meters:
                continue
            xy = np.array([[x, y] for x in bounds[:, 0] for y in bounds[:, 1]]) @ matrix[:, :2].T + matrix[:, 2]
            if not domain.intersects(shapely.box(*xy.min(0), *xy.max(0)).buffer(radius)):
                continue
            if oid not in cache:
                triangles = archive['points'][archive['faces'][obj['firstFace']:obj['firstFace'] + obj['faceCount']]]
                projected = triangles[:, :, :2] @ matrix[:, :2].T + matrix[:, 2]
                shapes = shapely.polygons(projected)
                cache[oid] = shapely.union_all(shapes[shapely.area(shapes) > 1e-10])
            body = cache[oid]
            clear = domain.difference(body.buffer(radius))
            if clear.area > 1e-8:
                continue
            rejected.append(dict(id=support['id'], sourceObjects=sorted(own), coveringObject=oid,
                coveringPath=obj['path'], surfaceElevationMeters=z, coveringHeightRange=bounds[:, 2].tolist(),
                remainingDomainAreaSvg=domain.area, physicalOverlapAreaSvg=domain.intersection(body).area,
                clearStandingCenterAreaSvg=clear.area,
                reason='The lower box top is occupied by a box resting on it. No center in the remaining support domain clears that body at the extracted standing capsule radius.'))
            break
    report = dict(capsuleRadiusMeters=radius_meters, capsuleSource=str(source),
        capsuleSourceSha256=hashlib.sha256(source.read_bytes()).hexdigest(), rejectedSupports=rejected,
        scope='Closed box/container bodies resting on existing explicit supports. No arbitrary minimum platform area; preserve every domain with capsule clearance.')
    (output / 'covered-support-review.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(dict(rejected=len(rejected), radiusMeters=radius_meters)))


if __name__ == '__main__':
    main()
