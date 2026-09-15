"""Verify local floor effects while retaining a pinned full baseline proof.

Only wall and support edits are accepted. Ground, receiver, camera and other
runtime settings must be unchanged. Every changed footprint is rechecked with
the ordinary source-floor comparator; the baseline covers its unchanged exterior.
This certifies source-floor coverage and default selection only. The wall review
and gameplay sightline checks establish whether the edited wall height is right.
"""
import argparse
import ast
import copy
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from compile_reviewed_svg_height_map import polygon, rings
from polygonal_area import polygonal
from verify_icebox_regional_floors import (
    compare, ROOT, BOUNDARY_TOLERANCE_SVG, OVERLAY_PRECISION_SVG)


def read(path):
    raw = path.read_bytes()
    return json.loads(gzip.decompress(raw) if path.suffix == '.gz' else raw)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unchanged_plane_region(before_text, after_text):
    """The comparator imports only this self-contained numerical function."""
    def relevant(text):
        tree = ast.parse(text)
        selected = []
        module_statements = []
        for node in tree.body:
            if isinstance(node, ast.FunctionDef) and node.name == 'plane_region':
                selected.append(ast.dump(node, include_attributes=False))
            if isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name in {'numpy', 'shapely'}:
                        selected.append(ast.dump(alias, include_attributes=False))
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef,
                                     ast.Import, ast.ImportFrom)):
                if not (isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant)
                        and isinstance(node.value.value, str)):
                    module_statements.append(ast.dump(node, include_attributes=False))
        require(len(selected) == 3, 'Expected plane_region and its numpy/shapely imports.')
        return selected, module_statements
    return relevant(before_text) == relevant(after_text)


CANDIDATE_REVIEW_STAMPS = {
    'sourceReportedWallReviewSha256',
    'sourceConfirmedWallReviewSha256',
    'sourceLotusLowCrateReviewSha256',
    'sourceFractureSmallCrateReviewSha256',
    'sourceAbyssTowerOpeningReviewSha256',
    'sourceLotusStepwellOpeningReviewSha256',
    'sourceFractureContainerOpeningReviewSha256',
    'sourcePearlLowBrickReviewSha256',
    'sourcePearlMetroOpeningReviewSha256',
    'sourcePearlLowBrickTailReviewSha256',
    'sourcePearlRampBrickProfileReviewSha256',
    'sourceFracturePlatformEndReviewSha256',
    'sourcePearlMidStepOpeningReviewSha256',
    'sourceRemainingOwnershipReviewSha256',
    'sourceLotusSmallCrateOutlineReviewSha256',
    'sourceLotusSteppedCrateReviewSha256',
    'sourceLotusLowerCourtyardProjectionReviewSha256',
}


def changes(before, after):
    allowed = {'walls', 'supports', *CANDIDATE_REVIEW_STAMPS}
    require({k: v for k, v in before.items() if k not in allowed} == {
        k: v for k, v in after.items() if k not in allowed
    }, 'A nonlocal runtime field changed; run a full source comparison.')
    require(before['version'] == after['version'] == 3, 'The delta verifier requires version 3 data.')
    changed = []
    for field in ['walls', 'supports']:
        old = {r['id']: r for r in before[field]}
        new = {r['id']: r for r in after[field]}
        require(len(old) == len(before[field]) and len(new) == len(after[field]),
                f'{field} ids must be unique.')
        for key in old.keys() | new.keys():
            a, b = old.get(key), new.get(key)
            if a == b:
                continue
            if field == 'supports' and a is not None and b is not None and {
                k: v for k, v in a.items() if k != 'rings'
            } == {k: v for k, v in b.items() if k != 'rings'}:
                changed.append(polygon(a).symmetric_difference(polygon(b)))
            else:
                changed.extend(polygon(row) for row in [a, b] if row is not None)
    # This is a verification margin, never a modification of map geometry.
    return polygonal(shapely.union_all(changed)).buffer(2 * BOUNDARY_TOLERANCE_SVG)


def crop_records(records, region):
    result = []
    for row in records:
        shape = polygonal(polygon(row).intersection(region))
        if shape.is_empty:
            continue
        result.append(dict(row, fillRule='evenodd', rings=[ring
            for part in shapely.get_parts(shape) for ring in rings(part)]))
    return result


def crop_model(model, region):
    local = copy.deepcopy(model)
    for field in ['walls', 'supports', 'receiver']:
        local[field] = crop_records(model[field], region)
    ground = model['ground']
    vertices = np.asarray(ground['vertices']).reshape(-1, 3)
    faces = np.asarray(ground['triangles'], dtype=int).reshape(-1, 3)
    triangles = shapely.polygons(vertices[faces, :2])
    # Preserve original first-covering order and every earlier local triangle.
    ids = np.flatnonzero(shapely.intersects(triangles, region))
    local['ground']['triangles'] = faces[ids].reshape(-1).tolist()
    physical = set(ground['standingTriangles'])
    local['ground']['standingTriangles'] = [i for i, old in enumerate(ids) if int(old) in physical]
    return local, len(ids)


def verify_baseline(report, source, source_path, review, review_path, report_path=None):
    """Reject a declared pass unless its complete pinned proof still resolves."""
    map_name = review['map']
    require(report.get('map') == map_name, 'Baseline and review map identities disagree.')
    require(source.get('map') in (None, map_name), 'The standing source names a different map.')
    require(report.get('status') == 'passed', 'The full baseline did not pass.')
    require(report.get('failedDomainChecks') == 0, 'The full baseline has missing levels.')
    require(report.get('failedDefaultDomainChecks') == 0, 'The full baseline has wrong defaults.')
    require(sha(source_path) == report.get('sourceSha256'), 'The standing source changed.')
    if review.get('standingSource'):
        require(sha(source_path) == review['standingSource']['sha256'],
                'The review names a different standing source.')
    require(report.get('heightToleranceMeters') == .02, 'The baseline height tolerance changed.')
    require(report.get('boundaryToleranceSvg') == BOUNDARY_TOLERANCE_SVG,
            'The baseline boundary tolerance changed.')
    require(report.get('overlayPrecisionSvg') == OVERLAY_PRECISION_SVG,
            'The baseline overlay precision changed.')

    expected = {(row['id'], side) for row in source['domains']
                for side in ['attack', 'defense']}
    rows = report.get('rows', [])
    actual = [(row.get('id'), row.get('side')) for row in rows]
    require(len(actual) == len(set(actual)), 'The full baseline repeats domain rows.')
    require(set(actual) == expected, 'The full baseline does not cover every source domain and side.')
    require(report.get('domainChecks') == len(rows) == len(expected),
            'The full baseline domain count is inconsistent.')
    require(all(row.get('status') == 'passed' and row.get('defaultStatus') == 'passed'
                for row in rows), 'A full baseline row did not pass.')

    inputs = report.get('inputsSha256')
    require(isinstance(inputs, dict) and inputs, 'The full baseline has no pinned input manifest.')
    fingerprint = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    require(fingerprint == report.get('checkpointFingerprint'),
            'The full baseline input fingerprint is inconsistent.')
    for raw_path, expected_sha in inputs.items():
        path = Path(raw_path)
        require(path.exists(), f'Pinned baseline input is missing: {path}')
        if sha(path) != expected_sha and path.name in {'verify_regional_floor_sides.py', 'build_all_map_gameplay_supports.py'} and report_path is not None:
            # The historical orchestrator is archived when it launches the
            # comparison. Its later CLI changes do not replace that evidence.
            # Numerical dependencies, source, alignment and assets still must
            # match their original hashes in place.
            archived = report_path.parent / 'domain-side-checkpoints' / fingerprint / 'algorithms' / path.name
            require(archived.exists() and sha(archived) == expected_sha,
                    'The historical full-comparison orchestrator is missing or changed.')
            if path.name == 'build_all_map_gameplay_supports.py':
                require(unchanged_plane_region(archived.read_text(), path.read_text()),
                        'The comparator plane_region implementation changed; run a full comparison.')
        else:
            require(sha(path) == expected_sha, f'Pinned baseline input changed: {path}')
    comparator = Path(__file__).with_name('verify_icebox_regional_floors.py')
    orchestrator = Path(__file__).with_name('verify_regional_floor_sides.py')
    require(sha(comparator) == report.get('algorithmSha256'), 'Full comparator changed.')
    require(inputs.get(str(orchestrator)) == report.get('orchestratorSha256'),
            'The full orchestrator hash disagrees with its pinned input.')
    require(sha(review_path) == review.get('reviewSha256', sha(review_path)),
            'The wall review fingerprint is inconsistent.')


def active_rows(before_rows, after_rows):
    before = {row['id']: row for row in before_rows}
    after = {row['id']: row for row in after_rows}
    require(before.keys() == after.keys(), 'Local source rows disagree.')
    rows = []
    for key in before:
        old, new = before[key], after[key]
        require(abs(old['sourceAreaSvg'] - new['sourceAreaSvg']) <= 1e-9,
                f'Source projection changed during the local comparison: {key}')
        require(abs(old['withinReceiverAreaSvg'] - new['withinReceiverAreaSvg']) <= 1e-9,
                f'Receiver restriction changed during the local comparison: {key}')
        if max(old['withinReceiverAreaSvg'], new['withinReceiverAreaSvg']) <= 1e-12:
            continue
        rows.append(dict(new,
            baselineApplicableAreaSvg=old['applicableAreaSvg'],
            applicableAreaDeltaSvg=new['applicableAreaSvg'] - old['applicableAreaSvg'],
            baselineExcludedByActiveSvgWallAreaSvg=old['excludedByActiveSvgWallAreaSvg'],
            excludedByActiveSvgWallAreaDeltaSvg=(new['excludedByActiveSvgWallAreaSvg'] -
                                                  old['excludedByActiveSvgWallAreaSvg']),
            baselineDefaultAreaSvg=old['defaultAreaSvg'],
            defaultAreaDeltaSvg=new['defaultAreaSvg'] - old['defaultAreaSvg']))
    return rows


def verify_candidate_review(model, review_sha, side,
                            stamp='sourceReportedWallReviewSha256'):
    require(stamp in CANDIDATE_REVIEW_STAMPS, 'Unknown review metadata field.')
    require(model.get(stamp) == review_sha,
            f'The {side} candidate does not name this wall review.')


def expect_rejection(label, action):
    try:
        action()
    except (ValueError, KeyError, AssertionError) as error:
        return dict(control=label, status='passed', rejection=str(error))
    raise ValueError(f'Negative control was accepted: {label}')


def verify(review_path, baseline_report_path, source_path, candidate_dir, output,
           fault_controls=False):
    review, baseline_report, source = read(review_path), read(baseline_report_path), read(source_path)
    require(len({row['id'] for row in source['domains']}) == len(source['domains']),
            'The standing source repeats a domain id.')
    verify_baseline(baseline_report, source, source_path, review, review_path, baseline_report_path)
    comparator = Path(__file__).with_name('verify_icebox_regional_floors.py')
    alignment_path = ROOT / f'tactical-alignment-sides-v1/{review["map"]}.json'
    require(sha(alignment_path) == review['sources']['alignment']['sha256'],
            'The reviewed alignment changed.')
    require(any(Path(path) == alignment_path and digest == sha(alignment_path)
                for path, digest in baseline_report['inputsSha256'].items()),
            'The full baseline did not pin the reviewed alignment.')
    alignment = read(alignment_path)
    rows, sides, baseline_failures, candidate_failures, controls = [], [], [], [], []
    review_sha = sha(review_path)
    binding = review.get('candidateReview')
    stamp, stamp_sha = 'sourceReportedWallReviewSha256', review_sha
    if binding is not None:
        stamp, stamp_sha = binding['stamp'], binding['sha256']
        require(stamp in CANDIDATE_REVIEW_STAMPS, 'Unknown candidate review stamp.')
        require(sha(Path(binding['path'])) == stamp_sha,
                'The candidate wall review changed.')
    if fault_controls:
        omitted = copy.deepcopy(baseline_report)
        omitted['rows'] = omitted['rows'][1:]
        controls.append(expect_rejection('baseline-row-omission',
            lambda: verify_baseline(omitted, source, source_path, review, review_path, baseline_report_path)))
    for side in ['attack', 'defense']:
        before_path = Path(review['baseline'][side]['path'])
        after_path = candidate_dir / f'candidate-{side}.json.gz'
        require(sha(before_path) == review['baseline'][side]['sha256'] ==
                baseline_report['assetSha256'][side], f'The {side} baseline changed.')
        before, after = read(before_path), read(after_path)
        verify_candidate_review(after, stamp_sha, side, stamp)
        if fault_controls and side == 'attack':
            changed_ground = copy.deepcopy(after)
            changed_ground['ground']['vertices'][0] += .01
            controls.append(expect_rejection('changed-ground-gate',
                lambda: changes(before, changed_ground)))
            wrong_review = copy.deepcopy(after)
            wrong_review[stamp] = '0' * 64
            controls.append(expect_rejection('candidate-review-hash-mismatch',
                lambda: verify_candidate_review(wrong_review, stamp_sha, side, stamp)))
        region = changes(before, after)
        matrix = np.asarray(alignment[f'nativeTo{side.title()}Svg'])
        baseline_model, baseline_ground_count = crop_model(before, region)
        candidate_model, candidate_ground_count = crop_model(after, region)
        # Keep every complete native source domain. The restricted receiver makes
        # this a local comparison without inverse-projection or partition rounding.
        before_rows = compare(source, baseline_model, matrix, side) if not region.is_empty else []
        after_rows = compare(source, candidate_model, matrix, side) if not region.is_empty else []
        side_baseline_failures = [row for row in before_rows
                                  if row['status'] != 'passed' or row['defaultStatus'] != 'passed']
        side_candidate_failures = [row for row in after_rows
                                   if row['status'] != 'passed' or row['defaultStatus'] != 'passed']
        baseline_failures.extend(side_baseline_failures)
        candidate_failures.extend(side_candidate_failures)
        local_rows = active_rows(before_rows, after_rows) if before_rows else []
        rows.extend(local_rows)
        if fault_controls and side == 'attack' and not region.is_empty:
            missing_supports = copy.deepcopy(candidate_model)
            removed = sum(bool(row.get('automaticStandingAllowed'))
                          for row in missing_supports['supports'])
            missing_supports['supports'] = [row for row in missing_supports['supports']
                                            if not row.get('automaticStandingAllowed')]
            require(removed > 0, 'Missing-support control found no local automatic support.')
            fault_rows = compare(source, missing_supports, matrix, side)
            detected = [row for row in fault_rows
                        if row['status'] != 'passed' or row['defaultStatus'] != 'passed']
            require(detected, 'Missing required supports did not fail the local comparison.')
            controls.append(dict(control='removed-required-supports', status='passed',
                                 removedAutomaticSupports=removed,
                                 detectedFailedDomains=len(detected),
                                 sampleDomainIds=[row['id'] for row in detected[:5]]))
        applicability = [row for row in local_rows
                         if abs(row['applicableAreaDeltaSvg']) > 1e-9 or
                         abs(row['excludedByActiveSvgWallAreaDeltaSvg']) > 1e-9]
        sides.append(dict(side=side, beforeSha256=sha(before_path), afterSha256=sha(after_path),
                          checkedRegionSvg=json.loads(shapely.to_geojson(region)),
                          checkedAreaSvg=region.area,
                          baselineRestrictionGroundTriangles=baseline_ground_count,
                          candidateGroundTriangles=candidate_ground_count,
                          completeSourceDomains=len(source['domains']),
                          localSourceDomains=len(local_rows),
                          baselineRestrictionFailures=len(side_baseline_failures),
                          candidateFailures=len(side_candidate_failures),
                          applicabilityChangedDomains=len(applicability)))
    failures = [*baseline_failures, *candidate_failures]
    report = dict(status='passed' if not failures else 'floor-differences', map=review['map'],
                  scope=__doc__.strip(), algorithmSha256=sha(Path(__file__)),
                  comparatorSha256=sha(comparator), sourceSha256=sha(source_path),
                  reviewSha256=review_sha,
                  candidateReview=binding,
                  baselineReport=baseline_report_path.as_posix(), baselineReportSha256=sha(baseline_report_path),
                  baselineDomainChecks=baseline_report['domainChecks'], localDomainChecks=len(rows),
                  baselineRestrictionFailedDomainChecks=len(baseline_failures),
                  failedLocalDomainChecks=len(candidate_failures),
                  applicabilityChangedDomainChecks=sum(side['applicabilityChangedDomains'] for side in sides),
                  faultControls=controls, sides=sides, rows=rows)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: v for k, v in report.items() if k not in ['rows', 'sides']}), flush=True)
    if failures:
        print(json.dumps(failures), flush=True)
        raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['review', 'baseline-report', 'source', 'candidate-dir', 'output']:
        parser.add_argument('--'+key, type=Path, required=True)
    parser.add_argument('--fault-controls', action='store_true')
    args = parser.parse_args()
    verify(args.review, args.baseline_report, args.source, args.candidate_dir, args.output,
           args.fault_controls)
