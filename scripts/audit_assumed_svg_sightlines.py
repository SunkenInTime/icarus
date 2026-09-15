"""Probe both sides of every assumed wall against material-aware source rays.

These probes expose height disagreements, including upper openings. They are
review findings, never instructions to move SVG ink or accept gameplay gaps.
"""
import argparse
from collections import Counter
import gzip
import hashlib
import json
import math
from pathlib import Path

import numpy as np
import shapely

from audit_all_map_gameplay_levels import MAPS, ROOT, read
from audit_assumed_svg_height_sections import wall_stations
from build_all_map_gameplay_supports import ground_sampler, support_elevation
from compile_reviewed_svg_height_map import polygon
from inventory_assumed_svg_heights import DESTINATION
from native_reference_cast import NativeReferenceModel
from svg_review_source import source_world, verified_source_pack
from svg_represented_source_objects import RepresentedSourceRays
from svg_source_navigation import SourceNavigation


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def blocks(wall, eye):
    relative = eye - wall['floorElevationMeters']
    return wall['unknownHeight'] or any(
        (lo <= relative and (hi is None or relative <= hi)) or (lo == 0 and relative < 0)
        for lo, hi in wall['bands'])


def reviewed_annotation_ids(directory, model):
    path = directory / 'specific-height-review.json'
    if not path.exists():
        return set()
    walls = {w['id']: w for w in model['walls']}
    return {r['wallId'] for r in read(path)['records']
            if r.get('gameplaySource') and r.get('bandsAboveSourceZero') == []
            and r['wallId'] in walls and walls[r['wallId']]['bands'] == []
            and walls[r['wallId']].get('unknownHeight') is False}


def displayed_difference(row, receiver, walls, shapes, tree):
    origin = np.asarray(row['originSvg'])
    angle = row['directionRadians']
    direction = np.array([math.cos(angle), math.sin(angle)])
    near, far = sorted([row['svgHit'], row['sourceHit']])
    segment = shapely.LineString([origin + direction * near, origin + direction * far])
    displayed = receiver.intersection(segment)
    for i in tree.query(segment, predicate='intersects'):
        if blocks(walls[i], row['eyeElevationMeters']):
            displayed = displayed.difference(shapes[i])
    return float(displayed.length)


def audit(name, output):
    directory = output / name
    model = read(directory / 'candidate-attack.json.gz')
    inventory = read(directory / 'assumed-height-review.json')['records']
    annotations = reviewed_annotation_ids(directory, model)
    classification = directory / 'specific-height-review.json'
    pack_file = ROOT / f'tactical-visibility-revision/full-height-input-v1/{name}/{name}.height.bin.gz'
    source = NativeReferenceModel(pack_file,
        ROOT / 'tactical-visibility-revision/native-tactical-rays-build/Release/tactical_reference_cast.dll')
    pack = verified_source_pack(name, source)
    objects = read(source_world(name) / 'geometry.json')['objects']
    represented = RepresentedSourceRays(name, source_world(name), objects)
    starts = np.array([o['firstFace'] for o in objects])
    alignment = ROOT / f'tactical-alignment-sides-v1/{name}.json'
    matrix = np.asarray(read(alignment)['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    scale = np.linalg.norm(matrix[0, :2])
    walls = model['walls']
    shapes = [polygon(w) for w in walls]
    tree = shapely.STRtree(shapes)
    supports = [s for s in model['supports'] if s.get('automaticStandingAllowed')]
    support_shapes = [polygon(s) for s in supports]
    support_tree = shapely.STRtree(support_shapes)
    receiver = shapely.union_all([polygon(r) for r in model['receiver']])
    ground = ground_sampler(model)
    navigation = SourceNavigation(name)
    records, findings, coverage, outside_display = [], [], [], []
    coverage_path = directory / 'source-coverage-poses.json'
    supplemental = read(coverage_path)['poses'] if coverage_path.exists() else []
    for wall in inventory:
        count = 0
        skipped = Counter()
        wall_findings = []
        stations = list(wall_stations(wall))
        extra_offsets = {}
        for i, pose in enumerate(supplemental):
            if pose['wallId'] != wall['wallId']:
                continue
            station = np.asarray(pose['targetSvg'])
            normal = np.asarray(pose['originSvg']) - station
            offset = np.linalg.norm(normal)
            normal /= offset
            stations.append((-1, float(i), station, np.array([normal[1], -normal[0]])))
            extra_offsets[float(i)] = offset
        for ring, along, station, tangent in stations:
            normal = np.array([-tangent[1], tangent[0]])
            for sign in ([1] if ring == -1 else [-1, 1]):
                # Move a probe farther from its wall when the first point is
                # inside source scenery or outside extracted walkable ground.
                # Reviewed boost supports remain valid without nav coverage.
                pose = None
                reason = 'outside-receiver'
                offsets = ([extra_offsets[along]] if ring == -1 else
                           [2.5, 4.5, 6.5, 1.25, .75, 9., 12., 16., 24.])
                for offset in offsets:
                    origin = station + sign * normal * offset
                    point = shapely.Point(origin)
                    if not receiver.contains(point):
                        reason = 'outside-receiver'
                        continue
                    floor = ground(origin)
                    if floor is None:
                        reason = 'missing-ground'
                        continue
                    candidates = [(floor, None)]
                    for sid in support_tree.query(point, predicate='intersects'):
                        candidates.append((support_elevation(supports[sid], origin), supports[sid]['id']))
                    elevation, support = max(candidates, key=lambda r: r[0])
                    eye = elevation + model['defaultCameraHeightMeters']
                    if any(blocks(walls[i], eye) for i in tree.query(point, predicate='intersects')):
                        reason = 'inside-active-ink'
                        continue
                    native = (origin - matrix[:, 2]) @ inverse.T
                    nav = [(i, z) for i, z in navigation.heights(native) if abs(z - elevation) <= .5]
                    if not nav and support is None:
                        reason = 'no-playable-source-origin'
                        continue
                    pose = True
                    break
                if pose is None:
                    skipped[reason] += 1
                    continue
                direction = -sign * normal
                limit = offset + 5.
                end = origin + direction * limit
                ray = shapely.LineString([origin, end])
                first, hit_wall = limit, None
                for i in tree.query(ray, predicate='intersects'):
                    if not blocks(walls[i], eye):
                        continue
                    distance = point.distance(shapes[i].intersection(ray))
                    if distance < first:
                        first, hit_wall = distance, walls[i]['id']
                native_end = (end - matrix[:, 2]) @ inverse.T
                hit = source.cast(np.r_[native, eye], np.r_[native_end, eye])
                source_distance = limit if hit is None else hit['distanceMeters'] * scale
                extra = represented.cast(np.r_[native, eye], np.r_[native_end, eye])
                if extra and extra['distanceMeters'] * scale < source_distance:
                    source_distance = extra['distanceMeters'] * scale
                else:
                    extra = None
                row = dict(wallId=wall['wallId'], stationSvg=station.tolist(),
                    ring=ring, distanceAlongSvg=along, side=sign, originSvg=origin.tolist(),
                    supportId=support, eyeElevationMeters=eye,
                    originOffsetSvg=offset, sourceNavigationTriangles=[i for i, _ in nav],
                    directionRadians=math.atan2(direction[1], direction[0]),
                    rangeSvg=limit, svgHit=first, hitWallId=hit_wall, sourceHit=source_distance,
                    differenceSvg=source_distance-first)
                if extra is not None:
                    row.update({key: value for key, value in extra.items() if key != 'distanceMeters'})
                    row['supplementaryRepresentedSource'] = True
                elif hit is not None:
                    face = int(pack['mapping'][hit['face']])
                    oid = int(np.searchsorted(starts, face, side='right')-1)
                    row.update(sourceFace=face, sourceObject=oid, sourcePath=objects[oid]['path'])
                index = len(records)
                records.append(row)
                count += 1
                if abs(row['differenceSvg']) > 3:
                    row['displayedDifferenceSvg'] = displayed_difference(row, receiver, walls, shapes, tree)
                    if row['displayedDifferenceSvg'] > 1e-6:
                        findings.append(row)
                        wall_findings.append(index)
                    else:
                        outside_display.append(row)
        coverage.append(dict(wallId=wall['wallId'], rays=count, skipped=dict(skipped),
                             findingIndices=wall_findings))
        print(name, len(coverage), '/', len(inventory), wall['wallId'], count, 'rays',
              len(wall_findings), 'findings', flush=True)
    payload = dict(records=records, coverage=coverage, findings=findings,
                   differencesOutsideDisplayedFloor=outside_display)
    rays_file = directory / 'assumed-height-source-rays.json.gz'
    rays_file.write_bytes(gzip.compress(json.dumps(payload, separators=(',', ':')).encode(), mtime=0))
    unresolved = sum(w['unknownHeight'] or any(hi is None for _, hi in w['bands']) for w in walls)
    report = dict(schemaVersion=1, map=name, status='blocked' if unresolved or findings else 'passed',
        unresolvedFindings=len(findings), assumedHeightRecords=unresolved,
        inventoryRecords=len(inventory), wallsWithProbes=sum(r['rays'] > 0 for r in coverage),
        annotationWallIds=sorted(annotations),
        coveredInventoryRecords=sum(r['rays'] > 0 or r['wallId'] in annotations for r in coverage),
        physicalWallsWithoutProbes=sum(r['rays'] == 0 and r['wallId'] not in annotations for r in coverage),
        classificationEvidenceSha256=digest(classification) if classification.exists() else None,
        rays=len(records), falseBlockFindings=int(sum(r['differenceSvg'] > 3 for r in findings)),
        leakFindings=int(sum(r['differenceSvg'] < -3 for r in findings)),
        differencesOutsideDisplayedFloor=len(outside_display),
        sourceNavigationSha256=digest(ROOT / f'nav/baked/{name}_source_xyz.json'),
        sourceWalkableNavigationSha256=digest(ROOT / f'nav/baked/{name}_navigation.json'),
        candidateSha256={s: digest(directory / f'candidate-{s}.json.gz') for s in ['attack', 'defense']},
        sourceGeometrySha256=pack['proof']['sourceGeometrySha256'],
        verifiedSourceTriangles=pack['proof']['verifiedTriangles'],
        sourcePackSha256=pack['proof']['sourcePackSha256'],
        supplementaryRepresentedObjects=represented.declarations,
        supplementarySourceAuditorSha256=digest(Path(__file__).with_name('svg_represented_source_objects.py')),
        alignmentSha256=digest(alignment), auditorSha256=digest(Path(__file__)),
        rayRecordsSha256=digest(rays_file),
        supplementalCoveragePosesSha256=digest(coverage_path) if coverage_path.exists() else None,
        limitations=['SVG registration and tactical semantics require review of each disagreement.',
                     'Default standing uses the highest locally eligible support and local ground.',
                     'A physical wall with zero probes is a coverage gap. Explicit gameplay-reviewed annotations need no wall probe.',
                     'Attack-space probes do not replace production rendering and defense parity checks.'])
    if report['coveredInventoryRecords'] != len(inventory):
        report['status'] = 'blocked'
    (directory / 'source-sightline-verification.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report), flush=True)
    return report


if __name__ == '__main__':
    from pathlib import Path
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=MAPS)
    parser.add_argument('--output', type=Path, default=DESTINATION)
    args = parser.parse_args()
    results = [audit(name, args.output) for name in args.maps]
    if any(r['status'] != 'passed' for r in results):
        raise SystemExit(1)
