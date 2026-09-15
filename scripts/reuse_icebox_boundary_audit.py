"""Reuse contact comparisons only for identical cones and unchanged wall data."""
import argparse
import json
from pathlib import Path

from audit_all_map_gameplay_levels import read
from compile_icebox_ramp_ground import sha


def reuse(previous_boundaries, boundaries, previous_candidate, candidate):
    previous = read(previous_boundaries/'export-summary.json')
    current = read(boundaries/'export-summary.json')
    verified = read(previous_boundaries/'boundary-audit.json')
    assert verified['flaggedCones'] == verified['flaggedIntervals'] == 0
    cones_hash = sha(boundaries/'cones.jsonl')
    assert cones_hash == sha(previous_boundaries/'cones.jsonl') == verified['conesSha256']
    assert cones_hash == previous['conesSha256'] == current['conesSha256']
    assert sha(boundaries/'cases.json') == sha(previous_boundaries/'cases.json') == current['casesSha256'] == previous['casesSha256']
    assert previous['emitted'] == current['emitted'] == verified['cones']
    assert previous['skippedCases'] == current['skippedCases']
    evidence = []
    for side in ['attack', 'defense']:
        before_path = previous_candidate/f'candidate-{side}.json.gz'
        after_path = candidate/f'candidate-{side}.json.gz'
        asset = f'assets/maps/icebox_svg_height_{side}.json.gz'
        assert sha(before_path) == previous['assetSha256'][asset]
        assert sha(after_path) == current['assetSha256'][asset]
        before, after = read(before_path), read(after_path)
        assert before['walls'] == after['walls'], side
        assert before['receiver'] == after['receiver'], side
        evidence.append(dict(side=side, previousAssetSha256=sha(before_path), candidateSha256=sha(after_path),
            wallRecordsUnchanged=True, receiverRecordsUnchanged=True))
    proof = dict(status='passed', previousBoundaryAuditSha256=sha(previous_boundaries/'boundary-audit.json'),
        previousExportSha256=sha(previous_boundaries/'export-summary.json'),
        currentExportSha256=sha(boundaries/'export-summary.json'),
        conesSha256=cones_hash, records=evidence, algorithmSha256=sha(Path(__file__)),
        basis='Current native cone bytes and authoritative wall records are identical to the completed contact comparison.')
    (boundaries/'contact-reuse-verification.json').write_text(json.dumps(proof, indent=2)+'\n')
    result = dict(verified, reuseVerificationSha256=sha(boundaries/'contact-reuse-verification.json'))
    (boundaries/'boundary-audit.json').write_text(json.dumps(result, separators=(',', ':'))+'\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'cases'}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--previous-boundaries', type=Path, required=True)
    parser.add_argument('--boundaries', type=Path, required=True)
    parser.add_argument('--previous-candidate', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    reuse(args.previous_boundaries, args.boundaries, args.previous_candidate, args.candidate)
