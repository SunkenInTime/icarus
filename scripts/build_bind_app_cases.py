"""Freeze Bind app poses and ordinary-floor walks from reviewed source geometry."""
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


def build(source_dir, regional_path, target, baseline):
    source_path = source_dir/'regional-floors.json'
    source = read(source_path)
    inventory = read(source_dir/'source-inventory.json')
    assert inventory['map'] == 'bind'
    fixture = read(regional_path)
    assert fixture['sourceSha256'] == sha(source_path)
    review_path = source_dir/'gameplay-standing-review.json'
    review = read(review_path)['maps']['bind']
    alignment = read(ROOT/'tactical-alignment-sides-v1/bind.json')
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
    assert len(cases) >= 4, 'Need multiple independently reviewed app poses.'

    ground_objects = set(read(Path('work/bind-all-reviewed-v1/ground-role-review.json'))['sourceObjects'])
    domain_by_id = {d['id']:d for d in domains}
    eligible = []
    for join in fixture['rampJoins']:
        if str(domain_by_id[join['sourceRamp']].get('sourceObject')) not in ground_objects:
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
        oid = domain_by_id[join['sourceRamp']].get('sourceObject')
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
        gameplayReviewSha256=sha(review_path), selectedPointerJoins=[j['id'] for j in selected],
        basis='Reviewed source poses; highest locally clear source level; ordinary-floor joins that remain the source default throughout. Frozen baseline supplies only SVG floor footprints and previously reviewed wall intervals.')
    fixture['appRouteEvidence'] = evidence
    regional_path.write_text(json.dumps(fixture,separators=(',',':'))+'\n')
    target.write_text(json.dumps(dict(version=1,map='bind',sourceSha256=sha(source_path),
        evidence=evidence,dragFrom=cases[0]['id'],dragTo=cases[-1]['id'],cases=cases),indent=2)+'\n')
    print(json.dumps(dict(appPoses=len(cases),pointerJoins=evidence['selectedPointerJoins'],
        cases=[dict(id=r['id'],path=r['sourcePath'],height=r['expectedFloorMeters']) for r in cases])))


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True)
    p.add_argument('--regional-fixture',type=Path,required=True)
    p.add_argument('--target',type=Path,required=True)
    p.add_argument('--baseline',type=Path,required=True)
    a=p.parse_args()
    build(a.source,a.regional_fixture,a.target,a.baseline)
