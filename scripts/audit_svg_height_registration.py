"""Separate local height gaps from nearby source/SVG registration differences.

This report is diagnostic. A nearby solid face does not by itself disprove a
gameplay doorway, and none of these categories accepts or installs a candidate.
"""
import argparse
from collections import Counter
import json
import math
from pathlib import Path

import numpy as np

from audit_all_map_gameplay_levels import ROOT, MAPS, read
from native_reference_cast import NativeReferenceModel
from resolve_local_svg_wall_profiles import OUTPUT, sha
from svg_review_source import source_world, verified_source_pack


def inspect(name, output=OUTPUT):
    directory = output / name
    source_rays = directory / 'assumed-height-source-rays.json.gz'
    rays = read(source_rays)
    profiles = {w['wallId']: w for w in read(directory / 'local-source-profiles.json')['records']}
    compilation = read(directory / 'compiled-height-profile-review.json')
    decisions = {r['wallId']: r for r in compilation['records'] if r.get('parentWallId')}
    matrix = np.asarray(read(ROOT / f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    scale = np.linalg.norm(matrix[0, :2])
    source = NativeReferenceModel(ROOT / f'tactical-visibility-revision/full-height-input-v1/{name}/{name}.height.bin.gz',
        ROOT / 'tactical-visibility-revision/native-tactical-rays-build/Release/tactical_reference_cast.dll')
    pack = verified_source_pack(name, source)
    objects = read(source_world(name) / 'geometry.json')['objects']
    starts = np.array([o['firstFace'] for o in objects])
    results = []
    for finding_index, row in enumerate(rays['findings']):
        result = dict(findingIndex=finding_index, wallId=row['wallId'],
                      hitWallId=row['hitWallId'], stationSvg=row['stationSvg'])
        angle = row['directionRadians']
        direction = np.array([math.cos(angle), math.sin(angle)])
        crossing = np.array(row['originSvg']) + direction * row['svgHit']
        if row['differenceSvg'] < 0:
            profile = profiles[row['wallId']]
            sample_index = min(range(len(profile['stations'])), key=lambda i:
                np.linalg.norm(np.array(profile['stations'][i]['svg']) - row['stationSvg']))
        else:
            decision = decisions.get(row['hitWallId'])
            if decision is None:
                result['category'] = 'earlier-finite-height-record-needs-review'
                results.append(result)
                continue
            profile = profiles[decision['parentWallId']]
            sample_index = min(decision['sourceStationIndices'], key=lambda i:
                np.linalg.norm(np.array(profile['stations'][i]['associationSvg']) - crossing))
        sample = profile['stations'][sample_index]
        members = sample.get('sourceComponents', [])
        eye = row['eyeElevationMeters']
        eye_members = [c['object'] for c in members if any(lo <= eye <= hi for lo, hi in c['bands'])]
        result.update(profileWallId=profile['wallId'], sourceStationIndex=sample_index,
            sourceObject=sample.get('sourceObject'), sourcePath=sample.get('sourcePath'),
            sourceBands=sample.get('sourceBands'), sourceEyeObjects=eye_members,
            eyeElevationMeters=eye, displayedDifferenceSvg=row.get('displayedDifferenceSvg'))
        if row['differenceSvg'] < 0:
            result['category'] = ('associated-source-solid-precedes-ink'
                if row.get('sourceObject') in [c['object'] for c in members]
                else 'other-source-object-precedes-ink')
            result['firstSourceObject'] = row.get('sourceObject')
            result['firstSourcePath'] = row.get('sourcePath')
        elif not eye_members:
            result['category'] = 'closed-across-local-source-height-gap'
        else:
            tangent = np.array([-direction[1], direction[0]])
            offsets = [sign * d for d in np.arange(.25, 3.01, .25) for sign in [-1, 1]]
            matches = []
            for offset in offsets:
                origin_svg = np.array(row['originSvg']) + tangent * offset
                end_svg = origin_svg + direction * row['rangeSvg']
                a, b = [(p - matrix[:, 2]) @ inverse.T for p in [origin_svg, end_svg]]
                hit = source.cast(np.r_[a, eye], np.r_[b, eye])
                if hit is None:
                    continue
                face = int(pack['mapping'][hit['face']])
                oid = int(np.searchsorted(starts, face, side='right') - 1)
                distance = hit['distanceMeters'] * scale
                if oid in eye_members and abs(distance - row['svgHit']) <= 3.:
                    matches.append(dict(tangentOffsetSvg=float(offset), sourceFace=face,
                        sourceObject=oid, sourcePath=objects[oid]['path'], sourceHitSvg=distance,
                        longitudinalDifferenceSvg=distance-row['svgHit']))
            result['nearbySourceContacts'] = matches
            result['category'] = ('nearby-source-face-at-same-height' if matches
                                  else 'source-height-band-without-nearby-ray-contact')
        results.append(result)
    counts = dict(Counter(r['category'] for r in results))
    report = dict(schemaVersion=1, map=name, status='diagnostic-requires-review', counts=counts,
        algorithmSha256=sha(Path(__file__)), sourceRaysSha256=sha(source_rays),
        sourceProfilesSha256=sha(directory / 'local-source-profiles.json'),
        candidateSha256={s: sha(directory / f'candidate-{s}.json.gz') for s in ['attack', 'defense']},
        records=results)
    (directory / 'source-registration-diagnostics.json').write_text(json.dumps(report, separators=(',', ':')))
    print(name, counts, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=MAPS)
    for name in parser.parse_args().maps:
        inspect(name)
