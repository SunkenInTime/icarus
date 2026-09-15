"""Plot height-review leads against actual eye-height source cross sections."""
import argparse
from collections import defaultdict
import json
import math

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
import shapely

from audit_all_map_gameplay_levels import ROOT, MAPS, read
from audit_assumed_svg_sightlines import blocks
from compile_reviewed_svg_height_map import polygon
from render_svg_height_candidate_review import polygon as draw
from render_unresolved_svg_sections import slice_triangles
from resolve_local_svg_wall_profiles import OUTPUT, sha
from svg_review_source import source_world


def render(name):
    directory = OUTPUT / name
    model = read(directory / 'candidate-attack.json.gz')
    shapes = [polygon(w) for w in model['walls']]
    tree = shapely.STRtree(shapes)
    seed = read(directory / 'seed-attack.json.gz')
    known = {w['id'] for w in seed['walls'] if not w['unknownHeight'] and all(hi is not None for _, hi in w['bands'])}
    receiver = shapely.union_all([polygon(r) for r in model['receiver']])
    rays = read(directory / 'assumed-height-source-rays.json.gz')['findings']
    registration = {r['findingIndex']: r for r in read(directory / 'source-registration-diagnostics.json')['records']}
    gaps = {r['findingIndex']: r for r in read(directory / 'source-gap-playability.json')['records']}
    grouped = defaultdict(list)
    for index, row in enumerate(rays):
        r = registration[index]
        direction = np.array([math.cos(row['directionRadians']), math.sin(row['directionRadians'])])
        source_xy = np.array(row['originSvg']) + direction * row['sourceHit']
        category = None
        if row['differenceSvg'] < 0 and len(tree.query(shapely.Point(source_xy), predicate='intersects')):
            category = 'source solid inside literal ink'
            center, oid = source_xy, row.get('sourceObject')
        elif row['differenceSvg'] > 0 and row['hitWallId'] not in known:
            if r['category'] == 'closed-across-local-source-height-gap' and gaps.get(index, {}).get('targetWitnesses'):
                category = 'local gap with playable target'
            elif r['category'] == 'source-height-band-without-nearby-ray-contact':
                category = 'measured height without shifted contact'
            center = np.array(row['originSvg']) + direction * row['svgHit']
            oid = r.get('sourceObject')
        if category:
            key = (category, r.get('profileWallId', row['wallId']), oid,
                   int(center[0] // 12), int(center[1] // 12), int(row['eyeElevationMeters'] // 2))
            grouped[key].append(dict(index=index, center=center.tolist()))
    source = source_world(name)
    objects = read(source / 'geometry.json')['objects']
    with np.load(source / 'geometry.npz') as data:
        points, faces = data['points'], data['faces']
    bounds = np.array([o['boundsMeters'] for o in objects])
    matrix = np.array(read(ROOT / f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    cards = []
    for key, entries in grouped.items():
        chosen = max(entries, key=lambda e: abs(rays[e['index']]['differenceSvg']))
        cards.append(dict(category=key[0], profileWallId=key[1], object=key[2],
                          findingIndices=[e['index'] for e in entries], **chosen))
    for start in range(0, len(cards), 6):
        fig, axes = plt.subplots(2, 3, figsize=(18, 12))
        for card, ax in zip(cards[start:start+6], axes.flat):
            row = rays[card['index']]
            center = np.asarray(card['center'])
            eye = row['eyeElevationMeters']
            extent = 11.
            x0, y0, x1, y1 = [*(center-extent), *(center+extent)]
            crop = shapely.box(x0, y0, x1, y1)
            draw(ax, receiver.intersection(crop), '#e6e8e9')
            for i in tree.query(crop, predicate='intersects'):
                piece = shapes[i].intersection(crop)
                draw(ax, piece, '#69899d' if blocks(model['walls'][i], eye) else '#efd2d2', edge='#333333')
            corners = np.array([[x0, y0], [x1, y0], [x1, y1], [x0, y1]])
            native_corners = (corners-matrix[:, 2]) @ inverse.T
            lo, hi = native_corners.min(0), native_corners.max(0)
            candidates = np.flatnonzero(np.all(bounds[:, 0, :2] < hi, axis=1)
                & np.all(bounds[:, 1, :2] > lo, axis=1)
                & (bounds[:, 0, 2] <= eye) & (bounds[:, 1, 2] >= eye))
            for oid in candidates:
                obj = objects[oid]
                tri = points[faces[obj['firstFace']:obj['firstFace']+obj['faceCount']]].astype(float)
                segments = slice_triangles(tri, eye)
                if len(segments):
                    xy = segments @ matrix[:, :2].T + matrix[:, 2]
                    ax.add_collection(LineCollection(xy, colors='#d48711' if oid == card['object'] else '#ababab',
                        linewidths=1.6 if oid == card['object'] else .65))
            for e in card['findingIndices']:
                r = rays[e]
                direction = np.array([math.cos(r['directionRadians']), math.sin(r['directionRadians'])])
                ends = np.array([r['originSvg'], np.array(r['originSvg'])+direction*r['rangeSvg']])
                ax.plot(ends[:, 0], ends[:, 1], color='#be2581', linewidth=.75, alpha=.65)
                ax.scatter(*r['originSvg'], color='#be2581', s=10)
            ax.scatter(*center, c='black', marker='+', s=25)
            title = f"{start + list(axes.flat).index(ax)} | {card['profileWallId']}\n{card['category']} | eye {eye:.3f} m"
            ax.set_title(title, fontsize=8)
            path = objects[card['object']]['path'] if card['object'] is not None else ''
            ax.set_xlabel(path.split('/')[-2] if '/' in path else path, fontsize=8)
            ax.set(xlim=(x0, x1), ylim=(y1, y0), aspect='equal')
            ax.tick_params(labelsize=7)
            card['file'] = f'height-leads-{start//6+1:02}.png'
        for ax in list(axes.flat)[len(cards[start:start+6]):]:
            ax.axis('off')
        fig.suptitle(f'{name}: blue active SVG ink; pink inactive ink; gray actual source eye slices; gold named source')
        fig.tight_layout()
        fig.savefig(directory / f'height-leads-{start//6+1:02}.png', dpi=110)
        plt.close(fig)
    (directory / 'height-leads-gallery.json').write_text(json.dumps(dict(
        candidateSha256=sha(directory / 'candidate-attack.json.gz'), cards=cards), separators=(',', ':')))
    print(name, len(cards), 'review cards', flush=True)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('maps', nargs='*', default=MAPS)
    for name in p.parse_args().maps:
        render(name)
