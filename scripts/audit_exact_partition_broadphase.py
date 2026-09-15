"""Bounded independent controls for exact partition serialization and indexing.

Does not modify the verifier, global integer limits, or source geometry.
"""
import hashlib
import json
from pathlib import Path
import random
import sys
import time
from fractions import Fraction

import numpy as np

from exact_source_partition import candidate_pairs, decimal_integer, prove_partition


OUTPUT = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/exact-partition-broadphase-independent-review-v1')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def decimal_decode(text):
    sign = -1 if text.startswith('-') else 1
    text = text.lstrip('-')
    result = 0
    for start in range(0, len(text), 9):
        chunk = text[start:start+9]
        result = result * 10**len(chunk) + int(chunk)
    return sign * result


def overlapping_pairs(boxes):
    return {(i, j) for i in range(len(boxes)) for j in range(i)
            if boxes[i][0] < boxes[j][2] and boxes[j][0] < boxes[i][2]
            and boxes[i][1] < boxes[j][3] and boxes[j][1] < boxes[i][3]}


def main():
    OUTPUT.mkdir(exist_ok=True)
    helper = Path(__file__).with_name('exact_source_partition.py')
    before_hash = sha(helper)
    started = time.perf_counter()
    limit = sys.get_int_max_str_digits()
    tested_integers = 0
    for digits in (1, 9, 10, 603, 604, 5001, 16001):
        for value in (10**(digits-1), 10**digits-1, 10**digits+1):
            for signed in (value, -value):
                assert decimal_decode(decimal_integer(signed)) == signed
                tested_integers += 1
    assert decimal_integer(0) == '0'
    assert sys.get_int_max_str_digits() == limit

    rng = random.Random(92751)
    batches = []
    for batch in range(12):
        boxes = []
        for i in range(96):
            center = [Fraction(0), Fraction(1, 2), Fraction(1),
                      Fraction(rng.randrange(1024), 1024)][i % 4]
            epsilon = Fraction(1, 2**rng.choice([40, 60, 120, 1100, 1300]))
            lower = max(Fraction(0), center-epsilon)
            upper = min(Fraction(1), center+epsilon)
            ymin = Fraction(rng.randrange(10), 20)
            boxes.append((lower, ymin, upper, ymin+Fraction(1, 2)))
        expected = overlapping_pairs(boxes)
        candidates = set(candidate_pairs(boxes))
        assert expected <= candidates, ('Missed exact overlap', batch, expected-candidates)
        batches.append(dict(batch=batch, boxes=len(boxes), exactOverlaps=len(expected),
                            indexCandidates=len(candidates), missed=0))

    epsilon = Fraction(1, 2**1300)
    boxes = [(Fraction(0), Fraction(0), epsilon*(i+1), epsilon*(i+2)) for i in range(96)]
    underflow_pairs = set(candidate_pairs(boxes))
    assert len(underflow_pairs) == 96*95//2

    # Compare every exact report field, not just the final pass/fail value.
    pieces = np.asarray([[[0., 0.], [(i+1)/80, 1-(i+1)/80], [i/80, 1-i/80]]
                         for i in range(80)])
    bary = np.concatenate((1-pieces.sum(2, keepdims=True), pieces), axis=2)
    partitions = dict(fan=bary, missing=np.delete(bary, 19, axis=0),
                      duplicate=np.concatenate((bary, bary[30:31])))
    exact_reports = {}
    for name, value in partitions.items():
        indexed = prove_partition(value)
        brute = prove_partition(value, spatial_index=False)
        assert indexed == brute, ('Full exact reports differ', name)
        exact_reports[name] = indexed
    assert sha(helper) == before_hash, 'Verifier changed during independent audit'
    report = dict(scope=__doc__, passed=True, helper=dict(path=str(helper.resolve()), sha256=before_hash),
                  auditScript=dict(path=str(Path(__file__).resolve()), sha256=sha(Path(__file__))),
                  randomSeed=92751, signedDecimalRoundTrips=tested_integers,
                  maximumDecimalDigits=16002, globalIntegerDigitLimitBefore=limit,
                  globalIntegerDigitLimitAfter=sys.get_int_max_str_digits(),
                  rationalBoxBatches=batches, twoAxisUnderflowPairs=len(underflow_pairs),
                  exactReportComparisons=list(exact_reports),
                  elapsedSeconds=time.perf_counter()-started,
                  limits=['Bounded controls, not a proof for arbitrary geometry libraries.',
                          'Production partition boxes lie in the clipped [0,1] squared source domain.',
                          'Broadphase does not change rational area decisions or source geometry.'])
    (OUTPUT/'report.json').write_text(json.dumps(report, indent=2))
    (OUTPUT/'full-exact-report-controls.json').write_text(json.dumps(exact_reports, indent=2))
    summary = (f"Passed: {tested_integers} signed decimal controls, "
               f"{sum(b['exactOverlaps'] for b in batches)+len(underflow_pairs)} retained exact overlap pairs, "
               f"{len(exact_reports)} identical indexed/brute-force reports. Helper SHA {before_hash}.")
    (OUTPUT/'run.txt').write_text(summary+'\n')
    print(summary)


if __name__ == '__main__':
    main()
