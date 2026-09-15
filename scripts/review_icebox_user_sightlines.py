"""Resolve Dara's four saved Icebox poses from local floor and wall sections.

Source XY associates height evidence with existing SVG ink. It never supplies
new runtime walls. Geometry-only tops are not eligible for automatic standing.
"""
import json
import numpy as np
import shapely
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from audit_svg_source_height_associations import ROOT, REV
from compile_reviewed_svg_height_map import compile_map, polygon, rings
from review_icebox_gameplay_openings import vertical_intervals


def main():
    output = REV / 'icebox-user-review-v4'
    output.mkdir(exist_ok=True)
    previous = REV / 'icebox-gameplay-audit-v3/icebox-final-decisions.json'
    decisions = json.loads(previous.read_text())
    objects = json.loads((ROOT / 'supplemented-v2/world/icebox/geometry.json').read_text())['objects']
    archive = np.load(ROOT / 'supplemented-v2/world/icebox/geometry.npz')
    points, faces = archive['points'], archive['faces']
    matrix = np.array(json.loads((ROOT / 'tactical-alignment-sides-v1/icebox.json').read_text())['nativeToAttackSvg'])
    def triangles(ids):
        result = np.concatenate([points[faces[objects[i]['firstFace']:objects[i]['firstFace'] + objects[i]['faceCount']]] for i in ids]).astype(float)
        result[:, :, :2] = result[:, :, :2] @ matrix[:, :2].T + matrix[:, 2]
        return result
    walls = {w['wallId']: w for w in decisions['walls']}
    profiles = []
    specs = [
        ('B Site upper window', 'p14-stroke-0', [4232, 4233, 4238, 4239], 0, (48.2, 49.1), (190., 203.665), (189.62, 203.327)),
        ('Kitchen window', 'p14-stroke-6', [4767, 4770, 4778], 1, (170.9, 171.83), (159.46, 166.588), (159.46, 166.588)),
        ('Connector west railing and tower', 'p15-stroke-2', [4455, 4459, 4460, 4466], 0, (136.8, 138.), (101.343, 135.338), (101.343, 135.338)),
        ('Connector east railing and tower', 'p14-stroke-7', [4456, 4459, 4461, 4466], 0, (161.4, 163.2), (101.343, 125.468), (101.343, 125.468)),
        ('Connector east north return', 'p2-stroke-0', [4456, 4459, 4461, 4466], 0, (161.2, 163.2), (101.891, 114.204), (101.891, 114.204)),
        ('Connector east south return', 'p2-stroke-1', [4456, 4459, 4461, 4463], 0, (161.2, 163.2), (121.928, 135.338), (121.928, 135.338)),
    ]
    for name, wid, ids, axis, cross, source_along, svg_along in specs:
        source = triangles(ids)
        count = int(np.ceil((svg_along[1] - svg_along[0]) / .5))
        parts = []
        for i in range(count):
            fractions = (i / count, (i + 1) / count)
            section = [source_along[0] + t * (source_along[1] - source_along[0]) for t in fractions]
            start, end = [svg_along[0] + t * (svg_along[1] - svg_along[0]) for t in fractions]
            bands = vertical_intervals(source, axis, cross, section)
            if not bands:
                raise ValueError(('No local source section', name, section))
            parts.append(dict(id=f'local-section-{i}', clipBox=[-1000, start, 1000, end] if axis == 0 else [start, -1000, end, 1000],
                mode='source-height', floorElevationMeters=0., bandsAboveFloor=bands,
                reviewStatus='reviewed', selectedSourceObjects=ids,
                reason='Local vertical section of the named gameplay opening or railing, including the solid base and overhead frame.'))
        parts.append(dict(id='remaining-frame', remainder=True, mode='solid', floorElevationMeters=0., reviewStatus='reviewed'))
        walls[wid]['parts'] = parts
        walls[wid]['reason'] = 'Replaces the unverified infinite structural-outline assumption with measured local sections.'
        profiles.append(dict(name=name, wallId=wid, sourceObjects=ids, axis=axis, cross=cross, sourceAlong=source_along, svgAlong=svg_along, parts=parts[:-1]))

    front = walls['p3-stroke-1']
    front.pop('parts', None)
    front.update(mode='source-height', floorElevationMeters=0., maximumSourceZ=float(triangles([4455, 4459])[:, :, 2].max()),
        selectedSourceObjects=[4455, 4459], reason='Connector base reaches 4.50 m; its local railing reaches 5.61 m. Neither blocks the 6.25 m upper-floor eye.')
    front.pop('bandsAboveFloor', None)

    # The supplied gameplay review identifies this upper connector and the boost
    # assembly. Detailed navigation separately corroborates the 4.50 m floor.
    support_specs = [
        ('icebox-defender-mid-upper-floor', 'Defender to Mid upper floor', 4457, None, 4.5, 'User pose 3; detailed navigation has distinct 1.00 and 4.50 m floors at this XY.'),
        ('icebox-a-boost-pipes-low-step', 'A Site lower pipe step', 3730, [104, 105, 106, 107, 170, 171, 178, 179], None, 'User pose 4 confirms this boost assembly. Local horizontal pipe faces, not the maximum of the complete assembly.'),
    ]
    support_evidence = []
    for sid, label, oid, indices, elevation, evidence in support_specs:
        source = triangles([oid])
        if indices is None:
            indices = np.where(np.max(abs(source[:, :, 2] - elevation), axis=1) < .001)[0].tolist()
        selected = source[indices]
        domain = shapely.union_all(shapely.polygons(selected[:, :, :2]))
        elevation = float(selected[:, :, 2].mean())
        support = dict(id=sid, label=label, reviewStatus='reviewed',
            rings=[r for p in shapely.get_parts(domain) if p.geom_type == 'Polygon' for r in rings(p)], fillRule='evenodd',
            heightAboveFloorMeters=elevation - 1., floorElevationMeters=1., surfaceElevationMeters=elevation,
            sourceObjects=[oid], sourceLocalFaceIndices=indices,
            automaticStandingAllowed=True, standingGameplayEvidence=evidence)
        decisions['supports'].append(support)
        support_evidence.append(support)
    # These named interior/boost levels were specifically reviewed as gameplay
    # positions. All other geometry-only tops remain explicit, never automatic.
    eligible = {
        'icebox-b-site-upper-floor': 'User pose 1 inside B Site upper room; matching source floor and detailed navigation.',
        'icebox-a-warehouse-boost-top': 'User pose 4 identifies the A Site boost assembly.',
        'icebox-a-boost-pipes-top': 'User pose 4 identifies the A Site boost assembly; separate local upper pipe domain.',
        'icebox-a-stacked-interior-floor': 'Prior reviewed playable defender Nest interior.',
        'icebox-a-stacked-b-interior-floor': 'Prior user-reviewed attacker Nest raised sightline.',
    }
    for support in decisions['supports']:
        if support['id'] in eligible:
            support.update(automaticStandingAllowed=True, standingGameplayEvidence=eligible[support['id']])
        support.setdefault('automaticStandingAllowed', False)
    decisions['userSightlineReview'] = dict(previous=str(previous), reviewId='1788823493671-212d5f8',
        limitations=['Remaining geometry-only support tops are not automatically selected.',
                     'Other infinite structural-outline assignments are not certified by this four-position review.'])
    path = output / 'icebox-decisions.json'
    path.write_text(json.dumps(decisions, separators=(',', ':')))
    (output / 'source-section-evidence.json').write_text(json.dumps(dict(profiles=profiles, newSupports=support_evidence), indent=2))
    print(json.dumps(compile_map('icebox', path, output / 'models', False)))
    # An independent artifact makes the wall-height error directly inspectable.
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.4), constrained_layout=True)
    for ax, profile, eye in zip(axes, profiles[:2], [6.95333210627238, 6.450012924975109]):
        for part in profile['parts']:
            box = part['clipBox']; start, end = (box[1], box[3]) if profile['axis'] == 0 else (box[0], box[2])
            for low, high in part['bandsAboveFloor']:
                ax.fill_between([start, end], low, high, color='#74533b')
        ax.axhline(eye, color='#217a42', linewidth=2, label=f'Standing eye {eye:.2f} m')
        ax.set(title=profile['name'], xlabel='Along the painted wall, SVG units', ylabel='Source elevation, meters', ylim=(0, 12))
        ax.legend(loc='upper right'); ax.grid(axis='y', alpha=.15)
    fig.suptitle('The eye passes through the opening. The old data filled the whole wall.', fontsize=13)
    fig.savefig(output / 'window-sections.png', dpi=180)
    plt.close(fig)


if __name__ == '__main__':
    main()
