"""Separate XY silhouette changes from floor-profile changes on frozen rays."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from audit_tactical_target_rays import ReferenceModel
from audit_null_material_receiver_scope import source_receiver


def cast_profile(source, sample, origin):
    direction = np.array([np.cos(sample['angleRadians']), np.sin(sample['angleRadians'])])
    for piece in sample['pieces']:
        xy = origin[:2] + np.array([piece['start'], piece['end']])[:, None] * direction
        xyz = np.c_[xy, np.array(piece['ground']) + 1.75]
        hit = source.cast(*xyz, min_distance=1e-5 if piece['start'] == 0 else 0,
                          end_padding=1e-5 if piece['end'] == 65 else 0)
        if hit:
            return dict(distanceMeters=float((np.array(hit['point'][:2]) - origin[:2]) @ direction), hit=hit)
    # Frozen paths stop at their first hit, so a counterfactual miss is a lower
    # bound. Do not invent a continuation beyond the recorded floor profile.
    return dict(distanceMeters=None, clearThroughMeters=sample['pieces'][-1]['end'], hit=None)


def run(revision):
    folder = revision / 'source-floor-audited-terrain-v1'
    path = folder / 'fracture-continuity.json'
    data = json.loads(path.read_text())
    source_path = revision / 'full-height-input-v1/fracture/fracture.height.bin.gz'
    source = ReferenceModel(source_path)
    receiver = source_receiver(revision, 'fracture')
    rows = []
    for case in data['cases']:
        base = {round(row['angleRadians'], 12): row for row in case['samples'] if row['offset'] == [0, 0]}
        for sample in case['samples']:
            if sample['offset'] == [0, 0]:
                continue
            original = base[round(sample['angleRadians'], 12)]
            if abs(sample['distanceMeters'] - original['distanceMeters']) <= 1:
                continue
            results = []
            for profile_name, profile in [('original', original), ('shifted', sample)]:
                for origin_name, position in [('original', original['origin']), ('shifted', sample['origin'])]:
                    result = cast_profile(source, profile, np.array(position))
                    if profile_name == origin_name:
                        assert result['distanceMeters'] is not None
                        assert abs(result['distanceMeters'] - profile['distanceMeters']) < 1e-6
                    results.append(dict(profile=profile_name, origin=origin_name, **result))
            direction = np.array([np.cos(sample['angleRadians']), np.sin(sample['angleRadians'])])
            near, far = sorted([original['distanceMeters'], sample['distanceMeters']])
            line = shapely.LineString(np.array(original['origin'][:2]) + np.array([near, far])[:, None] * direction)
            overlap = line.intersection(receiver)
            rows.append(dict(case=case['id'], angleDegrees=float(np.rad2deg(sample['angleRadians'])),
                             offset=sample['offset'], distanceChangeMeters=sample['distanceMeters']-original['distanceMeters'],
                             changedRangeWithinJointReceiverMeters=float(overlap.length), counterfactuals=results))
            print(case['id'], round(np.rad2deg(sample['angleRadians'])), sample['offset'],
                  [(r['profile'],r['origin'],r['distanceMeters']) for r in results], flush=True)
    output = folder / 'fracture-grazing-counterfactuals.json'
    output.write_text(json.dumps(dict(scope=__doc__, inputSha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        sourceSha256=hashlib.sha256(source_path.read_bytes()).hexdigest(), cases=rows,
        limitation='Swapping frozen height profiles isolates XY from floor policy effects. A counterfactual miss is only clear through the last recorded piece. Receiver metric is the union of both exact inverse-W artwork fills.'), indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    run(parser.parse_args().revision)
