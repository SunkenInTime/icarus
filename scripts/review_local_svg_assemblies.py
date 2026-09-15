"""Measure named multipart structures whose local slices have construction gaps.

This is source assembly association, not a gameplay-opening decision. Every
added interval comes from the same local section as the already measured wall.
"""
import argparse
from functools import lru_cache
import json
from pathlib import Path
import shutil

import numpy as np

from audit_all_map_gameplay_levels import ROOT, read
from audit_assumed_svg_height_sections import clipped_height_intervals, merge_intervals, wall_stations
from resolve_local_svg_wall_profiles import OUTPUT, sha
from svg_review_source import source_world


ASSEMBLIES = {
    'ascent': [
        dict(prefix='Ascent_Art_Atk/AtkBridge_0_',
             role='Attacker bridge deck, side structure and mounted railings',
             basis='The local bridge rail sections sit above the side structure. '
                   'A section between posts misses their connections along the '
                   'bridge. Include these named bridge parts at their measured '
                   'local heights, including both opposing railings.'),
        dict(prefix='Ascent_Art_AtkPathA/Vino_1_WineBarrel',
             role='Wine alcove stacked horizontal barrels',
             basis='The upper barrels rest on pairs of lower barrels. A narrow '
                   'section through their curved ends does not pass through '
                   'every support contact. Measure all local rows of the stack.'),
    ],
}

# The Pizza prop outline ends against a building. Z overlap there does not
# establish that the building belongs to the prop. Keep the named assembly's
# ownership separate from its locally measured height.
PROP_ASSEMBLIES = {
    'ascent': {
        'p2-stroke-14-p2-stroke-14-unmatched-outline-0': dict(
            objects=[4500, 4501, 4502, 4801, 4802, 4803, 4967, 4968, 8092, 8013],
            role='Pizza table, crates, pizza boxes and leaning planks',
            basis='Source plan inspection identifies the small SVG outline with '
                  'these props. The adjacent building is outside this assembly. '
                  'Measure each local section of the named props independently.'),
    },
}


def review(name, output=OUTPUT):
    directory = output / name
    path = directory / 'local-source-profiles.json'
    input_hash = sha(path)
    backup = directory / f'profiles-before-assemblies-{input_hash[:12]}.json'
    if not backup.exists():
        shutil.copyfile(path, backup)
    report = read(path)
    inventory = {w['wallId']: w for w in read(directory / 'assumed-height-review.json')['records']}
    source = source_world(name)
    metadata = read(source / 'geometry.json')['objects']
    with np.load(source / 'geometry.npz') as archive:
        points, faces = archive['points'], archive['faces']
    matrix = np.array(read(ROOT / f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    recipes = [(recipe, [i for i, o in enumerate(metadata) if o['path'].startswith(recipe['prefix'])])
               for recipe in ASSEMBLIES.get(name, [])]

    @lru_cache(maxsize=128)
    def geometry(oid):
        obj = metadata[oid]
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        return ids, points[faces[ids]].astype(float)

    changes = []
    for wall in report['records']:
        tangent_samples = list(wall_stations(inventory[wall['wallId']]))
        prop = PROP_ASSEMBLIES.get(name, {}).get(wall['wallId'])
        for index, sample in enumerate(wall['stations']):
            if prop:
                center = np.array(sample['native'])
                tangent = inverse @ tangent_samples[index][3]
                tangent /= np.linalg.norm(tangent)
                measured = []
                for oid in prop['objects']:
                    face_ids, triangles = geometry(oid)
                    selected, intervals = clipped_height_intervals(
                        triangles, center, tangent, .15, .85, include_flat=True)
                    if len(selected):
                        measured.append(dict(object=oid, path=metadata[oid]['path'],
                            role='structure', faces=face_ids[selected].tolist(),
                            bands=merge_intervals(intervals)))
                if not measured:
                    raise ValueError((name, wall['wallId'], index, 'Named prop has no local section'))
                previous = sample.get('measuredTopMeters')
                bands = merge_intervals([b for c in measured for b in c['bands']])
                sample.update(status='measured-facade', sourceComponents=measured,
                    sourceFaces=[f for c in measured for f in c['faces']],
                    sourceBands=bands, measuredTopMeters=max(hi for lo, hi in bands),
                    measuredBottomMeters=min(lo for lo, hi in bands),
                    sourceAssemblyEvidence=prop, associationMethod='named-prop-assembly')
                sample.pop('passageIntervalMeters', None)
                changes.append(dict(wallId=wall['wallId'], station=index, assembly=prop['role'],
                    previousTopMeters=previous, topMeters=sample['measuredTopMeters'],
                    replacementObjects=[c['object'] for c in measured]))
                continue
            if sample['status'] != 'measured-facade':
                continue
            member_ids = [c['object'] for c in sample['sourceComponents']]
            for recipe, ids in recipes:
                if not any(i in ids for i in member_ids):
                    continue
                center = np.array(sample.get('measurementNative', sample['native']))
                tangent = inverse @ tangent_samples[index][3]
                tangent /= np.linalg.norm(tangent)
                added = []
                for oid in ids:
                    if oid in member_ids:
                        continue
                    bounds = np.array(metadata[oid]['boundsMeters'])
                    if np.any(bounds[0, :2] > center + 1.) or np.any(bounds[1, :2] < center - 1.):
                        continue
                    face_ids, triangles = geometry(oid)
                    selected, intervals = clipped_height_intervals(triangles, center, tangent, .15, .85)
                    if len(selected):
                        added.append(dict(object=oid, role='structure', faces=face_ids[selected].tolist(),
                                          bands=merge_intervals(intervals)))
                if not added:
                    continue
                previous = sample['measuredTopMeters']
                sample['sourceComponents'].extend(added)
                sample['sourceFaces'] = [f for c in sample['sourceComponents'] for f in c['faces']]
                sample['sourceBands'] = merge_intervals([b for c in sample['sourceComponents'] for b in c['bands']])
                sample['measuredTopMeters'] = max(hi for lo, hi in sample['sourceBands'])
                sample['measuredBottomMeters'] = min(lo for lo, hi in sample['sourceBands'])
                sample['sourceAssemblyEvidence'] = recipe
                changes.append(dict(wallId=wall['wallId'], station=index, assembly=recipe['role'],
                    previousTopMeters=previous, topMeters=sample['measuredTopMeters'],
                    addedObjects=[c['object'] for c in added]))
    report.setdefault('assemblyReviews', []).append(dict(algorithmSha256=sha(Path(__file__)),
        inputProfilesSha256=input_hash, inputProfilesFile=backup.name, changes=changes))
    path.write_text(json.dumps(report, separators=(',', ':')))
    print(name, 'assembly sections', len(changes), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=list(ASSEMBLIES))
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()
    for name in args.maps:
        review(name, args.output)
