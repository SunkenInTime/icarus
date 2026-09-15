"""Check automatic-floor consequences inside every reviewed roof projection.

This is a local change check, not a new whole-map gameplay certificate. Exact
physical source-domain and support retention is verified. Only reviewed default
flags and source automatic/manual disposition may change. Compare all remaining
automatic source domains in the affected area; explicit upper choices survive.
"""
import argparse
import copy
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from compile_reviewed_svg_height_map import polygon
from verify_wall_change_floor_delta import read, sha, require, crop_model
from verify_icebox_regional_floors import compare, BOUNDARY_TOLERANCE_SVG, ROOT


def assert_source_transition(before, after, decisions, review_sha):
    automatic = {d['id']: d for d in before['domains']}
    manual = {d['id']: d for d in before.get('manualDomains', [])}
    require(len(automatic) == len(before['domains']), 'Duplicate automatic source domain')
    require(len(manual) == len(before.get('manualDomains', [])), 'Duplicate manual source domain')
    require(not automatic.keys() & manual.keys(), 'Conflicting source dispositions')
    selected = {r['domain']['id']: r['domain'] for r in decisions}
    require(len(selected) == len(decisions), 'Duplicate reviewed source domain')
    require(all(automatic.get(key) == domain for key, domain in selected.items()),
            'Reviewed evidence differs from original physical source')
    # Reconstruct independently rather than calling the candidate compiler.
    expected = copy.deepcopy(before)
    expected['domains'] = [d for d in before['domains'] if d['id'] not in selected]
    expected['manualDomains'] = [*before.get('manualDomains', []),
        *[d for d in before['domains'] if d['id'] in selected]]
    expected['coveredInteriorReviewSha256'] = review_sha
    require(after == expected, 'Changes extend beyond reviewed source disposition')
    require({d['id']: d for d in after['domains'] + after['manualDomains']} == {
        **automatic, **manual}, 'Physical source evidence was removed or changed')
    return set(selected)


def assert_model_transition(before, after, name, domain_ids, support_ids):
    require(before.get('version') == after.get('version') == 3, 'Requires version 3 assets')
    ids = [s['id'] for s in before['supports']]
    require(len(set(ids)) == len(ids), 'Duplicate support identity')
    require([s['id'] for s in after['supports']] == ids, 'Support removed, added, or reordered')
    prefix = f'{name}-measured-'
    measured = {sid for sid in ids if sid.startswith(prefix) and sid[len(prefix):] in domain_ids}
    require(measured <= support_ids, 'Review omitted a measured manual-domain alias')
    expected = copy.deepcopy(before)
    for support in expected['supports']:
        if support['id'] in support_ids:
            support['automaticStandingAllowed'] = False
    require(after == expected, 'Changes extend beyond reviewed automatic-standing flags')
    require(not set(before.get('sightlineFloorSupportIds', [])) & support_ids,
            'Manual support is still an automatic sightline destination')
    return [s for s in before['supports'] if s['id'] in support_ids]


def rejects(action, label):
    try:
        action()
    except ValueError:
        return dict(control=label, status='rejected')
    raise ValueError(f'Fault control accepted: {label}')


def verify(review_path, candidate_root):
    review = read(review_path)
    application = read(candidate_root / 'application.json')
    require(application['reviewSha256'] == sha(review_path), 'Review changed')
    require(application['algorithmSha256'] == sha(Path('scripts/apply_covered_interior_review.py')),
            'Candidate compiler changed')
    applied_maps = {r['map']: r for r in application['maps']}
    require(len(applied_maps) == len(application['maps']) and set(applied_maps) == set(review['maps']),
            'Application map coverage differs')
    results, map_controls = [], []
    for name, spec in review['maps'].items():
        folder = candidate_root / name
        source_path = folder / 'source/regional-floors.json'
        source, old_source = read(source_path), read(Path(spec['standingSource']))
        require(sha(Path(spec['standingSource'])) == spec['standingSourceSha256'],
                'Original standing source changed')
        require(sha(folder / 'before-regional-floors.json') == spec['standingSourceSha256'],
                'Frozen original source changed')
        for path, digest in spec['sourceSha256'].items():
            require(sha(Path(path)) == digest, f'Physical source changed: {path}')
        decisions = spec['defaultExcludedStandingDomains']
        manual_domains = assert_source_transition(old_source, source, decisions, sha(review_path))
        support_ids = {sid for r in decisions for sid in r['supportIds']}
        applied = applied_maps[name]
        require(applied['sourceSha256'] == sha(source_path), 'Candidate source fingerprint changed')
        require(applied['originalStandingSourceSha256'] == spec['standingSourceSha256'],
                'Application original source changed')
        require(applied['manualDomainIds'] == sorted(manual_domains), 'Application domain coverage differs')
        applied_sides = {r['side']: r for r in applied['sides']}
        require(len(applied_sides) == len(applied['sides']) and set(applied_sides) == {'attack', 'defense'},
                'Application side coverage differs')
        controls = []
        if manual_domains:
            dropped = copy.deepcopy(source)
            dropped['manualDomains'] = [d for d in dropped['manualDomains']
                                        if d['id'] != sorted(manual_domains)[0]]
            controls.append(rejects(lambda: assert_source_transition(old_source, dropped, decisions, sha(review_path)),
                                    'remove-retained-manual-domain'))
        wrong_stamp = copy.deepcopy(source)
        wrong_stamp['coveredInteriorReviewSha256'] = 'deliberately-wrong'
        controls.append(rejects(lambda: assert_source_transition(old_source, wrong_stamp, decisions, sha(review_path)),
                                'change-source-review-fingerprint'))
        alignment_path = ROOT / f'tactical-alignment-sides-v1/{name}.json'
        require(spec['sourceSha256'].get(alignment_path.as_posix()) == sha(alignment_path),
                'Alignment source changed')
        alignment = read(alignment_path)
        found_aliases, old_failures_total = set(), 0
        for side in ['attack', 'defense']:
            before_path, after_path = folder / f'before-{side}.json.gz', folder / f'candidate-{side}.json.gz'
            require(sha(before_path) == spec['baselineSha256'][side], 'Baseline changed')
            require(applied_sides[side]['beforeSha256'] == sha(before_path), 'Application baseline changed')
            require(applied_sides[side]['candidateSha256'] == sha(after_path), 'Candidate fingerprint changed')
            before, after = read(before_path), read(after_path)
            affected = assert_model_transition(before, after, name, manual_domains, support_ids)
            present = {s['id'] for s in affected}
            found_aliases.update(present)
            require(applied_sides[side]['defaultExcludedSupportIds'] == sorted(present),
                    'Application alias coverage differs')
            changed = sorted(s['id'] for s in affected if s.get('automaticStandingAllowed') is not False)
            require(applied_sides[side]['changedSupportIds'] == changed, 'Changed-alias accounting differs')
            if present:
                bad_flag = copy.deepcopy(after)
                next(s for s in bad_flag['supports'] if s['id'] in present)['automaticStandingAllowed'] = True
                controls.append(rejects(lambda: assert_model_transition(before, bad_flag, name, manual_domains, support_ids),
                                        f'{side}-restore-automatic-roof-flag'))
                deleted = copy.deepcopy(after)
                deleted['supports'] = [s for s in deleted['supports'] if s['id'] != sorted(present)[0]]
                controls.append(rejects(lambda: assert_model_transition(before, deleted, name, manual_domains, support_ids),
                                        f'{side}-delete-preserved-upper-choice'))
            bad_ground = copy.deepcopy(after)
            bad_ground['ground'] = {'deliberately': 'changed'}
            controls.append(rejects(lambda: assert_model_transition(before, bad_ground, name, manual_domains, support_ids),
                                    f'{side}-change-unrelated-ground'))
            matrix = np.asarray(alignment[f'nativeTo{side.title()}Svg'])
            transform = [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]]
            source_projections = [affine_transform(
                shapely.from_geojson(json.dumps(r['domain']['nativeGeometry'])), transform)
                for r in decisions]
            # A reviewed domain may be source-only or have parts represented by
            # ground instead of a support. Include its full source projection,
            # not just current aliases, so those changes cannot escape the check.
            region = shapely.union_all([*source_projections,
                *[polygon(s) for s in affected]]).buffer(2 * BOUNDARY_TOLERANCE_SVG)
            if region.is_empty:
                active, before_failures = [], []
            else:
                local, _ = crop_model(after, region)
                old_local, _ = crop_model(before, region)
                rows = compare(source, local, matrix, side)
                # Restoring old automatic roof flags must fail the independently
                # reviewed lower-source expectation. This is a behavioral control.
                old_rows = compare(source, old_local, matrix, side)
                active = [r for r in rows if r['withinReceiverAreaSvg'] > 1e-12]
                before_failures = [r for r in old_rows if r['withinReceiverAreaSvg'] > 1e-12
                                   and r['defaultStatus'] != 'passed']
            failures = [r for r in active if r['status'] != 'passed' or r['defaultStatus'] != 'passed']
            require(not failures, f'{name} {side} loses an automatic floor or selects the wrong level: '
                    + json.dumps([{k: r[k] for k in ['id', 'status', 'defaultStatus', 'samples', 'defaultSamples']}
                                  for r in failures]))
            old_failures_total += len(before_failures)
            results.append(dict(map=name, side=side, status='passed',
                assetSha256=sha(after_path), sourceSha256=sha(source_path),
                reviewedManualSourceDomains=sorted(manual_domains), defaultExcludedSupportIds=sorted(present),
                preservedSupportCount=len(after['supports']),
                otherFieldsUnchanged=True, localDomainChecks=len(active),
                failedLocalDomainChecks=len(failures), oldRoofWrongDefaultChecks=len(before_failures),
                applicability='reviewed-source-and-support-projections' if not region.is_empty else 'empty-reviewed-projection',
                rows=active, beforeWrongDefaultRows=before_failures))
            print(json.dumps({k: v for k, v in results[-1].items()
                              if k not in {'rows', 'beforeWrongDefaultRows',
                                           'reviewedManualSourceDomains', 'defaultExcludedSupportIds'}}), flush=True)
        require(found_aliases == support_ids, f'{name} reviewed aliases absent from both sides')
        require(old_failures_total > 0, f'{name} old-roof behavioral fault control did not fail')
        map_controls.append(dict(map=name, physicalSourceEvidencePreserved=True,
            oldRoofWrongDefaultChecks=old_failures_total, structuralFaultControls=controls))
    report = dict(status='passed', scope=__doc__.strip(), reviewSha256=sha(review_path),
                  algorithmSha256=sha(Path(__file__)), results=results, mapControls=map_controls,
                  applicationSha256=sha(candidate_root / 'application.json'),
                  dependencySha256={str(p): sha(p) for p in [Path('scripts/verify_icebox_regional_floors.py'),
                    Path('scripts/verify_wall_change_floor_delta.py'), Path('scripts/compile_reviewed_svg_height_map.py')]})
    (candidate_root / 'local-floor-comparison.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--review', type=Path, required=True)
    parser.add_argument('--candidate-root', type=Path, required=True)
    args = parser.parse_args()
    verify(args.review, args.candidate_root)
