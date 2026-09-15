"""Measure vertical openings on reviewed SVG walls without moving their ink."""
import json
import numpy as np

from audit_svg_source_height_associations import ROOT, REV


def clip_triangle(triangle, bounds):
    result = list(triangle)
    for axis, low, high in bounds:
        for bound, sign in ((low, 1), (high, -1)):
            clipped = []
            for p, q in zip(result, result[1:] + result[:1]):
                dp, dq = sign * (p[axis] - bound), sign * (q[axis] - bound)
                if dp >= 0:
                    clipped.append(p)
                if (dp >= 0) != (dq >= 0):
                    clipped.append(p + (q - p) * dp / (dp - dq))
            result = clipped
    return np.array(result)


def vertical_intervals(triangles, axis, cross_range, along_range):
    bounds = [(axis, *cross_range), (1 - axis, *along_range)]
    selected = np.ones(len(triangles), dtype=bool)
    for dim, low, high in bounds:
        selected &= (triangles[:, :, dim].max(1) >= low) & (triangles[:, :, dim].min(1) <= high)
    intervals = []
    for tri in triangles[selected]:
        clipped = clip_triangle(tri, bounds)
        if len(clipped) >= 3:
            intervals.append([float(clipped[:, 2].min()), float(clipped[:, 2].max())])
    merged = []
    for lo, hi in sorted(intervals):
        if merged and lo <= merged[-1][1] + 1e-6:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    # A lone horizontal triangle has zero vertical thickness. It is a support
    # plane, not a positive-height interval for a horizontal standing ray.
    return [[lo, hi] for lo, hi in merged if hi > lo + 1e-7]


def main():
    output = REV / 'icebox-gameplay-audit-v3'
    output.mkdir(exist_ok=True)
    previous = REV / 'icebox-elevation-reviewed-v2/icebox-decisions.json'
    decisions = json.loads(previous.read_text())
    objects = json.loads((ROOT / 'supplemented-v2/world/icebox/geometry.json').read_text())['objects']
    archive = np.load(ROOT / 'supplemented-v2/world/icebox/geometry.npz')
    matrix = np.array(json.loads((ROOT / 'tactical-alignment-sides-v1/icebox.json').read_text())['nativeToAttackSvg'])
    walls = {w['wallId']: w for w in decisions['walls']}
    reviews = []
    # Source cross-sections are selected by the named assembly. Along-wall
    # endpoints register its opening to the corresponding painted SVG element.
    # These ranges never become new XY walls.
    specs = [
        ('attacker-nest-open-end', 'p15-stroke-5', [3743, 3744, 3745, 3746], 0, (311, 316), (234.011, 245.526), (234.033, 244.999)),
        ('attacker-nest-north-door', 'p6-stroke-2', [3743, 3744, 3745, 3746], 1, (233.9, 235.1), (338.8, 347.5), (339.305, 349.174)),
        ('defender-nest-open-end', 'p4-stroke-3', [3747, 3748, 3749, 3750], 0, (309, 314), (143.165, 154.913), (141.917, 153.98)),
        ('tube-mid-window', 'p14-stroke-9', [4755, 4757], 0, (190, 192), (193.5, 203.5), (192.361, 203.876)),
        ('belt-ramp-front', 'p8-stroke-4', [3732, 3733, 3734], 1, (293.8, 294.4), (319.566, 364.527), (319.566, 364.527)),
        ('belt-platform-front', 'p8-stroke-5', [3732, 3734, 3639], 1, (282.0, 283.0), (325.597, 385.86), (325.597, 386.459)),
    ]
    for name, wid, ids, axis, cross, source_along, svg_along in specs:
        triangles = np.concatenate([archive['points'][archive['faces'][objects[i]['firstFace']:objects[i]['firstFace'] + objects[i]['faceCount']]] for i in ids]).astype(float)
        triangles[:, :, :2] = triangles[:, :, :2] @ matrix[:, :2].T + matrix[:, 2]
        parts = []
        count = int(np.ceil(svg_along[1] - svg_along[0]))
        for i in range(count):
            a, b = i / count, (i + 1) / count
            source_range = [source_along[0] + t * (source_along[1] - source_along[0]) for t in (a, b)]
            start, end = [svg_along[0] + t * (svg_along[1] - svg_along[0]) for t in (a, b)]
            bands = vertical_intervals(triangles, axis, cross, source_range)
            if not bands:
                raise ValueError(('Missing source section', name, i))
            clip = [-1000, start, 1000, end] if axis == 0 else [start, -1000, end, 1000]
            parts.append(dict(id=f'{name}-{i}', clipBox=clip, mode='source-height',
                floorElevationMeters=0., bandsAboveFloor=bands, reviewStatus='reviewed', selectedSourceObjects=ids,
                reason='Measured disjoint source height intervals preserve a playable opening; source bounds do not place runtime walls.'))
        parts.append(dict(id='remaining-frame', remainder=True, mode='solid', floorElevationMeters=0., reviewStatus='reviewed'))
        walls[wid]['parts'] = parts
        reviews.append(dict(name=name, wallId=wid, sourceObjects=ids, sourceCrossRange=cross,
            sourceAlongRange=source_along, svgAlongRange=svg_along, parts=parts))
    gate = walls['p5-stroke-10']
    gate['parts'] = [dict(id='see-through-gate', clipBox=[354.0, 245.499, 355.5, 260.0],
        mode='connected-ground', floorElevationMeters=0., bandsAboveFloor=[], reviewStatus='reviewed',
        selectedSourceObjects=[3595], reason='Riot 1.14 documents this see-through movement gate. Source Gate_0_WarehouseRampGate matches the painted connecting segment. Navigation remains independent.'),
        dict(id='nest-body', remainder=True, mode='solid', floorElevationMeters=gate['floorElevationMeters'], reviewStatus='reviewed')]
    reviews.append(dict(name='ground-level-nest-gate', wallId='p5-stroke-10', sourceObjects=[3595], parts=gate['parts']))
    for wid, ids in [('p7-stroke-25', [152, 153]), ('p8-stroke-2', [155])]:
        top = max(objects[i]['boundsMeters'][1][2] for i in ids)
        wall = walls[wid]
        wall.pop('parts', None)
        wall.pop('bandsAboveFloor', None)
        wall.update(mode='source-height', maximumSourceZ=top, selectedSourceObjects=ids,
            reason='Separate painted server cover corresponds to the measured server bodies. Its finite top does not become an infinitely tall wall when viewed from elevated positions.')
        reviews.append(dict(name='finite-server-cover', wallId=wid, sourceObjects=ids, maximumSourceZ=top))
    decisions['gameplayOpeningReview'] = dict(previous=str(previous),
        references=['https://playvalorant.com/en-us/news/game-updates/valorant-patch-notes-1-14/',
                    'https://playvalorant.com/en-us/news/game-updates/valorant-patch-notes-8-0/',
                    'Dara annotated attacker Nest raised sightline, 2026-09-07'],
        limitations=['The see-through ground gate is separate from the solid Nest bases.',
                     'Each height interval conservatively encloses its source section.'])
    clearance = json.loads((output / 'covered-support-review.json').read_text())
    rejected = {r['id'] for r in clearance['rejectedSupports']}
    decisions['supports'] = [s for s in decisions['supports'] if s['id'] not in rejected]
    decisions.setdefault('rejectedSupports', []).extend(clearance['rejectedSupports'])
    decisions['gameplayOpeningReview']['standingClearanceEvidence'] = str(output / 'covered-support-review.json')
    (output / 'icebox-decisions.json').write_text(json.dumps(decisions, separators=(',', ':')))
    (output / 'opening-evidence.json').write_text(json.dumps(reviews, indent=2))
    print(json.dumps(dict(openings=len(reviews), output=str(output))))


if __name__ == '__main__':
    main()
