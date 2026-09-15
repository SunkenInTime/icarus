"""Replace specific reviewed prop assumptions and mislabeled zipline artwork.

Each height belongs to a named, bounded source assembly. Roofs above a prop
and other objects sharing its XY are not members of that assembly.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from audit_all_map_gameplay_levels import ROOT, read
from compile_reviewed_svg_height_map import polygon
from inventory_assumed_svg_heights import DESTINATION
from svg_review_source import source_world


RECIPES = {
    'ascent': [
        dict(walls=['p2-stroke-6'], objects=[7190, 7265, 7266],
             role='Boat and its two stands. Switchhouse roof 7276 is overhead room geometry, not the boat.'),
        dict(walls=['p2-stroke-18'], objects=[7489],
             role='A approach planter shell. Adjacent building and foliage do not define the planter height.'),
        dict(walls=['p4-stroke-0', 'p4-stroke-1', 'p4-stroke-2', 'p4-stroke-3'], objects=[7944],
             role='Four painted edges of the same Mid wall. Local wall top is 4.5 m source elevation; nearby boxes remain separate obstacles.'),
    ],
    'bind': [
        dict(walls=['p12-stroke-0'], objects=[6694],
             role='Single wine barrel. Ground, ambient-occlusion blocker and overhead geometry are not the barrel.'),
    ],
    'fracture': [
        dict(walls=['p10-fill-0', 'p11-fill-0', 'p12-stroke-0', 'p12-stroke-1',
                    'p12-stroke-2', 'p12-stroke-3'], objects=[], annotation=True,
             role='The two triangular direction markers and four drawn zipline-route segments between attacker spawns are map annotations, not walls.',
             gameplaySource='https://playvalorant.com/en-us/news/game-updates/what-s-new-in-valorant-episode-3-act-ii/'),
    ],
    'split': [
        dict(walls=['vent174-opening-0'], objects=[7795],
             localProfileWall='vent174-opening-0',
             role='Dara rejected the vent asset gap as a usable gameplay sightline. '
                  'Keep this drawn tactical blocker solid up to the locally measured '
                  'top of Shell_6_VentRoomLargeTubeDU. Scaffolding above that assembly '
                  'does not define this wall height.',
             gameplaySource='User annotated vent-opening preview, September 6, 2026'),
    ],
}


def review(name, output):
    directory = output / name
    models = {s: read(directory / f'candidate-{s}.json.gz') for s in ['attack', 'defense']}
    original = {s: read(directory / f'before-{s}.json.gz') for s in models}
    objects_path = source_world(name) / 'geometry.json'
    objects = read(objects_path)['objects']
    matrix = read(ROOT / f'tactical-alignment-sides-v1/{name}.json')
    attack, defense = [np.asarray(matrix[f'nativeTo{s}Svg']) for s in ['Attack', 'Defense']]
    linear = defense[:, :2] @ np.linalg.inv(attack[:, :2])
    shift = defense[:, 2] - linear @ attack[:, 2]
    transform = [*linear[0], *linear[1], *shift]
    by_id = {w['id']: w for w in original['attack']['walls']}
    defense_shapes = [polygon(w) for w in original['defense']['walls']]
    changes = []
    for recipe in RECIPES[name]:
        source = [dict(object=i, path=objects[i]['path'], boundsMeters=objects[i]['boundsMeters'])
                  for i in recipe['objects']]
        top = max((s['boundsMeters'][1][2] for s in source), default=None)
        if recipe.get('localProfileWall'):
            measured = next(r for r in read(directory / 'assumed-height-sections.json')['records']
                            if r['wallId'] == recipe['localProfileWall'])
            local_tops = [max(high for section in station['sourceSections']
                             if section['object'] in recipe['objects']
                             for _, high in section['bands'])
                          for station in measured['stations']]
            if max(local_tops) - min(local_tops) > 1e-6:
                raise ValueError('A varying local top requires a partitioned profile')
            top = local_tops[0]
        for wid in recipe['walls']:
            before = by_id[wid]
            target = affine_transform(polygon(before), transform)
            distances = [target.hausdorff_distance(p) for p in defense_shapes]
            mate = int(np.argmin(distances))
            if distances[mate] > .01:
                raise ValueError((name, wid, 'Ambiguous defense correspondence', distances[mate]))
            paired_id = original['defense']['walls'][mate]['id']
            bands = [] if recipe.get('annotation') else [[0., top]]
            for side, identifier in [('attack', wid), ('defense', paired_id)]:
                matches = [w for w in models[side]['walls'] if w['id'] == identifier]
                if len(matches) != 1:
                    raise ValueError((name, side, identifier, 'Missing exact authored record'))
                matches[0].update(floorElevationMeters=0., bands=bands, unknownHeight=False)
            changes.append(dict(wallId=wid, defenseWallId=paired_id,
                previousBands=before['bands'], bandsAboveSourceZero=bands,
                sourceObjects=source, role=recipe['role'],
                gameplaySource=recipe.get('gameplaySource'),
                status='measured-candidate-awaiting-sightline-verification'))
    for side, model in models.items():
        prior = original[side]
        for key in prior:
            if key != 'walls' and prior[key] != model[key]:
                raise ValueError((name, side, 'Non-wall data changed', key))
        before_ink = shapely.union_all([polygon(w) for w in prior['walls']])
        after_ink = shapely.union_all([polygon(w) for w in model['walls']])
        if before_ink.symmetric_difference(after_ink).area > 1e-10:
            raise ValueError((name, side, 'Authored ink changed'))
    for side, model in models.items():
        (directory / f'candidate-{side}.json.gz').write_bytes(gzip.compress(
            json.dumps(model, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
    report = dict(schemaVersion=1, map=name, records=changes,
        sourceGeometrySha256=hashlib.sha256((objects_path.parent/'geometry.npz').read_bytes()).hexdigest(),
        sourceMetadataSha256=hashlib.sha256(objects_path.read_bytes()).hexdigest(),
        candidateSha256={s:hashlib.sha256((directory/f'candidate-{s}.json.gz').read_bytes()).hexdigest()
                         for s in models})
    (directory/'specific-height-review.json').write_text(json.dumps(report, indent=2))
    print(name, len(changes), 'assumptions replaced in both candidate sides', flush=True)


def review_summit_defense_strip(output):
    """Two literal defense edges extend slightly beyond paired prop masks."""
    directory = output / 'summit'
    path = directory / 'candidate-defense.json.gz'
    model = read(path)
    attack = read(directory / 'candidate-attack.json.gz')
    objects = read(source_world('summit') / 'geometry.json')['objects']
    records = []
    for wid, paired, ids, area in [
        ('p1-stroke-8-structural-0', 'p1-stroke-7-prop-4-0', [5945], .0007011),
        ('p1-stroke-9-structural-1', 'p1-stroke-9-prop-0-0', [4035, 4036], .0022221),
    ]:
        wall = next(w for w in model['walls'] if w['id'] == wid)
        shape = polygon(wall)
        if abs(shape.area - area) > 1e-8:
            raise ValueError('Summit defense strip geometry changed')
        counterpart = next(w for w in attack['walls'] if w['id'] == paired)
        top = max(objects[i]['boundsMeters'][1][2] for i in ids)
        if abs(counterpart['floorElevationMeters'] + counterpart['bands'][0][1] - top) > 1e-8:
            raise ValueError('Summit paired prop no longer matches its source')
        wall.update(floorElevationMeters=0., bands=[[0., top]], unknownHeight=False)
        records.append(dict(wallId=wid, attackCounterpartId=paired,
            sourceObjects=[dict(object=i, path=objects[i]['path'], boundsMeters=objects[i]['boundsMeters']) for i in ids],
            bandsAboveSourceZero=wall['bands'], paintedAreaSvg=shape.area,
            role='This thin defense remainder belongs to the same box assembly as '
                 'the adjacent finite-height prop. Preserve the exact ink and use that box height.',
            status='measured-candidate-awaiting-sightline-verification'))
    path.write_bytes(gzip.compress(json.dumps(model, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
    (directory / 'defense-height-review.json').write_text(json.dumps(dict(records=records,
        candidateSha256=hashlib.sha256(path.read_bytes()).hexdigest()), indent=2))
    print('summit 2 defense-only prop remainders corrected', flush=True)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=DESTINATION)
    args=parser.parse_args()
    for name in RECIPES:
        review(name,args.output)
    review_summit_defense_strip(args.output)
