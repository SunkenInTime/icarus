"""Check the exact frozen Icebox columns before/after audited Wind exclusions."""
import json
from pathlib import Path
import numpy as np
from audit_receiver_floor_clearance import sha
from native_reference_cast import NativeReferenceModel


def main():
    revision = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    before_path = revision/'icebox-nav-source-floor-clearance-v1/candidate-columns.npz'
    after_path = revision/'icebox-nav-source-floor-clearance-v2/candidate-columns.npz'
    report_path = after_path.parent/'report.json'
    report = json.loads(report_path.read_bytes())
    excluded = report['excludedEffectFullPackFaces']
    with np.load(before_path) as b, np.load(after_path) as a:
        for key in ['samples', 'displayedSvg', 'insideSvg', 'sampleIds', 'sourceHeights',
                    'supportIds', 'fullHeightPackFaces']:
            np.testing.assert_array_equal(a[key], b[key])
        affected = np.isin(b['hitFullHeightPackFaces'], excluded)
        for key in ['centerColumnClear', 'hitFullHeightPackFaces', 'hitHeight']:
            np.testing.assert_array_equal(a[key][~affected], b[key][~affected])
        if np.isin(a['hitFullHeightPackFaces'], excluded).any():
            raise ValueError('Excluded Wind face remains a hit')
        blocked = affected & (a['centerColumnClear'] == 0)
        if np.any(a['hitHeight'][blocked] < b['hitHeight'][blocked]):
            raise ValueError('Removing a Wind face produced an earlier obstruction')
        # Freeze actual coincident/remaining backing behavior rather than
        # asserting every affected ray must become clear.
        summary = dict(candidateColumns=len(affected), windFirstHits=int(affected.sum()),
                       remainingBlockedAfterWindRemoval=int(blocked.sum()),
                       unaffectedColumnsExactlyEqual=int((~affected).sum()))
        i = int(np.flatnonzero(affected)[0])
        feet = np.r_[a['samples'][a['sampleIds'][i], :2], a['sourceHeights'][i]]
    pack = revision/'full-height-input-v1/icebox/icebox.height.bin.gz'
    model = NativeReferenceModel(pack, revision/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    start, end = feet+[0, 0, .0001], feet+[0, 0, 1.75]
    assert model.cast(start, end) == model.cast(start, end, excluded_faces=())
    for invalid in [[-1], [len(model.arrays['faces'])], [1.5]]:
        try:
            model.cast(start, end, excluded_faces=invalid)
        except ValueError:
            continue
        raise AssertionError('Invalid face identity was accepted')
    result = dict(summary=summary, passed=True, inputSha256=sha(before_path),
        outputSha256=sha(after_path), exclusionRunReportSha256=sha(report_path),
        scriptSha256=sha(Path(__file__)), noUnrelatedColumnChanged=True,
        scope='Frozen source optical center rays only. Does not certify Pawn collision or choose floors.')
    (after_path.parent/'independent-exclusion-replay.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
