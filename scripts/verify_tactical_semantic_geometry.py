"""Keep low-cover fixtures and stacked branches visible in geometry reports."""
import argparse
import json
from pathlib import Path
import numpy as np
from audit_tactical_target_rays import ReferenceModel
from build_global_tactical_candidate import GroundField
from verify_tactical_transform import source_cast


def verify(revision, name):
    folder = revision / 'global-ground-complete-v2' / name
    source = ReferenceModel(revision / 'full-height-input-v1' / name / (name + '.height.bin.gz'))
    candidate = ReferenceModel(folder / (name + '.height.bin.gz'))
    field = GroundField(revision / 'global-ground-v1' / (name + '.tactical-ground.json.gz'))
    fixtures = json.loads(Path('test/fixtures/tactical_semantic_reference.json').read_text())
    report = dict(map=name, lowCover=[], stacked=[], scope='Source geometry regression and explicit policy deltas. Live landmark evidence is not exact camera-pose certification.')
    for case in fixtures['lowCoverCases']:
        if case['map'] != name:
            continue
        results = []
        for ray_name in ('modelRay', 'clearTargetBeforeWall'):
            if ray_name not in case:
                continue
            ray = case[ray_name]
            origin, target = np.array(ray['origin']), np.array(ray['target'])
            reference = field.heights(origin[None, :2])[0]
            origin[2] -= reference
            target[2] = origin[2]
            expected = source_cast(source, field, origin, target)
            actual = candidate.cast(origin, target)
            assert (expected is None) == (actual is None)
            unchanged = (actual is not None) == ray['blocked']
            results.append(dict(ray=ray_name, baselineBlocked=ray['blocked'], candidateBlocked=actual is not None, semanticOutcomeUnchanged=unchanged))
        report['lowCover'].append(dict(id=case['id'], results=results))
    for case in fixtures['overlapCases']:
        if case['map'] != name:
            continue
        ray = case['verticalBetweenStandingEyes']
        original_origin, original_target = np.array(ray['origin']), np.array(ray['target'])
        reference = field.heights(original_origin[None, :2])[0]
        origin, target = original_origin.copy(), original_target.copy()
        origin[2] -= reference
        target[2] -= reference
        expected, actual = source.cast(original_origin, original_target), candidate.cast(origin, target)
        assert (expected is None) == (actual is None)
        vertical_blocked = actual is not None
        error = None
        if expected is not None:
            restored = np.array(actual['point']) + [0, 0, reference]
            error = float(np.linalg.norm(restored - expected['point']))
            assert error < 1e-6
        directions = []
        for pair in case['horizontalRays']:
            outcomes = {}
            for branch in ('lower', 'upper'):
                original = pair[branch]
                origin, target = np.array(original['origin']), np.array(original['target'])
                origin[2] -= reference
                target[2] = origin[2]
                expected, actual = source_cast(source, field, origin, target), candidate.cast(origin, target)
                assert (expected is None) == (actual is None)
                outcomes[branch] = dict(baselineBlocked=original['blocked'], candidateBlocked=actual is not None,
                                        firstHitMeters=None if actual is None else actual['distanceMeters'])
            directions.append(dict(directionIndex=pair['directionIndex'], **outcomes))
        report['stacked'].append(dict(id=case['id'], originalFloors=case['floorMeters'], relativeFloors=[z - reference for z in case['floorMeters']],
                                      verticalBlockerRetained=vertical_blocked,
                                      verticalHitErrorMeters=error, directions=directions))
    (folder / 'semantic-geometry.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'scope'}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('map')
    args = parser.parse_args()
    verify(args.revision, args.map)
