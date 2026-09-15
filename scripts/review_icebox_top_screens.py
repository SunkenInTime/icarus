"""Restore the gameplay-confirmed Top Screens standing surface on both sides."""
import gzip
import json
from pathlib import Path
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import ROOT, OUT, read, sample_domain
from build_all_map_gameplay_supports import navigation_triangles, standing_obstacles
from compile_reviewed_svg_height_map import polygon, rings
from gameplay_standing_volumes import StandingVolumes
from resolve_local_svg_wall_profiles import sha
from svg_review_source import source_world

OUTPUT = ROOT / 'tactical-visibility-revision/icebox-top-screens-v8'
SUPPORT_ID = 'icebox-a-top-screens'
REVIEW_ID = '1788883963581-57243566'
SOURCE_OBJECT = 3742
COLLISION = '/Port_BVPawn/BP_BlockingVolume167/Cube#0'
GAMEPLAY = 'https://www.youtube.com/watch?v=vN1DKX1Fhws'
IMAGE = 'https://static.beebom.com/wp-content/uploads/2024/04/Valorant-A-site-Callouts.jpg?w=1024'


def main():
    OUTPUT.mkdir(exist_ok=True)
    saved_path = ROOT / f'tactical-visibility-revision/sightline-review/reviews/{REVIEW_ID}.json'
    saved = read(saved_path)
    pose = saved['cones'][3]
    alignment = read(ROOT / 'tactical-alignment-sides-v1/icebox.json')
    attack = np.asarray(alignment['nativeToAttackSvg'])
    native = np.linalg.solve(attack[:, :2], np.asarray(pose['origin'])-attack[:, 2])
    volumes = StandingVolumes('icebox')
    assert not volumes.unresolved
    z, contact = volumes.physical_floor(native, 7.1)
    assert contact == COLLISION and abs(z-7) < 1e-6
    assert not volumes.exclusions(native, z)
    index = next(i for i, r in enumerate(volumes.rows) if r['id'] == contact)
    triangles = volumes.triangles[index]
    top = triangles[np.max(abs(triangles[:, :, 2]-z), axis=1) < 1e-6]
    domain = shapely.union_all(shapely.polygons(top[:, :, :2]))
    nav = navigation_triangles('icebox')
    nav_shapes = shapely.polygons(nav[:, :, :2])
    ids = [int(i) for i in shapely.STRtree(nav_shapes).query(domain, predicate='intersects')
           if np.max(abs(nav[i, :, 2]-z)) < .2]
    assert ids
    domain = domain.intersection(shapely.union_all(nav_shapes[ids]).buffer(.42))
    domain = domain.difference(standing_obstacles(volumes, domain, z, ignored={index}))
    assert domain.contains(shapely.Point(native))
    checked = []
    for p in sample_domain(domain, 9):
        xy = np.array([p.x, p.y])
        floor, collision = volumes.physical_floor(xy, z)
        assert collision == COLLISION and abs(floor-z) < 1e-6
        assert not volumes.exclusions(xy, floor), xy
        checked.append(xy.tolist())
    source = source_world('icebox')
    obj = read(source/'geometry.json')['objects'][SOURCE_OBJECT]
    assert obj['path'] == 'Port_Art_A/Shell_2_WarehouseSignA/StaticMeshComponent0.252'
    old_review = read(OUT/'icebox/support-build.json')
    omitted = [r for r in old_review['unconfirmedDetachedSamples'] if r['sourceObject'] == SOURCE_OBJECT]
    assert len(omitted) == 16 and all(r['eligible'] for r in omitted)
    files, cases = [], []
    for side in ['attack', 'defense']:
        asset = Path(f'assets/maps/icebox_svg_height_{side}.json.gz')
        before_path = OUTPUT / f'before-{side}.json.gz'
        if not before_path.exists():
            before_path.write_bytes(asset.read_bytes())
        before = read(before_path)
        assert all(s['id'] != SUPPORT_ID for s in before['supports'])
        model = {**before, 'supports': list(before['supports'])}
        matrix = np.asarray(alignment[f'nativeTo{side.title()}Svg'])
        transform = [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]]
        svg = affine_transform(domain, transform)
        svg = svg.intersection(shapely.union_all([polygon(r) for r in model['receiver']]))
        eye = z + model['defaultCameraHeightMeters']
        active = [polygon(w) for w in model['walls'] if any(
            lo <= eye-w['floorElevationMeters'] <= hi or lo == 0 and eye < w['floorElevationMeters']
            for lo, hi in w['bands'])]
        svg = svg.difference(shapely.union_all(active))
        origin = matrix[:, :2] @ native + matrix[:, 2]
        assert svg.contains(shapely.Point(origin))
        support = dict(id=SUPPORT_ID, label='A Top Screens',
            rings=[r for p in shapely.get_parts(svg) if p.geom_type == 'Polygon' for r in rings(p)],
            fillRule='evenodd', floorElevationMeters=0., heightAboveFloorMeters=z,
            surfaceElevationMeters=z, automaticStandingAllowed=True)
        model['supports'].append(support)
        assert all(model[k] == before[k] for k in before if k != 'supports')
        candidate = OUTPUT / f'candidate-{side}.json.gz'
        candidate.write_bytes(gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0))
        (OUTPUT/'render-models').mkdir(exist_ok=True)
        (OUTPUT/f'render-models/icebox-{side}.json').write_text(json.dumps(model,separators=(',',':')))
        direction = matrix[:, :2] @ np.linalg.solve(attack[:, :2], [np.cos(pose['direction']), np.sin(pose['direction'])])
        angle = float(np.arctan2(direction[1], direction[0]))
        # Exact reported position, the same position explicitly below, and
        # different directions along the whole reviewed platform.
        samples = [(native, angle, 'reported')]
        for i, p in enumerate(sample_domain(domain, 3)):
            samples.append((np.array([p.x,p.y]), angle, f'platform-{i}'))
        for xy, a, label in samples:
            p = matrix[:, :2] @ xy + matrix[:, 2]
            if not svg.contains(shapely.Point(p)):
                continue
            cases.append(dict(id=f'{side}-{label}', side=side, originSvg=p.tolist(),
                centerSvg=p.tolist(), directionRadians=a, rangeSvg=pose['range'],
                apertureRadians=pose['aperture'], cropSizeSvg=90., render=label=='reported',
                automatic=True, expectedEyeElevationMeters=eye))
        cases.append(dict(id=f'{side}-reported-ground',side=side,originSvg=origin.tolist(),
            centerSvg=origin.tolist(),directionRadians=angle,rangeSvg=pose['range'],
            apertureRadians=pose['aperture'],cropSizeSvg=90.,render=True,
            absoluteEyeElevationMeters=saved['computed'][3]['eyeMeters'],
            expectedEyeElevationMeters=saved['computed'][3]['eyeMeters']))
        files.append(dict(side=side,beforeSha256=sha(before_path),candidateSha256=sha(candidate),
                          areaSvg=svg.area,support=support))
    (OUTPUT/'production-cases.json').write_text(json.dumps(dict(cases=cases),separators=(',',':')))
    report = dict(reviewId=REVIEW_ID,reviewSha256=sha(saved_path),sourceObject=SOURCE_OBJECT,
        sourcePath=obj['path'],sourceGeometrySha256=sha(source/'geometry.npz'),
        collision=contact,collisionEvidence=volumes.rows[index],physicalFloorMeters=z,
        priorEyeMeters=saved['computed'][3]['eyeMeters'],correctEyeMeters=eye,
        navigationTriangles=ids,verifiedStandingPositions=checked,files=files,
        gameplaySource=GAMEPLAY,inspectedGameplayImage=IMAGE,
        inspectedGameplayImageSha256=sha(OUTPUT/'gameplay-top-screens.jpg'),
        omittedEligibleSamples=len(omitted),
        cause='The earlier standing builder left navigation island 24 unconfirmed because the source lacked a named gameplay role. The finite-wall pass preserved that incomplete support list.',
        scope='Add one independently reviewed support per side. Existing walls, supports, ground, receivers and artwork remain unchanged.')
    (OUTPUT/'source-review.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(dict(physicalFloorMeters=z,correctEyeMeters=eye,verifiedPositions=len(checked),cases=len(cases))))


if __name__ == '__main__':
    main()
