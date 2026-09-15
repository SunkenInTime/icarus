"""Measure named floor edges and building assemblies missed by facade filters.

These recipes follow inspected source plan slices. They replace only unresolved
sections, retain local face evidence, and leave gameplay verification pending.
"""
import argparse
from functools import lru_cache
import json
from pathlib import Path
import shutil

import numpy as np

from audit_all_map_gameplay_levels import ROOT, read
from audit_assumed_svg_height_sections import clipped_height_intervals, merge_intervals, wall_stations
from audit_svg_source_height_associations import projected_distance
from refine_local_svg_wall_profiles import nearest_xy
from resolve_local_svg_wall_profiles import OUTPUT, sha
from svg_review_source import source_world, verified_source_pack


RECIPES = {
    'abyss': {
        'p1-stroke-0': dict(objects=[4491], role='A Site catwalk floor edge'),
        'p1-stroke-6': dict(objects=[6568, 6510], role='Mid tower floor and adjoining plank edge'),
    },
    'haven': {
        'p3-stroke-6': dict(objects=[7033, 7034], replaceAllStations=True,
            role='Garage low shrine furniture in front of the room wall', maximumRegistrationMeters=1.,
            gameplaySource='https://dignitas.gg/articles/how-to-properly-rotate-on-offense-and-defense-in-valorant',
            inspectedImage='garage-interior-gameplay.jpg'),
        'p3-stroke-1': dict(objects=[7266, 7226], role='C Cubby step and floor edge',
            gameplaySource='https://www.gamepressure.com/valorant/haven-map-description/zdd3bd',
            inspectedImage='c-long-gameplay.jpg'),
    },
    'fracture': {
        'p18-stroke-0': dict(objects=[4725, 4813], replaceSourceObjects=[4712],
            domainSvg=[125., 238., 138., 241.], maximumRegistrationMeters=1.,
            role='B Site front floor edge before the set-back crate',
            gameplaySource='https://www.dexerto.com/valorant/valorant-fracture-map-guide-layout-callouts-strategies-more-1645939/',
            inspectedImage='b-site-gameplay.jpg'),
        'p7-stroke-0': dict(objects=[4752, 4747], replaceSourceObjects=[4744],
            role='B Site raised floor edge below the overhead beam', maximumRegistrationMeters=.75,
            gameplaySource='https://www.dexerto.com/valorant/valorant-fracture-map-guide-layout-callouts-strategies-more-1645939/',
            inspectedImage='b-site-gameplay.jpg'),
        'p1-fill-4': dict(objects=[5002], role='Back Path to B slanted building facade'),
        'p1-fill-5': dict(objects=[4608, 4609], role='Attacker spawn gate end sections'),
        'p1-fill-6': dict(objects=[4856], role='Back Path ground edge'),
        'p2-stroke-0': dict(objects=[5175, 5169, 3878], role='Back Path rock and ground edge'),
        'p17-stroke-0': dict(objects=[4752, 4734], role='B Site floor and stairway landing corner'),
    },
    'icebox': {
        'p3-stroke-0': dict(objects=[4455, 4457, 4459], replaceSourceObjects=[4454],
            domainSvg=[136., 102.7, 150., 105.], maximumRegistrationMeters=1.,
            role='Defender to Mid connector floor and low edge below the separate ice wall'),
        'p4-stroke-0': dict(objects=[4780], replaceAllStations=True,
            role='Kitchen low counter in front of the room wall', maximumRegistrationMeters=1.5,
            gameplaySource='https://yatoyablog.com/game/valorant-icebox-killjoy/',
            inspectedImage='kitchen-gameplay.jpg'),
        'p16-stroke-6': dict(objects=[771], role='Attacker dock floor edge'),
        'p1-fill-0': dict(objects=[4541, 4544, 4551, 4554, 1574, 4555],
            role='Defender Spawn tunnel walls, rear arch supports and floor',
            maximumRegistrationMeters=3.5, preferFloorFacades=True,
            domainSvg=[190., 16., 254., 32.],
            registrationEvidence='The authored rear tunnel is wider than the '
                'source tunnel. The inspected plan slices show parallel side '
                'walls inward of the ink. Associate only these named tunnel '
                'members; the ice cliff above the tunnel is a separate object.'),
    },
    'pearl': {
        'p7-stroke-8-p7-stroke-8-original-remainder-0': dict(objects=[6595, 6596],
            role='Mid arches exterior roof and upper facade'),
        'p9-stroke-2-p9-stroke-2-remainder-0': dict(objects=[6508, 6509], role='Attacker Mid floor edge'),
        'p17-stroke-0': dict(objects=[7813, 7814], role='Mid to B floor edge'),
        'p23-stroke-8-p23-stroke-8-remainder-0': dict(objects=[5995], role='A Site ramp side'),
        'p24-stroke-0-p24-stroke-0-remainder-2': dict(objects=[7084, 7556], role='A Site and Defender Spawn ground edge'),
    },
    'summit': {
        'p1-stroke-0-structural-3': dict(objects=[5685, 5686], role='B Lobby wall and attached roof section'),
    },
    'lotus': {
        'p8-stroke-3': dict(objects=[3860, 3864], replaceSourceObjects=[3726, 3856],
            domainSvg=[101., 296., 148., 304.], maximumRegistrationMeters=1.,
            role='C Mound continuous sloping ground boundary below the overhead rock'),
        'p3-stroke-6': dict(objects=[4485, 4486], role='C to B connector entry wall corner',
                            maximumRegistrationMeters=2.1),
    },
}


def review(name, output=OUTPUT):
    directory = output / name
    path = directory / 'local-source-profiles.json'
    profiles = read(path)
    input_hash = sha(path)
    backup = directory / f'profiles-before-boundaries-{input_hash[:12]}.json'
    if not backup.exists():
        shutil.copyfile(path, backup)
    inventory = {w['wallId']: w for w in read(directory / 'assumed-height-review.json')['records']}
    source = source_world(name)
    metadata = read(source / 'geometry.json')['objects']
    with np.load(source / 'geometry.npz') as data:
        points, faces = data['points'], data['faces']
    retained = verified_source_pack(name)['retained']
    matrix = np.asarray(read(ROOT / f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])

    @lru_cache(maxsize=64)
    def geometry(oid):
        obj = metadata[oid]
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        ids = ids[retained[ids]]
        return ids, points[faces[ids]].astype(float)

    changes, missed = [], []
    for wall in profiles['records']:
        recipe = RECIPES.get(name, {}).get(wall['wallId'])
        if recipe is None:
            continue
        tangents = list(wall_stations(inventory[wall['wallId']]))
        for index, sample in enumerate(wall['stations']):
            repeat = bool(recipe.get('replaceSourceObjects')) and sample.get('sourceBoundaryEvidence', {}).get('role') == recipe['role']
            if not recipe.get('replaceAllStations') and not sample['status'].startswith('needs') and sample.get('sourceObject') not in recipe.get('replaceSourceObjects', []) and not repeat:
                continue
            if recipe.get('domainSvg'):
                x, y = sample['associationSvg']
                x0, y0, x1, y1 = recipe['domainSvg']
                if not (x0 <= x <= x1 and y0 <= y <= y1):
                    continue
            center = np.array(sample['native'])
            tangent = inverse @ tangents[index][3]
            tangent /= np.linalg.norm(tangent)
            shift = 0.
            if recipe.get('maximumRegistrationMeters'):
                choices = []
                for oid in recipe['objects']:
                    ids, tri = geometry(oid)
                    distances = projected_distance(tri, center)
                    priority = np.zeros(len(tri), dtype=int)
                    if recipe.get('preferFloorFacades'):
                        low, high = tri[:, :, 2].min(1), tri[:, :, 2].max(1)
                        priority = (~((low <= sample['floorElevationMeters'] + .5)
                                    & (high >= sample['floorElevationMeters'] + 1.75))).astype(int)
                    k = np.lexsort((distances, priority))[0]
                    choices.append((int(priority[k]), float(distances[k]), oid, int(ids[k]), nearest_xy(tri[k], center)))
                _, shift, oid, face, center = min(choices, key=lambda r: r[:2])
                if shift > recipe['maximumRegistrationMeters']:
                    missed.append(dict(wallId=wall['wallId'], station=index, reason='registration-bound', distance=shift))
                    continue
            measured = []
            for oid in recipe['objects']:
                ids, tri = geometry(oid)
                selected, bands = clipped_height_intervals(tri, center, tangent, .15, .85, include_flat=True)
                if len(selected):
                    measured.append(dict(object=oid, path=metadata[oid]['path'],
                        role='reviewed-local-assembly', faces=ids[selected].tolist(), bands=merge_intervals(bands)))
            if not measured:
                missed.append(dict(wallId=wall['wallId'], station=index, reason='no-local-faces'))
                continue
            bands = merge_intervals([b for c in measured for b in c['bands']])
            # A replaced overhead association can carry an obsolete opening
            # above the actual floor edge. Its evidence belongs to that old body.
            if recipe.get('replaceSourceObjects') or recipe.get('replaceAllStations'):
                sample.pop('passageIntervalMeters', None)
                sample.pop('passageIntervalsMeters', None)
                sample.pop('gameplayOpeningEvidence', None)
            evidence = dict(**recipe, sourcePlanReview='unresolved-source-gallery.json')
            if recipe.get('inspectedImage'):
                evidence['imageSha256'] = sha(directory / recipe['inspectedImage'])
            sample.update(status='measured-ground-boundary' if max(hi for _, hi in bands) <= sample['floorElevationMeters'] + .05
                          else 'measured-facade', sourceRole=recipe['role'],
                sourceObject=measured[0]['object'], sourcePath=measured[0]['path'],
                sourceComponents=measured, sourceFaces=[f for c in measured for f in c['faces']],
                sourceBands=bands, measuredBottomMeters=min(lo for lo, hi in bands),
                measuredTopMeters=max(hi for lo, hi in bands), sourceBoundaryEvidence=evidence,
                associationMethod='reviewed-local-boundary-assembly', measurementNative=center.tolist(),
                registrationDistanceMeters=shift)
            changes.append(dict(wallId=wall['wallId'], station=index, role=recipe['role'],
                                sourceBands=bands, registrationDistanceMeters=shift))
        wall['unresolvedStations'] = sum(s['status'].startswith('needs') for s in wall['stations'])
    profiles.setdefault('boundaryReviews', []).append(dict(algorithmSha256=sha(Path(__file__)),
        inputProfilesSha256=input_hash, inputProfilesFile=backup.name, changes=changes, missed=missed))
    path.write_text(json.dumps(profiles, separators=(',', ':')))
    print(name, 'boundary sections', len(changes), 'missed', len(missed), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=list(RECIPES))
    for name in parser.parse_args().maps:
        review(name)
