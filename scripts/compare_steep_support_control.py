"""Compare support-filter controls at the same origins and common ray range."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
from summarize_floor_continuity import at


def run(revision, name):
    base_path = revision / ('source-floor-audited-terrain-v2/fracture-continuity.json' if name == 'fracture'
                            else 'source-floor-support-all-walkable-detached-v3/icebox-continuity.json')
    candidate_path = revision / f'steep-support-removal-control-v1/{name}-continuity.json'
    baseline = json.loads(base_path.read_text())
    candidate = json.loads(candidate_path.read_text())
    results = []
    for case in candidate['cases']:
        before = next(row for row in baseline['cases'] if row['id'] == case['id'])
        lookup = {(tuple(row['offset']), round(row['angleRadians'], 12)): row for row in before['samples']}
        maximum = before.get('query', [0] * 5 + [65])[5]
        rows = []
        for sample in case['samples']:
            original = lookup[(tuple(sample['offset']), round(sample['angleRadians'], 12))]
            np.testing.assert_allclose(sample['origin'], original['origin'], atol=1e-9, rtol=0)
            change = min(sample['distanceMeters'], maximum) - min(original['distanceMeters'], maximum)
            common = min(sample['distanceMeters'], original['distanceMeters'], maximum)
            events = np.array(sorted({0., common} | {p['start'] for s in (original, sample) for p in s['pieces'] if p['start'] < common}))
            tests = np.r_[events, (events[:-1] + events[1:]) / 2]
            floor_change = float(abs(at(original['pieces'], tests) - at(sample['pieces'], tests)).max())
            rows.append(dict(angleDegrees=float(np.rad2deg(sample['angleRadians'])), offset=sample['offset'],
                visibilityDistanceChangeMeters=change, maximumCommonPathFloorChangeMeters=floor_change,
                beforeDistanceMeters=original['distanceMeters'], afterDistanceMeters=sample['distanceMeters'],
                beforeHit=original['hit'], afterHit=sample['hit'],
                beforePieces=len(original['pieces']), afterPieces=len(sample['pieces'])))
        results.append(dict(id=case['id'], comparedRays=len(rows), commonMaximumRangeMeters=maximum,
            changesOver1cm=sum(abs(row['visibilityDistanceChangeMeters'])>.01 for row in rows),
            changesOver10cm=sum(abs(row['visibilityDistanceChangeMeters'])>.1 for row in rows),
            changesOver1m=sum(abs(row['visibilityDistanceChangeMeters'])>1 for row in rows),
            maximumDistanceChangeMeters=max(abs(row['visibilityDistanceChangeMeters']) for row in rows),
            meanBeforePieces=float(np.mean([row['beforePieces'] for row in rows])),
            meanAfterPieces=float(np.mean([row['afterPieces'] for row in rows])),
            largestChanges=sorted(rows,key=lambda row:abs(row['visibilityDistanceChangeMeters']),reverse=True)[:24]))
    output = candidate_path.with_name(f'{name}-filter-comparison.json')
    output.write_text(json.dumps(dict(scope=__doc__, baselineSha256=hashlib.sha256(base_path.read_bytes()).hexdigest(),
        candidateSha256=hashlib.sha256(candidate_path.read_bytes()).hexdigest(), cases=results,
        limitation='A changed ray is not automatically improved. Inspect actual source surfaces and lost/gained receiver regions before adopting a support filter.'), indent=2)+'\n')
    for row in results:
        print(name,row['id'],'>1cm/10cm/1m',row['changesOver1cm'],row['changesOver10cm'],row['changesOver1m'],
              'max',row['maximumDistanceChangeMeters'],'pieces',row['meanBeforePieces'],row['meanAfterPieces'],flush=True)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision',type=Path)
    parser.add_argument('--map',required=True,choices=['fracture','icebox'])
    args=parser.parse_args()
    run(args.revision,args.map)
