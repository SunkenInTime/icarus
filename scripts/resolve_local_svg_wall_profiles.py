"""Associate each remaining painted wall section with a local source facade.

The source owns height only. Every association records its actual face ids,
local clipped intervals, registration distance and competing objects for review.
No asset is installed by this tool.
"""
import argparse
from collections import Counter
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re
import shutil
import time

import numpy as np
import shapely

from audit_all_map_gameplay_levels import MAPS, ROOT, read
from audit_assumed_svg_height_sections import clipped_height_intervals, merge_intervals, wall_stations
from audit_svg_source_height_associations import projected_distance
from build_all_map_gameplay_supports import ground_sampler
from derive_svg_height_candidates import terrain, excluded
from inventory_assumed_svg_heights import DESTINATION
from svg_review_source import source_world, verified_source_pack
from svg_source_navigation import SourceNavigation
from svg_represented_source_objects import represented_objects
from compile_reviewed_svg_height_map import polygon

OUTPUT = ROOT / 'tactical-visibility-revision/all-map-finite-heights-v7'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_role(path):
    path = path.lstrip('/')
    name = path.lower().split('/')[1]
    if (re.match(r'lights?_', name) or name.startswith('lightblocker')
            or ('light_on_' in name and name.startswith('bm_'))
            or re.search(r'(?:large|small|longwall|towerwall)light\d*$', name)
            or re.fullmatch(r'shell_\d+_light[a-z]\d+', name)):
        return 'decoration'
    if any(word in name for word in ('water_lid', 'water_boat', 'water_surface', 'lightleak', 'decal', 'vfx', 'particle',
                                     'winebottle', 'papers_', 'trash', 'monitor', 'screen', 'lightfixture',
                                     'wire', 'cable', 'paper', 'sign', 'spice_',
                                     'lamp', 'sconce', 'flag', 'banner', 'poster')) or re.search(
            r'(?:^|_)(?:tree|plant|bush|shrub|palm)(?:_|\d)', name):
        return 'decoration'
    if terrain(path):
        return 'ground'
    if any(word in name for word in ('roof', 'ceiling')):
        return 'overhead'
    return 'structure'


def source_eligible(path):
    path = path.lstrip('/')
    if source_role(path) == 'decoration':
        return False
    # FlowerShop is the name of a building, not a foliage material.
    path = path.lower().replace('flowershop', 'shop')
    if not excluded(path):
        return True
    name = path.lower().split('/')[1]
    # Several represented perimeter structures are named VistaWall or
    # VistaCraneBase. Their local solid faces remain relevant to painted ink.
    return ('vista' in path.lower()
            and any(word in name for word in ['wall', 'tower', 'foundation',
                                               'support', 'building', 'frame', 'crane', 'rockcliff'])
            and not excluded(path.lower().replace('vista', 'scene')))


def continue_flat_facades(record):
    """Bridge a missing sample only between two measurements of the same wall.

    Sampling is every two SVG units. A local clipping miss at a stroke corner
    can be filled when both neighboring samples identify the same facade at
    the same height. An entire unmatched stretch cannot use this path.
    """
    stations = record['stations']
    original = list(stations)
    for i, sample in enumerate(original):
        if not sample['status'].startswith('needs'):
            continue
        neighbors = []
        for direction in [-1, 1]:
            j = (i + direction) % len(original)
            other = original[j]
            if (other['ring'] != sample['ring'] or other['status'] != 'measured-facade'
                    or other.get('passageIntervalMeters')
                    or np.linalg.norm(np.asarray(other['svg']) - sample['svg']) > 2.1):
                break
            neighbors.append((j, other))
        if len(neighbors) != 2:
            continue
        a, b = [s for _, s in neighbors]
        if a['sourceObject'] != b['sourceObject'] or abs(a['measuredTopMeters'] - b['measuredTopMeters']) > 1e-4:
            continue
        measured = {key: a[key] for key in ['sourceObject', 'sourcePath', 'sourceRole',
                                           'sourceBands', 'sourceComponents', 'sourceFaces',
                                           'measuredTopMeters', 'measuredBottomMeters']}
        stations[i] = dict(sample, **measured, status='measured-facade',
                           associationMethod='bracketed-flat-facade',
                           neighboringSourceStationIndices=[j for j, _ in neighbors])


def resolve(name, output=OUTPUT, only_stations=None):
    started = time.monotonic()
    algorithm_hash = sha(Path(__file__))
    original = DESTINATION / name
    directory = output / name
    directory.mkdir(parents=True, exist_ok=True)
    previous = None
    if only_stations is not None:
        profile_path = directory / 'local-source-profiles.json'
        previous = read(profile_path)
        previous_hash = sha(profile_path)
        backup = directory / f'profiles-before-rematch-{previous_hash[:12]}.json'
        if not backup.exists():
            shutil.copyfile(profile_path, backup)
        previous_records = {w['wallId']: w for w in previous['records']}
    measurements = read(original / 'assumed-height-sections.json')
    inventory = {r['wallId']: r for r in read(original / 'assumed-height-review.json')['records']}
    model = read(original / 'candidate-attack.json.gz')
    ground = ground_sampler(model)
    receiver = shapely.union_all([polygon(r) for r in model['receiver']])
    navigation = SourceNavigation(name)
    source = source_world(name)
    metadata = read(source / 'geometry.json')['objects']
    represented = represented_objects(name, metadata)
    with np.load(source / 'geometry.npz') as archive:
        points, faces = archive['points'], archive['faces']
    retained = verified_source_pack(name)['retained']
    eligible = [i for i, obj in enumerate(metadata)
                if obj['faceCount'] and source_eligible(obj['path'])]
    bounds = np.asarray([metadata[i]['boundsMeters'] for i in eligible])
    source_tree = shapely.STRtree(shapely.box(bounds[:, 0, 0], bounds[:, 0, 1],
                                             bounds[:, 1, 0], bounds[:, 1, 1]))
    alignment_path = ROOT / f'tactical-alignment-sides-v1/{name}.json'
    matrix = np.asarray(read(alignment_path)['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])

    @lru_cache(maxsize=128)
    def object_geometry(oid):
        obj = metadata[oid]
        raw = points[faces[obj['firstFace']:obj['firstFace'] + obj['faceCount']]].astype(float)
        normal = np.cross(raw[:, 1] - raw[:, 0], raw[:, 2] - raw[:, 0])
        length = np.linalg.norm(normal, axis=1)
        normal /= np.maximum(length[:, None], 1e-30)
        return raw, normal

    @lru_cache(maxsize=128)
    def object_xy_bounds(oid):
        raw, _ = object_geometry(oid)
        return raw[:, :, :2].min(1), raw[:, :, :2].max(1)

    results = []
    for wall in measurements['records']:
        if only_stations is not None and not any(wid == wall['wallId'] for wid, _ in only_stations):
            results.append(previous_records[wall['wallId']])
            continue
        represented_source = represented.get(wall['wallId'])
        stations = wall['stations']
        sample_geometry = list(wall_stations(inventory[wall['wallId']]))
        painted = polygon(inventory[wall['wallId']])
        if len(sample_geometry) != len(stations):
            raise ValueError('Source measurement stations changed')
        record = dict(wallId=wall['wallId'], stations=[], sourceOwners=Counter())
        for index, station in enumerate(stations):
            if only_stations is not None and (wall['wallId'], index) not in only_stations:
                record['stations'].append(previous_records[wall['wallId']]['stations'][index])
                continue
            svg = np.asarray(station['svg'])
            # Recover the tangent from the same authored ring used for the
            # measured sections, without estimating it from distant vertices.
            candidates = []
            tangent_svg = sample_geometry[index][3]
            perpendicular = np.array([-tangent_svg[1], tangent_svg[0]])
            cross_section = painted.intersection(shapely.LineString([svg - perpendicular * 8, svg + perpendicular * 8]))
            through = [g for g in shapely.get_parts(cross_section)
                       if g.geom_type == 'LineString' and g.length > 1e-8
                       and g.distance(shapely.Point(svg)) < 1e-6]
            section = min(through, key=lambda g: g.length) if through else None
            # A wide filled footprint can reach the section's artificial ends.
            # Its midpoint would move measurement into the building interior.
            # Only a complete, narrow strip has a meaningful center here.
            complete = (section is not None and section.length < 6.
                        and all(np.linalg.norm(np.asarray(p) - svg) < 7.99
                                for p in section.coords))
            center = np.asarray(section.interpolate(.5, normalized=True).coords[0]) if complete else svg
            native = (center - matrix[:, 2]) @ inverse.T
            tangent = inverse @ tangent_svg
            tangent /= max(np.linalg.norm(tangent), 1e-12)
            normal = np.array([-tangent[1], tangent[0]])
            svg_normal = matrix[:, :2] @ normal
            svg_normal /= np.linalg.norm(svg_normal)
            floors = [ground(p) for p in [svg, svg - svg_normal * 1.5, svg + svg_normal * 1.5]]
            floors = [z for z in floors if z is not None]
            floor = min(floors) if floors else wall['floorElevationMeters']
            local_objects = []
            sections = []
            # Measure around the center of the painted strip. The earlier
            # edge-centered inventory can miss an entire opposite facade.
            local_ids = ([represented_source['object']] if represented_source else
                         [eligible[i] for i in source_tree.query(shapely.box(*(native - .9), *(native + .9)))])
            for oid in local_ids:
                role = source_role(metadata[oid]['path'])
                raw, normals = object_geometry(oid)
                xy_low, xy_high = object_xy_bounds(oid)
                first = metadata[oid]['firstFace']
                nearby = ((xy_low <= native + .9).all(1)
                          & (xy_high >= native - .9).all(1)
                          & (True if represented_source else retained[first:first + len(raw)]))
                ids = np.flatnonzero(nearby)
                clipped, intervals = clipped_height_intervals(raw[ids], native, tangent, .15, .85,
                                                              include_flat=True)
                ids = ids[clipped]
                if not len(ids):
                    continue
                sections.append(dict(object=oid, bands=merge_intervals(intervals)))
                triangles, normals = raw[ids], normals[ids]
                all_distances = projected_distance(triangles, native)
                local_objects.append((oid, role, ids, triangles, all_distances))
                vertical = abs(normals[:, 2]) < .45
                aligned = abs(normals[:, :2] @ normal) > .75
                selected = np.flatnonzero(vertical & aligned)
                if not len(selected):
                    continue
                distances = all_distances[selected]
                low = triangles[selected, :, 2].min(1)
                high = triangles[selected, :, 2].max(1)
                anchored = (low <= floor + .45) & (high > floor + .05)
                # Foundations on a sloping or lower adjacent floor can start
                # above that sampled floor. Their local vertical facade still
                # supplies measured height; opening eligibility is separate.
                if role == 'structure':
                    anchored |= (high - low > .3) & (high > floor + .05)
                if role == 'overhead':
                    anchored &= high - low > 1.
                for j in np.flatnonzero(anchored):
                    reaches_floor = low[j] <= floor + .45
                    candidates.append((float(distances[j]), -(float(high[j] - low[j])),
                                       oid, int(ids[selected[j]]), role, not reaches_floor))
            result = dict(svg=station['svg'], associationSvg=center.tolist(), native=native.tolist(),
                          ring=station['ring'], distanceSvg=station['distanceSvg'],
                          floorElevationMeters=floor, groundAvailable=bool(floors))
            if represented_source:
                result['representedSourceEvidence'] = represented_source
            if not candidates:
                # Thin rail sections and the faces at a beveled corner need
                # not reach the ground or match a straight stroke's normal.
                # Keep this association method explicit for source review.
                for oid, role, ids, triangles, distances in local_objects:
                    if role != 'structure':
                        continue
                    _, object_normals = object_geometry(oid)
                    normals = object_normals[ids]
                    take = ((abs(normals[:, 2]) < .75)
                            & (abs(normals[:, :2] @ normal) > .4)
                            & (triangles[:, :, 2].max(1) > floor + .05))
                    for j in np.flatnonzero(take):
                        height = np.ptp(triangles[j, :, 2])
                        raised = triangles[j, :, 2].min() > floor + .45
                        candidates.append((float(distances[j]), -float(height), oid, int(ids[j]), role, raised))
                if candidates:
                    result['associationMethod'] = 'local-rail-or-beveled-facade'
            if not candidates:
                crossing = navigation.crossing(native, normal, floor)
                if crossing:
                    eye = crossing['centerFloorMeters'] + model['defaultCameraHeightMeters']
                    structural = [s for s in sections
                                  if source_role(metadata[s['object']]['path']) == 'structure']
                    obstructed = any(lo <= eye <= hi for s in structural for lo, hi in s['bands'])
                    if not obstructed:
                        overhead_bands = merge_intervals([band for s in structural for band in s['bands']
                                                          if band[0] >= crossing['centerFloorMeters'] + 1.96])
                        result.update(status='navigation-passage', navigationCrossing=crossing,
                            sourceBands=overhead_bands,
                            measuredTopMeters=max((hi for _, hi in overhead_bands), default=None),
                            sourceObjects=[s['object'] for s in structural],
                            sourceRole='passage' if overhead_bands else 'connected-ground')
                        record['stations'].append(result)
                        continue
                # A drawn receiver edge over a measured floor may be a drop
                # edge rather than an upright wall. Only classify it when the
                # local source has ground and no structure above that floor.
                ground_sections = [s for s in sections
                                   if source_role(metadata[s['object']]['path']) != 'overhead'
                                   and all(hi <= floor + .3 for lo, hi in s['bands'])]
                above_ground = [s for s in sections
                                if source_role(metadata[s['object']]['path']) == 'structure'
                                and any(hi > floor + .3 for lo, hi in s['bands'])]
                if (ground_sections and not above_ground
                        and receiver.boundary.distance(shapely.Point(center)) <= 1.):
                    bands = merge_intervals([b for s in ground_sections for b in s['bands']])
                    top = max(hi for lo, hi in bands)
                    if top <= floor + .3:
                        result.update(status='measured-ground-boundary', sourceBands=bands,
                            sourceObjects=[s['object'] for s in ground_sections],
                            sourceRole='receiver-ground-edge', measuredTopMeters=top,
                            measuredBottomMeters=min(lo for lo, hi in bands))
                        record['stations'].append(result)
                        continue
                result.update(status='needs-source-role', sourceObjects=[s['object'] for s in sections])
                record['stations'].append(result)
                continue
            # Prefer a facade at the local floor over a closer floating trim
            # or upper tower. Both may share XY, but only the former identifies
            # the base of this painted obstacle.
            best = min(candidates, key=lambda row: (row[5], *row[:2], row[2], row[3]))
            oid = best[2]
            components = []
            for local_oid, role, local_ids, triangles, distances in local_objects:
                take = distances <= best[0] + .35
                local_ids, triangles = local_ids[take], triangles[take]
                clipped, intervals = clipped_height_intervals(triangles, native, tangent, .15, .85,
                                                              include_flat=role == 'ground')
                if len(clipped):
                    components.append(dict(object=local_oid, role=role,
                        faces=(local_ids[clipped] + metadata[local_oid]['firstFace']).tolist(),
                        bands=merge_intervals(intervals)))
            body = [c for c in components if c['object'] == oid]
            if not body:
                result.update(status='needs-local-section', sourceObjects=[oid])
                record['stations'].append(result)
                continue
            bands = merge_intervals([band for c in body for band in c['bands']])
            # Grow the actual connected assembly, including stacked boxes,
            # foundations and roof caps. A separate object suspended above a
            # low wall cannot raise that wall merely by sharing its XY.
            pending = [c for c in components if c not in body]
            changed = True
            while changed:
                changed = False
                for component in list(pending):
                    if any(lo <= b + .08 and hi >= a - .08
                           for lo, hi in component['bands'] for a, b in bands):
                        body.append(component)
                        pending.remove(component)
                        bands = merge_intervals([*bands, *component['bands']])
                        changed = True
            other = min((r[0] for r in candidates if r[2] != oid), default=None)
            result.update(status='measured-facade', sourceObject=oid,
                sourceRole=source_role(metadata[oid]['path']), sourceComponents=body,
                sourceFaces=[f for c in body for f in c['faces']],
                sourcePath=metadata[oid]['path'], registrationDistanceMeters=best[0],
                competingObjectDistanceMeters=other,
                sourceBands=bands, measuredTopMeters=max(high for _, high in bands),
                measuredBottomMeters=min(low for low, _ in bands))
            eye = floor + model['defaultCameraHeightMeters']
            if max(high for _, high in bands) > eye and not any(lo <= eye <= hi for lo, hi in bands):
                crossing = navigation.crossing(native, normal, floor)
                if crossing:
                    opening_floor = crossing['centerFloorMeters']
                    below = max((hi for lo, hi in bands if hi < eye), default=opening_floor)
                    above = min((lo for lo, hi in bands if lo > eye), default=float('inf'))
                    if below <= opening_floor + .08 and above >= opening_floor + 1.96:
                        result.update(navigationCrossing=crossing,
                                      passageIntervalMeters=[below, above])
            record['sourceOwners'][oid] += 1
            record['stations'].append(result)
        continue_flat_facades(record)
        record['sourceOwners'] = Counter(s['sourceObject'] for s in record['stations'] if s.get('sourceObject') is not None)
        record['sourceOwners'] = [dict(object=oid, path=metadata[oid]['path'], stations=count)
                                  for oid, count in record['sourceOwners'].most_common()]
        record['unresolvedStations'] = sum(r['status'] not in ['measured-facade', 'navigation-passage', 'measured-ground-boundary'] for r in record['stations'])
        results.append(record)
        print(name, len(results), '/', len(measurements['records']), wall['wallId'],
              record['unresolvedStations'], '/', len(stations), 'unresolved', flush=True)
    report = dict(schemaVersion=1, map=name, records=results,
        algorithmSha256=algorithm_hash,
        navigationSourceSha256=sha(ROOT / f'nav/baked/{name}_source_xyz.json'),
        navigationWalkableSha256=sha(ROOT / f'nav/baked/{name}_navigation.json'),
        sourceGeometrySha256=measurements['sourceGeometrySha256'],
        sourceMetadataSha256=sha(source / 'geometry.json'),
        alignmentSha256=sha(alignment_path),
        measurementsSha256=sha(original / 'assumed-height-sections.json'),
        status='source-associations-awaiting-review', elapsedSeconds=time.monotonic() - started)
    if previous is not None:
        previous['records'] = results
        previous.setdefault('sourceRematches', []).append(dict(
            algorithmSha256=algorithm_hash, inputProfilesSha256=previous_hash,
            inputProfilesFile=backup.name, stations=sorted(only_stations)))
        report = previous
    (directory / 'local-source-profiles.json').write_text(json.dumps(report, separators=(',', ':')))
    print(name, 'unresolved', sum(r['unresolvedStations'] for r in results),
          'of', sum(len(r['stations']) for r in results), 'stations', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=MAPS)
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()
    for name in args.maps:
        resolve(name, args.output)
