"""Measure nearby-origin changes without declaring every silhouette change wrong."""
import argparse
import json
from pathlib import Path
import numpy as np


def at(pieces, distances):
    ends = np.array([piece['end'] for piece in pieces])
    ids = np.minimum(np.searchsorted(ends, distances, side='right'), len(pieces) - 1)
    output = []
    for distance, index in zip(distances, ids):
        piece = pieces[index]
        t = np.clip((distance - piece['start']) / (piece['end'] - piece['start']), 0, 1)
        output.append((1 - t) * piece['ground'][0] + t * piece['ground'][1])
    return np.array(output)


def summarize(path):
    document = json.loads(path.read_text())
    results = []
    for case in document['cases']:
        base = [sample for sample in case['samples'] if sample['offset'] == [0, 0]]
        comparisons = []
        for sample in case['samples']:
            if sample['offset'] == [0, 0]:
                continue
            reference = min(base, key=lambda row: abs(row['angleRadians'] - sample['angleRadians']))
            maximum = min(reference['distanceMeters'], sample['distanceMeters'])
            events = np.array(sorted({0., maximum} | {p['start'] for s in (reference, sample) for p in s['pieces'] if p['start'] < maximum}))
            tests = np.r_[events, (events[:-1] + events[1:]) * .5]
            floor_delta = abs(at(reference['pieces'], tests) - at(sample['pieces'], tests))
            comparisons.append(dict(angleRadians=sample['angleRadians'], offset=sample['offset'],
                distanceChangeMeters=sample['distanceMeters'] - reference['distanceMeters'],
                originalDistanceMeters=reference['distanceMeters'], shiftedDistanceMeters=sample['distanceMeters'],
                maximumCommonPathFloorChangeMeters=float(floor_delta.max()),
                maximumFloorChangeAtMeters=float(tests[floor_delta.argmax()]),
                originalHit=reference['hit'], shiftedHit=sample['hit']))
        ranked = sorted(comparisons, key=lambda row: abs(row['distanceChangeMeters']), reverse=True)
        results.append(dict(id=case['id'], rays=len(case['samples']), comparisons=len(comparisons),
            distanceChangesOver1m=sum(abs(row['distanceChangeMeters']) > 1 for row in comparisons),
            distanceChangesOver1mWithFloorChangeOver35cm=sum(abs(row['distanceChangeMeters']) > 1 and row['maximumCommonPathFloorChangeMeters'] > .35 for row in comparisons),
            floorChangesOverStandingHeight=sum(row['maximumCommonPathFloorChangeMeters'] > 1.75 for row in comparisons),
            maximumDistanceChangeMeters=max(abs(row['distanceChangeMeters']) for row in comparisons),
            maximumFloorChangeMeters=max(row['maximumCommonPathFloorChangeMeters'] for row in comparisons),
            largestDistanceChanges=ranked[:12],
            floorCoupledSightlineChanges=[row for row in ranked if abs(row['distanceChangeMeters']) > 1 and row['maximumCommonPathFloorChangeMeters'] > .35],
            largestFloorChanges=sorted(comparisons, key=lambda row: row['maximumCommonPathFloorChangeMeters'], reverse=True)[:12]))
        print(case['id'], 'rays', len(case['samples']), 'max distance/floor changes', results[-1]['maximumDistanceChangeMeters'], results[-1]['maximumFloorChangeMeters'], flush=True)
    output = path.with_name(path.stem + '-summary.json')
    output.write_text(json.dumps(dict(scope=__doc__, source=str(path), cases=results), indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    summarize(parser.parse_args().input)
