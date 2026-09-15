"""Production fixtures for standing, measured walls, and named opening levels."""
from collections import defaultdict
import json
import math
import numpy as np
import shapely
from compile_reviewed_svg_height_map import polygon

from audit_all_map_gameplay_levels import MAPS, ROOT, OUT, read
from resolve_local_svg_wall_profiles import OUTPUT, sha
from svg_source_navigation import SourceNavigation
import prepare_all_map_gameplay_render_cases as standing


def prepare(name):
    directory = OUTPUT / name
    standing.OUT = OUTPUT
    standing.prepare(name)
    path = directory / 'production-cases.json'
    cases = read(path)['cases']
    defense_rendered = 0
    for row in cases:
        if row['side'] == 'defense' and defense_rendered < 8:
            row['render'] = True
            defense_rendered += 1
    alignment = read(ROOT / f'tactical-alignment-sides-v1/{name}.json')
    a, b = [np.asarray(alignment[f'nativeTo{s}Svg']) for s in ['Attack', 'Defense']]
    linear = b[:, :2] @ np.linalg.inv(a[:, :2])
    shift = b[:, 2] - linear @ a[:, 2]
    groups = defaultdict(list)
    rays = read(directory / 'assumed-height-source-rays.json.gz')['records']
    for row in rays:
        groups[(row['wallId'], row['side'])].append(row)

    def append_pose(label, origin, center, angle, eye, render, evidence, crop=65.):
        for side in ['attack', 'defense']:
            p, q = np.asarray(origin), np.asarray(center)
            direction = np.array([math.cos(angle), math.sin(angle)])
            if side == 'defense':
                p, q = linear @ p + shift, linear @ q + shift
                direction = linear @ direction
            cases.append(dict(id=f'{side}-{label}', side=side, originSvg=p.tolist(),
                centerSvg=q.tolist(), directionRadians=math.atan2(direction[1], direction[0]),
                rangeSvg=65., apertureRadians=math.pi*.65, cropSizeSvg=crop,
                absoluteEyeElevationMeters=eye, expectedEyeElevationMeters=eye,
                render=render, sourceEvidence=evidence))

    keys = sorted(groups)
    rendered = set(np.linspace(0, max(0, len(keys)-1), min(10, len(keys)), dtype=int))
    for i, key in enumerate(keys):
        rows = sorted(groups[key], key=lambda r:(r['originOffsetSvg'], abs(r['differenceSvg'])))
        row = rows[len(rows)//2]
        append_pose(f'wall-{i}', row['originSvg'], row['stationSvg'], row['directionRadians'],
            row['eyeElevationMeters'], i in rendered,
            dict(kind='source-height-wall-probe', wallId=row['wallId'], sourceRay=row))

    openings = defaultdict(list)
    profiles = read(directory / 'local-source-profiles.json')
    nav = SourceNavigation(name)
    model = read(directory / 'candidate-attack.json.gz')
    camera = model['defaultCameraHeightMeters']
    shapes = np.asarray([polygon(w) for w in model['walls']], dtype=object)
    tree = shapely.STRtree(shapes)

    def free_origin(row):
        ep, i = row[4], row[5]
        eye = ep[i]['floorMeters'] + camera
        point = shapely.Point(ep[i]['svg'])
        return not any(any(lo <= eye <= hi for lo, hi in model['walls'][w]['bands'])
                       for w in tree.query(point, predicate='intersects'))
    for wall in profiles['records']:
        for index, sample in enumerate(wall['stations']):
            proof = sample.get('gameplayOpeningEvidence')
            if not proof:
                continue
            witnesses = proof.get('witnesses') or ([proof['witness']] if 'witness' in proof else [])
            for witness in witnesses:
                ray = witness['rays'][len(witness['rays'])//2]
                ep = ray['endpoints']
                if not isinstance(ep[0], dict):
                    continue
                ep = [{**e, 'floorMeters': e.get('floorMeters', sample['floorElevationMeters'])} for e in ep]
                for i, j in [(0, 1), (1, 0)]:
                    eye = ep[i]['floorMeters'] + camera
                    openings[(proof['name'], round(eye), i)].append((sample, index, wall, proof, ep, i, j))
    for k, rows in enumerate(openings.values()):
        valid = [r for r in rows if free_origin(r)]
        if not valid:
            raise ValueError(f'{name}: no legal SVG origin for opening {k}')
        sample, index, wall, proof, ep, i, j = valid[len(valid)//2]
        origin, target = np.asarray(ep[i]['svg']), np.asarray(ep[j]['svg'])
        delta = target-origin
        eye = ep[i]['floorMeters']+camera
        evidence = dict(kind='named-gameplay-opening', name=proof['name'], wallId=wall['wallId'],
            sourceStation=index, inspectedImage=proof['inspectedImage'], imageSha256=proof['imageSha256'],
            sourceEndpoints=ep)
        append_pose(f'opening-{k}', origin, (origin+target)/2,
            math.atan2(delta[1], delta[0]), eye, True, evidence, 45.)
        lower = [z for _, z in nav.heights(np.asarray(ep[i]['native'])) if z+camera < eye-1.]
        if lower:
            append_pose(f'base-{k}', origin, (origin+target)/2,
                math.atan2(delta[1], delta[0]), max(lower)+camera, True,
                {**evidence, 'kind':'named-opening-lower-floor'}, 45.)
    report = dict(cases=cases, candidateSha256={s:sha(directory/f'candidate-{s}.json.gz')
                  for s in ['attack', 'defense']}, sourceProfilesSha256=sha(directory/'local-source-profiles.json'))
    path.write_text(json.dumps(report, separators=(',', ':')))
    print(name, len(cases), 'production queries', sum(c.get('render', True) for c in cases), 'renders', flush=True)


def inherit_support_verification(name):
    old_path = OUT / name / 'support-verification.json'
    old = read(old_path)
    for side in ['attack', 'defense']:
        prior = OUT/name/f'candidate-{side}.json.gz'
        assert old['candidateSha256'][side] == sha(prior)
        a, b = read(prior), read(OUTPUT/name/f'candidate-{side}.json.gz')
        for key in ['supports', 'ground']:
            assert a[key] == b[key], (name, side, key, 'Cannot reuse source verification')
    report = {**old, 'candidateSha256': {s:sha(OUTPUT/name/f'candidate-{s}.json.gz')
                for s in ['attack', 'defense']},
        'verificationMethod': 'Unchanged support and ground data inherit the completed source-floor '
            'and player-clearance verification. Positions were not resampled in this revision.',
        'inheritedVerificationFile': str(old_path), 'inheritedVerificationSha256':sha(old_path),
        'inheritedCandidateSha256': old['candidateSha256']}
    (OUTPUT/name/'support-verification.json').write_text(json.dumps(report, indent=2))


if __name__ == '__main__':
    for name in MAPS:
        inherit_support_verification(name)
        prepare(name)
