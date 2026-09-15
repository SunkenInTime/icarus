"""Freeze explicit source-directed pipe/generator renderer controls."""
import argparse
import gzip
import json
from pathlib import Path

import numpy as np

from build_global_tactical_candidate import GroundField
from native_compact_wall_profiles import sha
from tactical_alignment_composite import explicit_warp

REV = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def prepare(output, candidate=None):
    output.mkdir(parents=True, exist_ok=False)
    cfg = json.loads((REV/'display-all-candidate-config-v1.json').read_text())['maps']['split']
    ground = GroundField(Path(cfg['groundFieldFile']))
    w = json.loads(gzip.decompress(Path(cfg['displayWarpFile']).read_bytes()))
    native = np.asarray(w['sourceNativeMeters']).reshape(-1, 2)
    target = np.asarray(w['targetAttackSvg']).reshape(-1, 2)
    forward = explicit_warp(native, target-native, np.asarray(w['triangles']).reshape(-1, 3))
    legacy = np.asarray(json.loads(Path(cfg['projectionFile']).read_text())['nativeToAttackSvg'])
    legacy_inverse = np.linalg.inv(legacy[:, :2])
    cases = []
    queries = {}

    def add(identifier, original, relative, evidence, category):
        original = np.asarray(original, dtype=float)
        relative = np.asarray(relative, dtype=float)
        assert np.array_equal(original[[0, 1, 3, 4, 5, 6]], relative[[0, 1, 3, 4, 5, 6]])
        floor = float(ground.heights(original[None, :2])[0])
        assert abs(original[2]-floor-relative[2]) < 1e-12
        origin_svg = forward.apply(original[None, :2])[0]
        end_xy = original[:2]+original[3:5]*original[5]
        target_svg = forward.apply(end_xy[None])[0]
        saved_xy = (origin_svg-legacy[:, 2])@legacy_inverse.T
        assert np.max(np.abs(saved_xy@legacy[:, :2].T+legacy[:, 2]-origin_svg)) < 1e-10
        cases.append(dict(id=identifier, category=category,
            query=[*saved_xy, original[2], *original[3:]],
            originSvg=origin_svg.tolist(), targetSvg=target_svg.tolist(),
            agentIndex=4 if identifier.startswith('clove') else 8,
            eyeHeightMode='absolute', sourceNativeOrigin=original[:2].tolist(),
            physicalSourceEye=original[:3].tolist(), originalPhysicalQuery=original.tolist(),
            relativeControlEyeMeters=float(relative[2]), sourceGroundAtOriginMeters=floor,
            sourceEvidence=evidence))
        queries[identifier] = relative.tolist()

    pipe_path = REV/'split-pipe130-profile-region-proposal-v5/regression-fixtures.json'
    for row in json.loads(pipe_path.read_text())['fixtures']:
        if 'provisionalAppQuery' in row:
            relative = np.array(row['provisionalAppQuery'])
            original = relative.copy()
            original[2] += ground.heights(original[None, :2])[0]
            category = 'Frozen app-relative pipe or left-opening preservation control'
        else:
            original = np.array(row['sourceQuery'])
            relative = original.copy()
            relative[2] -= ground.heights(original[None, :2])[0]
            category = 'Synthetic upper pipe height; provisional floor renderer'
        add(row['id'], original, relative, row, category)

    generator_path = REV/'split-generator-connected-profile-proposal-v4/original-height-regression-fixtures.json'
    for row in json.loads(generator_path.read_text())['records']:
        original = np.array(row['originalWorldQuery'])
        relative = original.copy()
        relative[2] -= ground.heights(original[None, :2])[0]
        add('generator-'+row['id'], original, relative, row,
            'Explicit source observer height; provisional floor renderer, not a standing-pose certification')

    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']['split']
    policy = ('Frozen physical XY/headings on both sides. Original observer eye is converted using '
              'the existing control ground only at the origin. This does not make the provisional '
              'floor-following ray equivalent to an original horizontal source ray. No visibility '
              'acceptance is inferred from the original first-hit labels.')
    fixture = dict(map='split', navigationSha256=catalog['navigationSha256'],
        packSha256=catalog['packSha256'], policy=policy, cases=cases)
    (output/'split-fixtures.json').write_text(json.dumps(fixture, indent=2)+'\n')
    cfg.update(automaticQueries=False, samePhysicalPoseAcrossSides=True,
        queriesById=queries, scopeLabel=policy)
    baseline = REV/'split-wall-family-normalized-candidate-v29'
    for label, folder in [('control', baseline), ('candidate', candidate)]:
        if folder is None:
            continue
        pack = folder/'split.height.bin.gz'
        assert pack.exists(), pack
        entry = dict(cfg, folder=str(folder/'native'), candidatePackSha256=sha(pack))
        (output/f'{label}-config.json').write_text(json.dumps(dict(scope=policy, maps=dict(split=entry)), indent=2)+'\n')
    (output/'provenance.json').write_text(json.dumps(dict(
        pipeFixtures=dict(path=str(pipe_path), sha256=sha(pipe_path)),
        generatorFixtures=dict(path=str(generator_path), sha256=sha(generator_path)),
        warpSha256=sha(Path(cfg['displayWarpFile'])),
        groundSha256=sha(Path(cfg['groundFieldFile'])),
        scriptSha256=sha(Path(__file__)), fixtureCount=len(cases),
        candidatePrepared=candidate is not None, productionMutation=False), indent=2)+'\n')
    print(json.dumps(dict(output=str(output), cases=len(cases), queries=queries), indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--candidate', type=Path)
    args = parser.parse_args()
    prepare(args.output, args.candidate)
