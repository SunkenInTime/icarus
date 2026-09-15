"""Freeze app poses and ordinary-floor walks from reviewed source geometry."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from audit_all_map_gameplay_levels import ROOT, read
from compile_reviewed_svg_height_map import polygon


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def spread_poses(candidates, count=4):
    """Keep an available lower level, then cover separated source positions."""
    selected = []
    remaining = list(candidates)
    while remaining and len(selected) < count:
        if not selected:
            chosen = max(remaining, key=lambda r: ('savedReferenceEyeMeters' in r, r['sourceAreaSquareMeters']))
        else:
            chosen = max(remaining, key=lambda r: min(float(np.linalg.norm(
                np.asarray(r['nativeXY'])-s['nativeXY'])) for s in selected))
        selected.append(chosen)
        remaining = [r for r in remaining if r['sourceDomain'] != chosen['sourceDomain']]
    return selected


def build(source_dir, regional_path, target, baseline, ground_review, physical_poses=False):
    source_path = source_dir/'regional-floors.json'
    source = read(source_path)
    inventory = read(source_dir/'source-inventory.json')
    map_name = inventory['map']
    fixture = read(regional_path)
    assert fixture['sourceSha256'] == sha(source_path)
    review_path = source_dir/'gameplay-standing-review.json'
    review = read(review_path)['maps'][map_name] if review_path.exists() else dict(samples=[])
    assert review['samples'] or physical_poses, 'No gameplay poses; select physical source poses explicitly.'
    alignment = read(ROOT/f'tactical-alignment-sides-v1/{map_name}.json')
    domains = source['domains']
    shapes = [shapely.from_geojson(json.dumps(d['nativeGeometry'])) for d in domains]
    tree = shapely.STRtree(shapes)
    walls, receivers, matrices = {}, {}, {}
    for side in ['attack', 'defense']:
        # Only the already-reviewed SVG footprints and wall intervals enter
        # expectations. Never read ground or supports from this baseline.
        model = read(baseline/f'before-{side}.json.gz')
        geometry = [polygon(w) for w in model['walls']]
        walls[side] = (model['walls'], geometry, shapely.STRtree(geometry))
        receivers[side] = shapely.union_all([polygon(r) for r in model['receiver']])
        matrices[side] = np.asarray(alignment[f'nativeTo{side.title()}Svg'])

    def svg(xy):
        return {side: (m@[*xy,1.]).tolist() for side,m in matrices.items()}

    def clear(xy, floor):
        for side, coords in svg(xy).items():
            point = shapely.Point(coords)
            if not receivers[side].contains(point):
                return False
            records, geometry, wall_tree = walls[side]
            for i in wall_tree.query(point, predicate='intersects'):
                w = records[i]
                if w.get('unknownHeight'):
                    return False
                eye = floor+1.75-w['floorElevationMeters']
                if any((low == 0 or eye >= low) and eye <= high for low,high in w['bands']):
                    return False
        return True

    def levels(xy):
        point = shapely.Point(xy)
        found = []
        for i in tree.query(point, predicate='intersects'):
            height = float(np.asarray(domains[i]['nativePlane'])@[*xy,1.])
            if clear(xy,height):
                found.append((height,domains[i]['id']))
        return sorted(found)

    cases, used = [], set()
    for sample in review['samples']:
        assert sample['gameplayStandingAllowed']
        xy = sample['nativeXY']
        point = shapely.Point(xy)
        reviewed = [domains[i] for i in tree.query(point, predicate='intersects')
            if domains[i].get('eligibilityBasis') and domains[i].get('sourceObject') == sample['sourceObject']]
        available = levels(xy)
        if not available:
            continue
        height, highest = available[-1]
        candidates = [d for d in reviewed if abs(float(np.asarray(d['nativePlane'])@[*xy,1.])-height) <= .02]
        if not candidates:
            continue
        key = candidates[0]['id']
        if key in used:
            continue
        used.add(key)
        row = dict(id=sample['id'], selection='automatic', directionAttack=0.,
            sourceDomain=highest, reviewedDomain=key, nativeXY=xy, svg=svg(xy),
            sourceObject=sample['sourceObject'], sourcePath=sample['sourcePath'],
            expectedFloorMeters=height, expectedEyeMeters=height+1.75,
            sourceLocalLevelsMeters=sorted(set(h for h,_ in available)))
        if available[0][0] < height-.02:
            row['savedReferenceEyeMeters'] = available[0][0]+1.75
        cases.append(row)
    if physical_poses:
        assert not source['unresolvedInfluencingCollision']
        domain_by_id = {d['id']: d for d in domains}
        candidates = []
        for placement in fixture['defaultPlacements']:
            if placement.get('defaultBoundaryAmbiguous'):
                continue
            xy = placement['nativeXY']
            available = levels(xy)
            if not available:
                continue
            height, highest = available[-1]
            domain = domain_by_id[highest]
            assert domain.get('sourceFaces') or domain.get('reviewedSourceFaces')
            row = dict(id=f"physical-{placement['id']}", selection='automatic', directionAttack=0.,
                sourceDomain=highest, nativeXY=xy, svg=svg(xy), sourceObject=domain.get('sourceObject'),
                sourcePath=domain.get('sourcePath', domain.get('sourceCollision')),
                sourceAreaSquareMeters=domain['areaSquareMeters'],
                expectedFloorMeters=height, expectedEyeMeters=height+1.75,
                sourceLocalLevelsMeters=sorted(set(h for h, _ in available)),
                eligibilityBasis='Measured player contact and standing clearance')
            if available[0][0] < height-.02:
                row['savedReferenceEyeMeters'] = available[0][0]+1.75
            candidates.append(row)
        cases = spread_poses(candidates)
    assert len(cases) >= 2, 'Need multiple independently established app poses.'

    ground_roles = read(ground_review)
    ground_objects = set(ground_roles['sourceObjects'])
    ground_collisions = set(ground_roles['sourceCollisions'])
    domain_by_id = {d['id']:d for d in domains}
    eligible = []
    for join in fixture['rampJoins']:
        ramp = domain_by_id[join['sourceRamp']]
        if (str(ramp.get('sourceObject')) not in ground_objects
                and ramp.get('sourceCollision') not in ground_collisions):
            continue
        if any(row.get('defaultBoundaryAmbiguous') or not row.get('sourceLocalLevelsMeters')
               or abs(max(row['sourceLocalLevelsMeters'])-row['expectedFloorMeters']) > 1e-6
               or not clear(row['nativeXY'],row['expectedFloorMeters']) for row in join['cases']):
            continue
        span = float(np.linalg.norm(np.asarray(join['cases'][-1]['nativeXY'])-join['cases'][0]['nativeXY']))
        if span > .4:
            eligible.append((span,join))
    selected, used_objects = [], set()
    for _, join in sorted(eligible,key=lambda pair:-pair[0]):
        ramp = domain_by_id[join['sourceRamp']]
        oid = (ramp.get('sourceObject'), ramp.get('sourceCollision'))
        if oid in used_objects:
            continue
        selected.append(join)
        used_objects.add(oid)
        if len(selected) == 3:
            break
    assert selected, 'Need a source-confirmed ordinary-floor join for pointer movement.'
    selected_ids = {r['id'] for j in selected for r in j['cases']}
    for row in fixture['cases']:
        if row['id'] in selected_ids:
            row['selection'] = 'automatic'
    for join in selected:
        for row in join['cases']:
            row['selection'] = 'automatic'
    evidence = dict(algorithmSha256=sha(Path(__file__)),
        wallBaselineSha256={side:sha(baseline/f'before-{side}.json.gz') for side in matrices},
        gameplayReviewSha256=sha(review_path) if review_path.exists() else None,
        groundReviewSha256=sha(ground_review), selectedPointerJoins=[j['id'] for j in selected],
        basis=('Measured physical source poses' if physical_poses else 'Reviewed source poses')+
            '; highest locally clear source level; ordinary-floor joins that remain the source default throughout. Frozen baseline supplies only SVG floor footprints and previously reviewed wall intervals.')
    fixture['appRouteEvidence'] = evidence
    regional_path.write_text(json.dumps(fixture,separators=(',',':'))+'\n')
    target.write_text(json.dumps(dict(version=1,map=map_name,sourceSha256=sha(source_path),
        evidence=evidence,dragFrom=cases[0]['id'],dragTo=cases[-1]['id'],cases=cases),indent=2)+'\n')
    print(json.dumps(dict(appPoses=len(cases),pointerJoins=evidence['selectedPointerJoins'],
        cases=[dict(id=r['id'],path=r['sourcePath'],height=r['expectedFloorMeters']) for r in cases])))


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True)
    p.add_argument('--regional-fixture',type=Path,required=True)
    p.add_argument('--target',type=Path,required=True)
    p.add_argument('--baseline',type=Path,required=True)
    p.add_argument('--ground-review',type=Path,required=True)
    p.add_argument('--physical-poses', action='store_true', help='Select poses from complete physical source measurements when no prior gameplay samples exist.')
    a=p.parse_args()
    build(a.source,a.regional_fixture,a.target,a.baseline,a.ground_review,a.physical_poses)
