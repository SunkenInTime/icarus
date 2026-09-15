"""Confirm named gameplay openings against local source sections and clear rays.

An image identifies the usable opening. Local source geometry supplies its
vertical extent, and navigation on both sides supplies playable ray endpoints.
No source gap outside the named review domain is accepted by this tool.
"""
import argparse
import json
from pathlib import Path
import shutil

import numpy as np
import shapely

from audit_all_map_gameplay_levels import ROOT, read
from audit_assumed_svg_height_sections import wall_stations, clipped_height_intervals, merge_intervals
from compile_reviewed_svg_height_map import polygon
from native_reference_cast import NativeReferenceModel
from resolve_local_svg_wall_profiles import OUTPUT, sha
from svg_review_source import source_world, verified_source_pack
from svg_source_navigation import SourceNavigation


OPENINGS = {
    'lotus': [
        dict(name='Waterfall arch passage', domain=[86., 130., 100., 133.],
            walls=['p7-stroke-0'], sourceNames=['DefPathCArch', 'DefPathCPlatform'], multipleLevels=True,
            gameplaySource='https://www.dexerto.com/valorant/valorant-lotus-map-guide-layout-callouts-strategies-more-2026533/',
            gameplayImage='https://www.dexerto.com/cdn-image/wp-content/uploads/2023/01/10/valorant-lotus-c-waterfall-1024x576.jpg?format=auto&quality=75&width=1200',
            inspectedImage='waterfall-gameplay.jpg',
            evidence='The Waterfall gameplay view shows the walkable arched opening '
                     'and its solid side piers beside the water.'),
    ],
    'summit': [
        dict(name='B Tower open overlook', domain=[72., 101., 75., 117.],
            walls=['p2-stroke-3'], sourceNames=['BTowerGymExterior'], multipleLevels=True,
            gameplaySource='https://bo3.gg/valorant/articles/how-to-execute-b-site-on-summit-b-main-and-b-link-coordination',
            gameplayImage='https://files.bo3.gg/uploads/image/125699/image/webp-5f288871eb6da40e1844b1719fe4f0ba.webp',
            inspectedImage='b-tower-gameplay.webp',
            evidence='The first-person Tower view shows an open overlook with a solid '
                     'floor and side frame. The Gym view separately shows its solid lower wall.'),
    ],
    'breeze': [
        dict(name='A Site upper corner overlook', domain=[326., 108., 330., 121.],
            walls=['p6-stroke-0'], sourceNames=['ASiteCornerDU'], multipleLevels=True,
            gameplaySource='https://beebom.com/valorant-breeze-map-guide/',
            gameplayImage='https://static.beebom.com/wp-content/uploads/2024/04/A-site-Breeze.jpg?quality=75&strip=all',
            inspectedImage='a-site-gameplay.jpg',
            evidence='The A Site gameplay view shows the upper open structure and '
                     'solid parapet beside Bridge. Require actual standing rays from its upper floor.'),
    ],
    'haven': [
        dict(name='Hell front beneath Heaven', domain=[358., 123., 362., 139.],
            walls=['p1-stroke-0'], sourceNames=['ATower', 'FenceRailsBroken',
                'FenceDecorativePosts', 'InteriorBroken', 'SingleCurveA_3'], multipleLevels=True,
            gameplaySource='https://dotesports.com/valorant/news/valorant-haven-map-guide',
            gameplayImage='https://dotesports.com/wp-content/uploads/2022/01/06111758/Haven-A-site-callouts-1024x576.jpg',
            inspectedImage='a-site-gameplay.png',
            evidence='The site gameplay view shows the open front into Hell beneath '
                     'the Heaven floor, with solid side piers and a lintel.'),
    ],
    'abyss': [
        dict(name='Mid Catwalk open floor edge', domain=[239., 188., 256., 199.],
            walls=['p1-stroke-6'],
            sourceNames=['MidBigMainTower', 'MidPillar', 'MidCat', 'MidPlank'], multipleLevels=True,
            gameplaySource='https://beebom.com/valorant-abyss-map-guide/',
            gameplayImage='https://static.beebom.com/wp-content/uploads/2024/06/Abyss-Mid-callouts.jpg?w=1024',
            inspectedImage='mid-catwalk-gameplay.jpg',
            evidence='The first-person Mid Catwalk view shows an open floor edge '
                     'toward Library and the lower mid route. The platform and '
                     'overhead structure are separate vertical levels.'),
        dict(name='Mid Bend doorway toward B Main', domain=[153.5, 281., 155.5, 298.],
            walls=['p7-stroke-4'],
            sourceNames=['AtkPathBMidDoor', 'MidAtkBWallB', 'MidToAtkPathBFloor'],
            multipleLevels=True,
            gameplaySource='https://www.sepiamars.work/entry/2024/07/01/181533',
            gameplayImage='https://cdn-ak.f.st-hatena.com/images/fotolife/s/sepiamars1/20240630/20240630155946.jpg',
            inspectedImage='mid-bend-gameplay.jpg',
            evidence='The gameplay view from Mid Bottom shows the open Mid Bend '
                     'doorway with a solid lintel. The B Main overhead view '
                     'also shows its open connection to Bend.'),
        dict(name='B Tower lower opening', domain=[0., 157., 8., 166.],
            walls=['p19-stroke-0'], sourceNames=['BSiteTower'], multipleLevels=True,
            gameplaySource='https://beebom.com/valorant-abyss-map-guide/',
            gameplayImage='https://static.beebom.com/wp-content/uploads/2024/06/Abyss-B-callouts.jpg?quality=75&strip=all',
            inspectedImage='b-site-gameplay.jpg',
            evidence='The B Site gameplay view distinguishes the upper walkway from '
                     'the open lower route. Accept a local section only with playable '
                     'source-ray endpoints inside the SVG floor.'),
    ],
    'corrode': [
        dict(name='B Tower projecting floor and upper window', domain=[76., 154., 91., 160.],
            walls=['p2-stroke-5'], sourceNames=['BSiteBldgD', 'BSiteBldD'], multipleLevels=True,
            gameplaySource='https://bo3.gg/valorant/articles/how-to-execute-a-b-site-take-on-corrode-in-valorant',
            gameplayImage='https://files.bo3.gg/uploads/image/114472/image/webp-410496504cb1f275bbb726ffb03a4490.webp',
            inspectedImage='b-site-gameplay.png',
            evidence='The overhead gameplay view shows the open upper window, its projecting '
                     'floor slab, and unobstructed site ground under the projection.'),
        dict(name='B Elbow open frame', domain=[11., 140., 15., 145.],
            walls=['p2-stroke-1'], sourceNames=['BElbow'], multipleLevels=True,
            gameplaySource='https://bo3.gg/valorant/articles/how-to-execute-a-b-site-take-on-corrode-in-valorant',
            inspectedImage='b-site-gameplay.png',
            evidence='The overhead site view shows the open timber-framed approach at B Elbow.'),
    ],
    'fracture': [
        dict(name='B Tunnel beneath the upper site outlines', domain=[98., 222., 145., 277.],
            walls=['p18-stroke-0', 'p7-stroke-3-p7-stroke-3-remainder-0',
                   'p7-stroke-3-p7-stroke-3-remainder-1'],
            sourceNames=['BsiteTunnel', 'BSiteOuterFloor', 'BSiteCenterBuilding',
                         'BSiteContaier', 'BsiteBuildingToMid', 'TunnelWall', 'TunnelCeiling'],
            multipleLevels=True,
            gameplaySource='https://www.twitch.tv/busecmn',
            gameplayImage='https://static-cdn.jtvnw.net/twitch-clips-thumbnails-prod/LivelyEvilClipsdadAMPEnergy-2_iNhklBLAvlB3qn/d40313de-820f-4c2e-9f11-09dac277569b/preview.jpg',
            inspectedImage='b-tunnel-gameplay.jpg',
            evidence='B Tunnel runs below the upper site. Its lower standing rays '
                     'must remain open under the site floor and upper containers. '
                     'Local tunnel walls and the ceiling remain solid.'),
        dict(name='A Site passage under platform', domain=[427., 228., 440., 240.],
            walls=['p19-stroke-0'], sourceNames=['AsitePlatform', 'AsiteMainBuilding7'],
            multipleLevels=True,
            gameplaySource='https://www.sportskeeda.com/valorant/valorant-guide-best-viper-lineups-fracture-patch-5-07',
            gameplayImage='https://staticg.sportskeeda.com/editor/2022/10/6b153-16672299747378-1920.jpg',
            inspectedImage='a-under-gameplay.jpg',
            evidence='The A Gate gameplay view shows the accessible route beneath '
                     'the platform and its solid overhead slab.'),
        dict(name='B Tunnel below site', domain=[102., 268., 107., 276.],
            walls=['p1-fill-3', 'p6-stroke-0'],
            sourceNames=['BsiteTunnel', 'TunnelCeiling', 'BSiteOuterFloor', 'BSiteCenterBuilding'],
            multipleLevels=True,
            gameplaySource='https://www.twitch.tv/busecmn',
            gameplayImage='https://static-cdn.jtvnw.net/twitch-clips-thumbnails-prod/LivelyEvilClipsdadAMPEnergy-2_iNhklBLAvlB3qn/d40313de-820f-4c2e-9f11-09dac277569b/preview.jpg',
            inspectedImage='b-tunnel-gameplay.jpg',
            evidence='The gameplay frame labelled B Tunnel shows the accessible passage '
                     'under the site, with its solid ceiling and stairs at the exit.'),
    ],
    'ascent': [
        dict(name='Boathouse front arches', domain=[25., 103., 31., 140.],
            walls=['p1-fill-0-p1-fill-0-original-remainder-0', 'p1-fill-1'],
            sourceNames=['Boathouse', 'BoatHouse', 'Archway'],
            gameplaySource='https://tracker.gg/valorant/articles/every-wallbang-spot-on-ascent',
            gameplayImage='https://files.bo3.gg/uploads/image/48504/image/webp-2a5a96569431d2ada9b4ab16ad6630ee.webp',
            inspectedImage='boathouse-gameplay.png',
            evidence='The interior gameplay view shows two open arches facing '
                     'the site, separated by a solid masonry pier.'),
        dict(name='Hell front below Heaven', domain=[345., 124., 378., 127.],
            walls=['p2-stroke-26'], sourceNames=['AScaffold_2_WoodPanelCustomA'],
            gameplaySource='https://dotesports.com/valorant/news/valorant-ascent-map-guide',
            gameplayImage='https://cdn1.dotesports.com/wp-content/uploads/2021/12/30122413/ascent-A-site-with-callouts-1024x576.jpg',
            inspectedImage='hell-front-gameplay.png',
            evidence='The site gameplay view shows an open front into Hell '
                     'beneath the solid Heaven floor and its front panel.'),
    ],
}


def playable_witness(center, tangent, normal, interval, nav, receiver, matrix, source, camera):
    """Find actual standing rays through the aperture, including unequal floors."""
    below, above = interval
    for left in [.35, .5, .75, 1., 1.5, 2., 3., 4., 6.]:
        for right in [.35, .5, .75, 1., 1.5, 2., 3., 4., 6.]:
            a, b = center - normal * left, center + normal * right
            for fa, za in nav.heights(a):
                for fb, zb in nav.heights(b):
                    crossing = (za * right + zb * left) / (left + right) + camera
                    if not below + .16 < crossing < above - .16:
                        continue
                    rays, valid = [], True
                    for shift in [-.15, 0., .15]:
                        endpoints = []
                        for point, level in [(a + tangent * shift, za), (b + tangent * shift, zb)]:
                            svg = matrix[:, :2] @ point + matrix[:, 2]
                            heights = [(i, z) for i, z in nav.heights(point) if abs(z-level) < .25]
                            if not heights or not receiver.covers(shapely.Point(svg)):
                                valid = False
                                break
                            endpoints.append(dict(native=point.tolist(), svg=svg.tolist(),
                                                  navigation=heights, floorMeters=level))
                        if not valid:
                            break
                        for dz in [-.15, 0., .15]:
                            p, q = [np.r_[e['native'], e['floorMeters'] + camera + dz] for e in endpoints]
                            if source.cast(p, q) is not None:
                                valid = False
                                break
                            rays.append(dict(endpoints=endpoints, sourceFrom=p.tolist(),
                                             sourceTo=q.tolist(), sourceHit=None))
                        if not valid:
                            break
                    if valid:
                        return dict(distancesMeters=[left, right], rays=rays)
    return None


def review(name, output=OUTPUT):
    directory = output / name
    path = directory / 'local-source-profiles.json'
    profiles = read(path)
    before = sha(path)
    backup = directory / f'profiles-before-openings-{before[:12]}.json'
    if not backup.exists():
        shutil.copyfile(path, backup)
    model = read(directory / 'candidate-attack.json.gz')
    receiver = shapely.union_all([polygon(r) for r in model['receiver']])
    inventory = {r['wallId']: r for r in read(directory / 'assumed-height-review.json')['records']}
    matrix = np.array(read(ROOT / f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    nav = SourceNavigation(name)
    pack_file = ROOT / f'tactical-visibility-revision/full-height-input-v1/{name}/{name}.height.bin.gz'
    source = NativeReferenceModel(pack_file,
        ROOT / 'tactical-visibility-revision/native-tactical-rays-build/Release/tactical_reference_cast.dll')
    pack = verified_source_pack(name, source)
    proof = pack['proof']
    metadata = read(source_world(name) / 'geometry.json')['objects']
    with np.load(source_world(name) / 'geometry.npz') as data:
        points, faces = data['points'], data['faces']
    changes, rejected = [], []
    for wall in profiles['records']:
        tangents = list(wall_stations(inventory[wall['wallId']]))
        for index, sample in enumerate(wall['stations']):
            if sample.pop('gameplayOpeningEvidence', None):
                sample.pop('passageIntervalMeters', None)
                sample.pop('passageIntervalsMeters', None)
            if sample['status'] != 'measured-facade' or (sample.get('passageIntervalMeters')
                    and not sample.get('gameplayOpeningEvidence')):
                continue
            for opening in OPENINGS.get(name, []):
                if wall['wallId'] not in opening['walls']:
                    continue
                xy = np.asarray(sample['associationSvg'])
                if not shapely.box(*opening['domain']).covers(shapely.Point(xy)):
                    continue
                if not opening.get('multipleLevels') and not any(part in sample.get('sourcePath', '') for part in opening['sourceNames']):
                    continue
                floor = sample['floorElevationMeters']
                eye = floor + model['defaultCameraHeightMeters']
                center = np.asarray(sample['native'])
                tangent = inverse @ tangents[index][3]
                tangent /= np.linalg.norm(tangent)
                normal = np.array([-tangent[1], tangent[0]])
                # A railing can be the closest face while an arch on the
                # same assembly supplies a lower lintel. Measure all local
                # members before deciding the opening's vertical extent.
                components = []
                for oid, obj in enumerate(metadata):
                    if not any(part.lower() in obj['path'].lower() for part in opening['sourceNames']):
                        continue
                    bounds = np.asarray(obj['boundsMeters'])
                    if np.any(bounds[0, :2] > center + 1.) or np.any(bounds[1, :2] < center - 1.):
                        continue
                    ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
                    ids = ids[pack['retained'][ids]]
                    selected, intervals = clipped_height_intervals(
                        points[faces[ids]].astype(float), center, tangent, .15, .85, include_flat=True)
                    if len(selected):
                        components.append(dict(object=oid, faces=ids[selected].tolist(),
                                               bands=merge_intervals(intervals)))
                bands = merge_intervals([b for c in components for b in c['bands']])
                if not bands:
                    continue
                if opening.get('multipleLevels'):
                    gaps, witnesses = [], []
                    bottom = floor
                    for lo, hi in bands:
                        if lo - bottom >= 1.96:
                            interval = [bottom, lo]
                            witness = playable_witness(center, tangent, normal, interval, nav,
                                receiver, matrix, source, model['defaultCameraHeightMeters'])
                            if witness:
                                gaps.append(interval)
                                witnesses.append(witness)
                            else:
                                rejected.append(dict(wallId=wall['wallId'], station=index,
                                    opening=opening['name'], interval=interval))
                        bottom = max(bottom, hi)
                    if gaps:
                        sample.update(passageIntervalsMeters=gaps,
                            measuredTopMeters=max(sample['measuredTopMeters'], max(hi for _, hi in bands)),
                            gameplayOpeningEvidence={**opening,
                                'imageSha256': sha(directory / opening['inspectedImage']),
                                'sourceProof': proof, 'witnesses': witnesses,
                                'localAssemblySections': components})
                        changes.append(dict(wallId=wall['wallId'], station=index,
                            opening=opening['name'], passageIntervalsMeters=gaps))
                    continue
                if any(lo <= eye <= hi for lo, hi in bands) or max(hi for _, hi in bands) <= eye:
                    continue
                below = max([floor, *[hi for lo, hi in bands if hi < eye]])
                above = min(lo for lo, hi in bands if lo > eye)
                if below > floor + .35 or above < floor + 1.96:
                    continue
                witness = None
                for half in [1., 1.5, 2., 2.5]:
                    rays = []
                    valid = True
                    for shift in [-.15, 0., .15]:
                        a, b = [center + tangent * shift + sign * normal * half for sign in [-1, 1]]
                        endpoints = []
                        for point in [a, b]:
                            svg = matrix[:, :2] @ point + matrix[:, 2]
                            heights = [(i, z) for i, z in nav.heights(point) if abs(z - floor) <= .5]
                            if not heights or not receiver.covers(shapely.Point(svg)):
                                valid = False
                                break
                            endpoints.append(dict(native=point.tolist(), svg=svg.tolist(), navigation=heights))
                        if not valid:
                            break
                        for z in [eye - .15, eye, eye + .15]:
                            hit = source.cast(np.r_[a, z], np.r_[b, z])
                            if hit is not None:
                                valid = False
                                break
                            rays.append(dict(endpoints=endpoints, eyeElevationMeters=z, sourceHit=None))
                        if not valid:
                            break
                    if valid:
                        witness = dict(halfLengthMeters=half, rays=rays)
                        break
                if witness is None:
                    rejected.append(dict(wallId=wall['wallId'], station=index, opening=opening['name']))
                    continue
                sample.update(passageIntervalMeters=[below, above],
                    gameplayOpeningEvidence={**opening, 'imageSha256': sha(directory / opening['inspectedImage']),
                                             'sourceProof': proof, 'witness': witness,
                                             'localAssemblySections': components})
                changes.append(dict(wallId=wall['wallId'], station=index, opening=opening['name'],
                                    passageIntervalMeters=[below, above]))
    profiles.setdefault('namedOpeningReviews', []).append(dict(algorithmSha256=sha(Path(__file__)),
        inputProfilesSha256=before, inputProfilesFile=backup.name, changes=changes, rejected=rejected))
    path.write_text(json.dumps(profiles, separators=(',', ':')))
    print(name, 'confirmed openings', len(changes), 'rejected witnesses', len(rejected), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=list(OPENINGS))
    for name in parser.parse_args().maps:
        review(name)
