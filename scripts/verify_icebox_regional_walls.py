"""Trace regional wall intervals to frozen source and gameplay decisions.

This verifies the existing associations and their delivery. It does not treat
agreement with an old asset as independent evidence of a gameplay opening.
"""
from collections import Counter
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

import shapely
import numpy as np
from shapely.affinity import affine_transform

from audit_all_map_gameplay_levels import ROOT, read
from compile_reviewed_svg_height_map import polygon
from svg_review_source import source_world_for_hashes

OUT = Path('work/icebox-acceptance')
REV = ROOT / 'tactical-visibility-revision'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def intervals(record):
    floor = record['floorElevationMeters']
    return [[None if low == 0 else floor + low, floor + high]
            for low, high in record['bands']]


def gameplay_intervals(decision):
    floor = decision.get('floorElevationMeters', 0.)
    if 'bandsAboveFloor' in decision:
        return [[None if low == 0 else low + floor, high + floor]
                for low, high in decision['bandsAboveFloor']]
    if decision.get('mode', decision.get('suggestedMode')) == 'connected-ground':
        return []
    if decision.get('maximumSourceZ') is not None:
        return [[None, decision['maximumSourceZ']]]
    return []


def measured_intervals(sample):
    if sample['status'] == 'navigation-passage':
        return [[None if low == 0 else low, high] for low, high in sample['sourceBands'] if high > low]
    passages = sample.get('passageIntervalsMeters') or (
        [sample['passageIntervalMeters']] if sample.get('passageIntervalMeters') else [])
    top = sample['measuredTopMeters']
    if not passages:
        return [[None, math.ceil(top * 100000) / 100000]]
    result, bottom = [], None
    for low, high in sorted(passages):
        result.append([bottom, low])
        bottom = high
    if top > bottom:
        result.append([bottom, top])
    return result


def equal(a, b):
    return len(a) == len(b) and all(
        (x is None and y is None) or (x is not None and y is not None and abs(x-y) < .00002)
        for aa, bb in zip(a, b) for x, y in zip(aa, bb))


def local_station_expectations(parent, indices):
    """Resolve coincident source sections by their measured registration distance.

    The compiler retains all opposite-edge references even when only the
    closest section supplies the height. Equal-quality conflicting sections
    remain unresolved here, independent of the compiler's ordering.
    """
    groups = {}
    for index in indices:
        sample = parent['stations'][index]
        point = tuple(round(v, 4) for v in sample.get('associationSvg', sample['svg']))
        groups.setdefault(point, []).append(index)
    expected, resolutions = [], []
    measured = {'measured-facade', 'navigation-passage', 'measured-ground-boundary'}
    for point, ids in groups.items():
        def quality(index):
            sample = parent['stations'][index]
            return sample['status'] not in measured, sample.get('registrationDistanceMeters', float('inf'))
        best = min(quality(i) for i in ids)
        selected = [i for i in ids if quality(i) == best]
        expected.extend(measured_intervals(parent['stations'][i]) for i in selected)
        if len(ids) > 1:
            resolutions.append(dict(associationSvg=point, sourceStationIndices=ids,
                selectedSourceStationIndices=selected,
                registrationDistanceMeters=best[1] if math.isfinite(best[1]) else None,
                basis='Closest measured source section at the same registered map location.'))
    return expected, resolutions


def verify_facade_record(record, objects, geometry, tangent):
    """Check a shared facade's selected faces against its original source object."""
    assert all(k in record for k in ['originalWallId', 'sourceObject',
        'sourcePath', 'domainRings', 'samples', 'measuredTopMeters'])
    obj = objects[record['sourceObject']]
    assert obj['path'] == record['sourcePath'] and record['samples']
    from audit_assumed_svg_height_sections import clipped_height_intervals, merge_intervals
    tops = []
    for sample in record['samples']:
        faces = sample['faces']
        assert faces and all(obj['firstFace'] <= f < obj['firstFace']+obj['faceCount'] for f in faces)
        selected, intervals = clipped_height_intervals(
            geometry['points'][geometry['faces'][faces]].astype(float),
            np.asarray(sample['native']), tangent, .2, 1., include_flat=True)
        assert len(selected) == len(faces)
        bands = merge_intervals(intervals)
        assert np.asarray(bands).shape == np.asarray(sample['measuredBands']).shape
        assert np.max(abs(np.asarray(bands)-sample['measuredBands'])) < 1e-7
        tops.append(max(high for _, high in bands))
    # The recorded common edge uses the lowest complete local facade top.
    assert abs(min(tops)-record['measuredTopMeters']) < 1e-7


def verify(source_dir=None, output=OUT, candidate_dir=None, source_faces_path=None, decisions_path=None):
    algorithm_sha = sha(Path(__file__))
    map_name = read(source_dir/'source-inventory.json').get('map', 'icebox') if source_dir else 'icebox'
    folder = REV / f'all-map-finite-heights-v7/{map_name}'
    sources = dict(profiles=folder / 'local-source-profiles.json',
        compiled=folder / 'compiled-height-profile-review.json',
        semantic=folder / 'source-height-semantic-review.json',
        decisions=decisions_path or (REV / 'icebox-user-review-v4/icebox-decisions.json' if map_name == 'icebox' else
            REV / f'{map_name}-svg-height-decisions-v2/{map_name}-svg-height-decisions-v2.json'))
    profiles, compiled, semantic, decisions = [read(p) for p in sources.values()]
    nest = dict(profiles=[])
    if map_name == 'icebox':
        sources['nest'] = REV / 'all-map-height-resolution-v6/icebox/nest-end-review.json'
        nest = read(sources['nest'])
    assert compiled['sourceProfilesSha256'] == sha(sources['profiles'])
    assert semantic['status'] == 'passed' and semantic['unresolvedFindings'] == 0
    for name, expected in semantic['inputsSha256'].items():
        assert sha(folder / name) == expected, name
    source_path = source_world_for_hashes(map_name, profiles['sourceGeometrySha256'],
        profiles['sourceMetadataSha256'])/'geometry.npz'
    assert profiles['sourceGeometrySha256'] == sha(source_path)
    if map_name == 'icebox':
        assert sha(source_path) == nest['sourceGeometrySha256']
    metadata = read(source_path.with_suffix('.json'))
    assert profiles['sourceMetadataSha256'] == sha(source_path.with_suffix('.json'))
    objects = metadata['objects']
    specific = {}
    specific_path = folder/'specific-height-review.json'
    if specific_path.exists():
        specific_review = read(specific_path)
        assert specific_review['sourceGeometrySha256'] == sha(source_path)
        assert specific_review['sourceMetadataSha256'] == sha(source_path.with_suffix('.json'))
        sources['specific'] = specific_path
        with np.load(source_path) as geometry:
            for decision in specific_review['records']:
                bands = decision.get('bandsAboveSourceZero', [])
                if len(bands) != 1 or bands[0][0] != 0 or bands[0][1] is None:
                    continue
                tops = []
                for component in decision['sourceObjects']:
                    oid = component['object']
                    obj = objects[oid]
                    assert obj['path'] == component['path']
                    ids = np.arange(obj['firstFace'], obj['firstFace']+obj['faceCount'])
                    heights = geometry['points'][geometry['faces'][ids], 2].max(1)
                    top = float(heights.max())
                    tops.append(dict(sourceObject=oid, sourcePath=obj['path'], topMeters=top,
                        topSourceFaces=ids[abs(heights-top)<1e-7].tolist()))
                if tops and abs(max(t['topMeters'] for t in tops)-bands[0][1]) < .00002:
                    specific[decision['wallId']] = dict(decision=decision, sourceTops=tops)
    recovered, finite_props = {}, []
    if source_faces_path:
        recovery = read(source_faces_path)
        assert recovery['status'] == 'passed'
        assert recovery['inputsSha256']['profiles'] == sha(sources['profiles'])
        assert recovery['inputsSha256']['geometry'] == sha(source_path)
        assert recovery['inputsSha256']['metadata'] == sha(source_path.with_suffix('.json'))
        if 'finiteProps' in recovery['inputsSha256']:
            finite_path = REV/f'all-map-gameplay-v5/{map_name}/finite-prop-wall-review.json'
            assert recovery['inputsSha256']['finiteProps'] == sha(finite_path)
        recovered = {(r['parentWallId'], r['station']): r for r in recovery['localBoundarySections']}
        finite_props = recovery['finitePropDecisions']
    bindings = {r['wallId']: r for r in compiled['records'] if 'wallId' in r}
    facade_records = [r for r in compiled['records'] if 'wallId' not in r]
    facades = {}
    if facade_records:
        matrix = np.asarray(read(ROOT/f'tactical-alignment-sides-v1/{map_name}.json')['nativeToAttackSvg'])
        tangent = np.linalg.inv(matrix[:, :2]) @ np.array([0., 1.])
        tangent /= np.linalg.norm(tangent)
        with np.load(source_path) as geometry:
            for record in facade_records:
                verify_facade_record(record, objects, geometry, tangent)
                facades[record['originalWallId']] = record
    parents = {p['wallId']: p for p in profiles['records']}
    prior = {}
    for wall in (decisions['walls'].values() if isinstance(decisions['walls'], dict) else decisions['walls']):
        prior[wall['wallId']] = wall
        for part in wall.get('parts', []):
            prior[f"{wall['wallId']}-{part['id']}"] = part
    region = shapely.box(270, 140, 345, 225)
    if source_dir:
        inventory = read(source_dir/'source-inventory.json')
        alignment_path = ROOT/f'tactical-alignment-sides-v1/{map_name}.json'
        assert inventory['source']['alignmentSha256'] == sha(alignment_path)
        matrix = np.asarray(read(alignment_path)['nativeToAttackSvg'])
        region = affine_transform(shapely.from_geojson(json.dumps(inventory['sourceRegion'])),
            [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]])
    def asset_path(side):
        return candidate_dir/f'candidate-{side}.json.gz' if candidate_dir else Path(f'assets/maps/{map_name}_svg_height_{side}.json.gz')
    current = read(asset_path('attack'))
    def finite_associations(wall):
        shape = polygon(wall)
        previous = []
        matches = []
        for record in finite_props:
            decision = record['decision']
            if not (wall['id'] == decision['wallId'] or wall['id'].startswith(decision['wallId']+'-')):
                continue
            clip = polygon(dict(rings=decision['clipRings'], fillRule='evenodd')) if decision['clipRings'] else shape
            scope = clip.difference(shapely.union_all(previous))
            if shape.difference(scope).area < 1e-6:
                matches.append(record)
            previous.append(clip)
        return matches
    rows = []
    for wall in current['walls']:
        if not polygon(wall).intersects(region):
            continue
        wid = wall['id']
        actual = intervals(wall)
        row = dict(wallId=wid, actualAbsoluteIntervals=actual)
        facade = next((r for r in facades.values() if '-shared-facade-' in wid and
            polygon(wall).difference(polygon(dict(rings=r['domainRings']))).area < 1e-7), None)
        binding_id = re.sub(r'-shared-rest-\d+$', '', wid)
        if facade is not None:
            footprint = polygon(dict(rings=facade['domainRings']))
            assert polygon(wall).difference(footprint).area < 1e-7
            expected = [[None, facade['measuredTopMeters']]]
            row.update(basis='recorded-source-facade-sections', sourceObject=facade['sourceObject'],
                sourceFaces=sorted({f for s in facade['samples'] for f in s['faces']}),
                sourceSamples=len(facade['samples']), expectedAbsoluteIntervals=expected,
                status='passed' if equal(actual, expected) else 'interval-mismatch')
        elif binding_id in bindings and 'sourceStationIndices' in bindings[binding_id]:
            binding = bindings[binding_id]
            parent = parents[binding['parentWallId']]
            samples = [parent['stations'][i] for i in binding['sourceStationIndices']]
            expected, station_resolutions = local_station_expectations(parent, binding['sourceStationIndices'])
            source_faces = sorted({f for sample in samples for f in sample.get('sourceFaces', [])})
            recovered_sections = [recovered[(binding['parentWallId'], i)] for i in binding['sourceStationIndices']
                if (binding['parentWallId'], i) in recovered]
            source_faces = sorted(set(source_faces) | {f for s in recovered_sections
                for c in s['sourceComponents'] for f in c['sourceFaces']})
            faces_accounted = all(s.get('sourceFaces') or
                (s['status'] == 'navigation-passage' and s.get('navigationCrossing')) or
                recovered.get((binding['parentWallId'], i), {}).get('status') == 'passed'
                for i, s in zip(binding['sourceStationIndices'], samples))
            # Face references must remain in their declared placed object.
            for sample in samples:
                for component in sample.get('sourceComponents', []):
                    obj = objects[component['object']]
                    assert all(obj['firstFace'] <= f < obj['firstFace'] + obj['faceCount'] for f in component['faces'])
            row.update(basis='local-source-stations', sourceBinding=binding,
                sourceFaces=source_faces, expectedAbsoluteIntervals=expected,
                coincidentStationResolutions=station_resolutions,
                recoveredSourceSections=[s['station'] for s in recovered_sections],
                status=('unresolved-source-faces' if not faces_accounted else
                    'passed' if all(equal(actual, e) for e in expected) else 'interval-mismatch'))
        elif re.search(r'-paired-nest-profile-\d+(?:-|$)', wid):
            index = int(re.search(r'-paired-nest-profile-(\d+)(?:-|$)', wid).group(1))
            matches = [(p, s) for p in nest['profiles'] for s in p['sections']
                if s['index'] == index and wid.startswith(p['wallId'] + '-')
                and polygon(wall).intersection(shapely.box(*s['clipBox'])).area > 1e-10]
            assert len(matches) == 1, (wid, len(matches))
            profile, section = matches[0]
            expected = [[None if low == 0 else low, high] for low, high in section['bands']]
            row.update(basis='paired-gameplay-nest-section', sourceObjects=profile['sourceObjects'],
                gameplayEvidence=profile['gameplayEvidence'], section=index,
                expectedAbsoluteIntervals=expected,
                status='passed' if equal(actual, expected) else 'interval-mismatch')
        elif wid in specific:
            record = specific[wid]
            expected = [[None, record['decision']['bandsAboveSourceZero'][0][1]]]
            row.update(basis='recorded-specific-finite-source', sourceDecision=record,
                expectedAbsoluteIntervals=expected,
                status='passed' if equal(actual, expected) else 'interval-mismatch')
        else:
            finite_matches = finite_associations(wall)
            if finite_matches:
                assert len(finite_matches) == 1, wid
                match = finite_matches[0]
                expected = [[None, match['decision']['maximumSourceZ']]]
                row.update(basis='recorded-finite-prop-assembly', sourceDecision=match,
                    expectedAbsoluteIntervals=expected,
                    status='passed' if match['status']=='passed' and equal(actual, expected) else 'interval-mismatch')
                rows.append(row)
                continue
            keys = [k for k in prior if wid == k or wid.startswith(k + '-')]
            if not keys:
                row.update(status='unresolved-source-binding')
            else:
                key = max(keys, key=len)
                decision = prior[key]
                expected = gameplay_intervals(decision)
                row.update(basis='recorded-local-gameplay-decision', decisionId=key,
                    sourceObjects=decision.get('selectedSourceObjects', []),
                    sourceFaces=decision.get('sourceFaces', []), reason=decision['reason'],
                    expectedAbsoluteIntervals=expected,
                    status='passed' if equal(actual, expected) else 'interval-mismatch')
        rows.append(row)
    delivery = []
    for side in ['attack', 'defense']:
        previous = read(folder / f'candidate-{side}.json.gz')
        asset = asset_path(side)
        model = read(asset)
        assert model['walls'] == previous['walls'], side
        assert sha(folder / f'candidate-{side}.json.gz') == semantic['candidateSha256'][side]
        delivery.append(dict(side=side, assetSha256=sha(asset), wallsUnchangedSinceSourceReview=True))
    result = dict(status='passed' if all(r['status'] == 'passed' for r in rows) else 'unresolved',
        algorithmSha256=algorithm_sha, regionSvg=json.loads(shapely.to_geojson(region)),
        sourceInventorySha256=sha(source_dir/'source-inventory.json') if source_dir else None,
        recoveredSourceFacesSha256=sha(source_faces_path) if source_faces_path else None,
        sourceSha256={k: sha(v) for k, v in sources.items()}, rows=rows,
        counts=dict(Counter(r['status'] for r in rows)), delivery=delivery,
        scope='Every current wall intersecting the attack regional rectangle. Existing local source and gameplay associations retained; both side wall arrays match the reviewed revision.',
        limitations=['Local source profiles use measured stations, not a continuous proof of every vertical facade point.',
                    'Gameplay opening decisions are reused; no new live-game observation is claimed.'])
    output.mkdir(parents=True, exist_ok=True)
    (output / 'regional-wall-comparison.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(status=result['status'], counts=result['counts'])))
    for row in rows:
        if row['status'] != 'passed':
            print(json.dumps(row))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--output', type=Path, default=OUT)
    parser.add_argument('--candidate-dir', type=Path)
    parser.add_argument('--source-faces', type=Path)
    parser.add_argument('--decisions', type=Path, help='Explicit frozen gameplay wall decisions for this map.')
    args = parser.parse_args()
    verify(args.source, args.output, args.candidate_dir, args.source_faces, args.decisions)
