"""Freeze regional standing and ramp samples without opening runtime assets."""
import hashlib
import argparse
from collections import defaultdict
import json
from pathlib import Path

import numpy as np
import shapely

from audit_all_map_gameplay_levels import ROOT, read
from audit_icebox_acceptance import sample_domain
from polygonal_area import polygonal

OUT = Path('work/icebox-acceptance')


def build(output=OUT, target=Path('test/fixtures/icebox_regional_standing.json'), check_defaults=False):
    algorithm_hashes = {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
        for name in ['build_icebox_regional_cases.py', 'audit_icebox_acceptance.py', 'polygonal_area.py']}
    path = output / 'regional-floors.json'
    source = read(path)
    map_name = read(output/'source-inventory.json').get('map', 'icebox')
    alignment = read(ROOT / f'tactical-alignment-sides-v1/{map_name}.json')
    rows, paths, joins = [], [], []
    # Clearance overlays can retain isolated lines. Only polygonal area is a
    # standing domain; those lines must not introduce an extra local level.
    domains = [(d, polygonal(shapely.from_geojson(json.dumps(d['nativeGeometry']))), np.array(d['nativePlane']))
               for d in source['domains']]
    boundaries = [shape.boundary for _, shape, _ in domains]
    inset_domains = [shape.buffer(-.000001) for _, shape, _ in domains]
    inset_tree = shapely.STRtree(inset_domains)

    def case(identifier, domain_id, xy, plane):
        height = float(plane[:2] @ xy + plane[2])
        return dict(id=identifier, domain=domain_id, nativeXY=xy.tolist(),
            expectedFloorMeters=height, expectedEyeMeters=height + 1.75,
            svg={side: (np.array(alignment[f'nativeTo{side.title()}Svg']) @ np.r_[xy, 1]).tolist()
                 for side in ['attack', 'defense']})
    for domain_index, item in enumerate(source['domains']):
        domain = domains[domain_index][1]
        plane = np.array(item['nativePlane'])
        # Boolean clipping leaves zero-width seams and tiny numerical shards.
        # Sample one micron inside the source domain. Whole-domain coverage
        # retains the original polygon and reports its numerical remainder.
        inset = inset_domains[domain_index]
        points = sample_domain(inset).reshape(-1, 2) if not inset.is_empty else np.empty((0, 2))
        if np.linalg.norm(plane[:2]) > .01:
            # Follow the fall line through each source polygon, and extend it
            # across each end to expose adjoining levels and stacked floors.
            direction = plane[:2] / np.linalg.norm(plane[:2])
            for part in shapely.get_parts(domain):
                if part.geom_type != 'Polygon' or part.area < .01:
                    continue
                center = np.array(part.representative_point().coords)[0]
                clipped = part.intersection(shapely.LineString([center - 100 * direction, center + 100 * direction]))
                for line in shapely.get_parts(clipped):
                    if line.geom_type != 'LineString' or line.length < .1:
                        continue
                    xy = np.array(line.coords)
                    samples = [xy[0] + t * direction for t in np.arange(.02, line.length, .05)]
                    points = np.r_[points, np.asarray(samples).reshape(-1, 2)]
                    paths.append(dict(id=f"{item['id']}-path-{len(paths)}", domain=item['id'],
                        nativeXY=[p.tolist() for p in samples], nativePlane=plane.tolist(),
                        scope='Continuous source ramp interior; adjoining source domains checked separately.'))
                    for end, sign in [(xy[0], -1), (xy[-1], 1)]:
                        joined = []
                        reference = float(plane[:2] @ end + plane[2])
                        for distance in np.arange(-.2, .501, .05):
                            probe = end + sign * distance * direction
                            available = [(domains[i][0], domains[i][2])
                                for i in sorted(inset_tree.query(shapely.Point(probe), predicate='intersects'))
                                if abs(float(domains[i][2][:2] @ probe + domains[i][2][2]) - reference) < .25]
                            if not available:
                                continue
                            d, p = min(available, key=lambda dp: abs(float(dp[1][:2] @ probe + dp[1][2]) - reference))
                            joined.append(case(f"join-{len(joins)}-{len(joined)}", d['id'], probe, p))
                        distinct = {r['domain'] for r in joined}
                        if len(distinct) > 1 and item['id'] in distinct:
                            if map_name == 'icebox' and item['id'] in ['volume-5-0', 'volume-7-0']:
                                for row in joined:
                                    row['selection'] = 'automatic'
                            joins.append(dict(id=f'join-{len(joins)}', sourceRamp=item['id'],
                                cases=joined, domains=sorted(distinct),
                                scope='Source-defined points on both sides of a ramp end; local levels within 25 cm of the source end.'))
        for i, xy in enumerate(points):
            rows.append(case(f"{item['id']}-{i}", item['id'], xy, plane))
    rows.extend(r for join in joins for r in join['cases'])
    if check_defaults:
        source_tree = shapely.STRtree([shape for _, shape, _ in domains])
        for row in rows:
            xy = np.array(row['nativeXY'])
            point = shapely.Point(xy)
            row['sourceLocalLevelsMeters'] = sorted(set(float(domains[i][2][:2] @ xy + domains[i][2][2])
                for i in source_tree.query(point, predicate='intersects')))
            # Source clearance unions snap at 1e-7 m. A sample on another
            # level's rounded boundary cannot decide which side owns it.
            # Retain its level-presence check; whole-domain comparison audits
            # the boundary with its separately declared coordinate tolerance.
            row['defaultBoundaryAmbiguous'] = any(boundaries[i].distance(point) <= 1e-7
                for i in source_tree.query(point.buffer(1e-7), predicate='intersects'))
    placements = []
    if check_defaults:
        choices_by_domain = defaultdict(list)
        for row in rows:
            if not row['defaultBoundaryAmbiguous']:
                choices_by_domain[row['domain']].append(row)
        for domain_index, (item, shape, _) in enumerate(domains):
            choices = choices_by_domain[item['id']]
            if choices:
                placements.append(max(choices, key=lambda row: boundaries[domain_index].distance(shapely.Point(row['nativeXY']))))
    fixture = dict(map=map_name, sourceSha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        algorithmSha256=algorithm_hashes,
        heightToleranceMeters=.02, sampleInsetMeters=.000001, cases=rows, rampPaths=paths, rampJoins=joins,
        defaultPlacements=placements)
    target.write_text(json.dumps(fixture, separators=(',', ':')) + '\n')
    print(json.dumps(dict(cases=len(rows), rampPaths=len(paths), rampJoins=len(joins))))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=OUT)
    parser.add_argument('--fixture', type=Path, default=Path('test/fixtures/icebox_regional_standing.json'))
    parser.add_argument('--check-defaults', action='store_true')
    args = parser.parse_args()
    build(args.output, args.fixture, args.check_defaults)
