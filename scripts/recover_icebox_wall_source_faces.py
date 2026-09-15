"""Recover omitted face identities from frozen local wall measurements."""
import argparse
from functools import lru_cache
import json
from pathlib import Path

import numpy as np

from audit_all_map_gameplay_levels import ROOT, read
from audit_assumed_svg_height_sections import clipped_height_intervals, merge_intervals, wall_stations
from compile_icebox_ramp_ground import sha
from svg_review_source import verified_source_pack, source_world_for_hashes

REV = ROOT/'tactical-visibility-revision'


def build(output, map_name='icebox'):
    profiles_path = REV/f'all-map-finite-heights-v7/{map_name}/local-source-profiles.json'
    profiles = read(profiles_path)
    world = source_world_for_hashes(map_name, profiles['sourceGeometrySha256'], profiles['sourceMetadataSha256'])
    inputs = dict(profiles=REV/f'all-map-finite-heights-v7/{map_name}/local-source-profiles.json',
        inventory=REV/f'all-map-height-resolution-v6/{map_name}/assumed-height-review.json',
        geometry=world/'geometry.npz',
        metadata=world/'geometry.json',
        alignment=ROOT/f'tactical-alignment-sides-v1/{map_name}.json')
    finite_path = REV/f'all-map-gameplay-v5/{map_name}/finite-prop-wall-review.json'
    if finite_path.exists():
        inputs['finiteProps'] = finite_path
    hashes = {k: sha(p) for k, p in inputs.items()}
    assert profiles['sourceGeometrySha256'] == hashes['geometry']
    assert profiles['sourceMetadataSha256'] == hashes['metadata']
    objects = read(inputs['metadata'])['objects']
    archive = np.load(inputs['geometry'])
    points, faces = archive['points'], archive['faces']
    pack = verified_source_pack(map_name)
    retained = pack['retained']
    inventory = {r['wallId']: r for r in read(inputs['inventory'])['records']}
    matrix = np.asarray(read(inputs['alignment'])['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])

    @lru_cache(maxsize=128)
    def geometry(oid):
        obj = objects[oid]
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        ids = ids[retained[ids]]
        return ids, points[faces[ids]].astype(float)

    records = []
    for parent in profiles['records']:
        missing = [(i, s) for i, s in enumerate(parent['stations'])
                   if s['status'] == 'measured-ground-boundary' and not s.get('sourceFaces')]
        if not missing:
            continue
        stations = list(wall_stations(inventory[parent['wallId']]))
        assert len(stations) == len(parent['stations'])
        for index, sample in missing:
            tangent = inverse @ stations[index][3]
            tangent /= np.linalg.norm(tangent)
            center = np.asarray(sample['native'])
            components = []
            for oid in sample['sourceObjects']:
                ids, triangles = geometry(oid)
                near = np.flatnonzero((triangles[:, :, :2].min(1) <= center + .9).all(1)
                    & (triangles[:, :, :2].max(1) >= center - .9).all(1))
                selected, bands = clipped_height_intervals(triangles[near], center, tangent, .15, .85, include_flat=True)
                if len(selected):
                    components.append(dict(sourceObject=oid, sourcePath=objects[oid]['path'],
                        sourceFaces=ids[near[selected]].tolist(), bands=merge_intervals(bands)))
            actual = merge_intervals([b for c in components for b in c['bands']])
            expected = sample['sourceBands']
            match = len(actual) == len(expected) and bool(actual) and np.allclose(actual, expected, rtol=0, atol=.00002)
            records.append(dict(parentWallId=parent['wallId'], station=index,
                status='passed' if match else 'source-section-mismatch', nativeCenter=center.tolist(),
                nativeTangent=tangent.tolist(), halfAlongMeters=.15, halfCrossMeters=.85,
                sourceComponents=components, expectedBands=expected, measuredBands=actual))
    finite = []
    for i, decision in enumerate(read(finite_path)['evidence'] if finite_path.exists() else []):
        sources = []
        for oid, path in zip(decision['sourceObjects'], decision['sourcePaths']):
            assert objects[oid]['path'] == path
            obj = objects[oid]
            ids = np.arange(obj['firstFace'], obj['firstFace']+obj['faceCount'])
            heights = points[faces[ids], 2].max(1)
            top = float(heights.max())
            sources.append(dict(sourceObject=oid, sourcePath=path, topMeters=top,
                topSourceFaces=ids[np.abs(heights-top) < 1e-7].tolist()))
        top = max(s['topMeters'] for s in sources)
        finite.append(dict(decisionIndex=i, decision=decision, sources=sources,
            status='passed' if abs(top-decision['maximumSourceZ']) < .00002 else 'source-top-mismatch'))
    result = dict(status='passed' if all(r['status']=='passed' for r in records+finite) else 'unresolved',
        inputsSha256=hashes, inputPaths={k: str(p) for k, p in inputs.items()}, sourcePack=pack['proof'],
        algorithmSha256={p.name: sha(p) for p in [Path(__file__), Path(__file__).with_name('audit_assumed_svg_height_sections.py')]},
        localBoundarySections=records, finitePropDecisions=finite,
        scope='Recover exact source faces for previously recorded sections and finite prop caps. Existing gameplay associations remain historical decisions; this does not add continuous facade or live-game evidence.')
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(dict(status=result['status'], localSections=len(records), finiteDecisions=len(finite),
        failures=[r for r in records+finite if r['status']!='passed'])))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('work/icebox-all-v2/recovered-wall-source-faces.json'))
    parser.add_argument('--map', default='icebox')
    args = parser.parse_args()
    build(args.output, args.map)
