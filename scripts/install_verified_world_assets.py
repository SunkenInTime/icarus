"""Copy the all-map assets covered by source, outlier-review and runtime audits.

Installation writes a fresh directory and verifies every copied byte. It does
not enable the Dart rollout or modify an existing asset directory.
"""
import argparse
import json
from pathlib import Path
import shutil

from verify_world_runtime import check_asset, read_map_names, sha256


def rows_by_map(document, expected):
    rows = document.get('maps', [])
    by_map = {row['map']: row for row in rows}
    if set(by_map) != expected or len(rows) != len(expected):
        raise ValueError('Audit map coverage differs from the application.')
    return by_map


def checked_runtime_assets(rows):
    assets = {}
    for row in rows:
        path = Path(row['path']).resolve()
        if path in assets:
            raise ValueError('Duplicate resolved runtime asset path.')
        if sha256(path) != row['sha256']:
            raise ValueError(f'Runtime input changed after verification: {path}')
        assets[path] = row['sha256']
    return assets


def checked_review(name, source_row, review_row, manifest_sha, reference_sha):
    comparison_path = Path(source_row['referenceReport'])
    if review_row.get('comparisonSha256') != sha256(comparison_path):
        raise ValueError(f'{name}: outlier review covers a different source comparison.')
    comparison = json.loads(comparison_path.read_bytes())
    if (comparison.get('map') != name or comparison.get('assetSha256') != manifest_sha or
            comparison.get('referenceSha256') != reference_sha or
            comparison.get('summary') != source_row.get('summary') or
            comparison.get('planeSummary') != source_row.get('planeSummary')):
        raise ValueError(f'{name}: source comparison differs from the source audit.')
    if any(review_row.get(key) is not True for key in (
            'comparisonPresent', 'allSamePlaneOutliersExplained',
            'comparisonUsesFinalReference', 'finalReferenceRayRecordsEqual')):
        raise ValueError(f'{name}: source outlier review is incomplete.')
    summary = comparison['planeSummary']
    if (summary.get('differentSelectedPlanes') != 0 or summary.get('rays', 0) <= 0 or
            summary['rays'] != comparison['summary'].get('rays')):
        raise ValueError(f'{name}: source comparison does not cover every selected-plane ray.')
    failures = comparison['planeFailures']
    retained = review_row.get('retainedOutliers', [])
    by_ray = {row['ray']: row for row in failures}
    reviewed = {row['ray']: row for row in retained}
    if (len(by_ray) != len(failures) or len(reviewed) != len(retained) or
            set(by_ray) != set(reviewed)):
        raise ValueError(f'{name}: review must retain every source outlier exactly once.')
    for ray, failure in by_ray.items():
        item = dict(reviewed[ray])
        explanation = item.pop('explanation', None)
        if not isinstance(explanation, str) or not explanation.strip() or item != failure:
            raise ValueError(f'{name}: reviewed source outlier changed or lacks an explanation.')
    over_10cm = sum(row['errorMeters'] > .1 for row in failures)
    if (review_row.get('samePlaneRays') != summary['rays'] or
            review_row.get('samePlaneOutliersOver2cm') != len(failures) or
            review_row.get('samePlaneOutliersOver10cm') != over_10cm or
            review_row.get('maximumSamePlaneErrorMeters') != summary['maxErrorMeters']):
        raise ValueError(f'{name}: reviewed source statistics differ from the comparison.')
    proof = review_row.get('reviewEvidence')
    if not proof or sha256(Path(proof['path'])) != proof['sha256']:
        raise ValueError(f'{name}: source outlier review evidence is missing or changed.')
    return summary['rays'], len(failures), over_10cm


def verified_files(candidate, source_report, runtime_report, outlier_inventory, required_maps):
    candidate = Path(candidate).resolve()
    source = json.loads(Path(source_report).read_bytes())
    runtime = json.loads(Path(runtime_report).read_bytes())
    inventory = json.loads(Path(outlier_inventory).read_bytes())
    expected = set(required_maps)
    if (source.get('scope') != 'all_maps' or source.get('allMapCoverageComplete') is not True or
            runtime.get('scope') != 'all_maps' or runtime.get('runtimeStatus') != 'passed' or
            runtime.get('completeAllMapCoverage') is not True):
        raise ValueError('Complete passing source and runtime audits are required before installation.')
    if (not expected or len(expected) != len(required_maps) or
            inventory.get('status') != 'all-map-same-plane-review-inventory' or
            inventory.get('acceptedOrWaivedRays') != 0 or
            any(inventory.get(key) is not True for key in (
                'allRequiredMapsCompared', 'allComparisonsUseFinalReferences', 'allRequiredMapsReviewed')) or
            any(inventory.get(key) != len(expected) for key in ('requiredMaps', 'comparedMaps', 'reviewedMaps'))):
        raise ValueError('A complete all-map source outlier review inventory is required.')
    source_rows = rows_by_map(source, expected)
    runtime_rows = rows_by_map(runtime, expected)
    review_rows = rows_by_map(inventory, expected)
    if Path(runtime['worldDirectory']).resolve() != candidate:
        raise ValueError('Runtime audit used a different candidate directory.')
    result = {}
    totals = [0, 0, 0]
    for name in required_maps:
        source_row, runtime_row = source_rows[name], runtime_rows[name]
        if source_row.get('status') != 'candidate-packed-and-compared' or runtime_row.get('runtimeStatus') != 'passed':
            raise ValueError(f'{name}: an audit failed.')
        manifest_path = candidate / f'{name}_visibility.manifest.json'
        fingerprint = sha256(manifest_path)
        if source_row['source']['packedManifestSha256'] != fingerprint:
            raise ValueError(f'{name}: packed manifest changed after its source comparison.')
        runtime_input = runtime_row['input']
        runtime_assets = checked_runtime_assets(runtime_input['assets'])
        if runtime_assets.get(manifest_path.resolve()) != fingerprint:
            raise ValueError(f'{name}: runtime verified a different manifest.')
        reference_path = (Path(runtime['referenceDirectory']) / f'{name}.json').resolve()
        reference_sha = sha256(reference_path)
        reference = json.loads(reference_path.read_bytes())
        policy_sha = sha256(reference_path.with_suffix('.policies.json'))
        if (runtime_input.get('map') != name or reference.get('map') != name or
                source_row['source'].get('referenceSha256') != reference_sha or
                runtime_assets.get(reference_path) != reference_sha or
                runtime_input.get('referenceFingerprints') != reference.get('source') or
                reference.get('source', {}).get('materialPoliciesSha256') != policy_sha or
                source_row['source'].get('referencePoliciesSha256') != policy_sha):
            raise ValueError(f'{name}: runtime reference or material policies differ from the source audit.')
        counts = checked_review(name, source_row, review_rows[name], fingerprint, reference_sha)
        totals = [total + count for total, count in zip(totals, counts)]
        manifest = json.loads(manifest_path.read_bytes())
        if manifest['map'] != name:
            raise ValueError('Manifest map identity differs.')
        result[manifest_path] = fingerprint
        for descriptor in [*manifest['chunks'], manifest['navigationAsset']]:
            suffix = '.bin.gz' if descriptor in manifest['chunks'] else '.json.gz'
            row = check_asset(candidate, descriptor, suffix)
            # Keep the manifest's filename for copying, but compare file identity
            # with the fully resolved runtime path.
            path = Path(row['path'])
            if path in result or runtime_assets.get(path.resolve()) != row['sha256']:
                raise ValueError('Duplicate asset or runtime/source asset mismatch.')
            result[path] = row['sha256']
    if totals != [inventory.get(key) for key in (
            'samePlaneRays', 'retainedOutliersOver2cm', 'retainedOutliersOver10cm')]:
        raise ValueError('All-map reviewed source totals differ from the comparisons.')
    for row in runtime.get('runtimeFiles', []):
        if sha256(Path(row['path'])) != row['sha256']:
            raise ValueError('Runtime code changed after the all-map audit.')
    if not runtime.get('runtimeFiles'):
        raise ValueError('Runtime audit must identify the verified implementation.')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('source_report', type=Path)
    parser.add_argument('runtime_report', type=Path)
    parser.add_argument('outlier_inventory', type=Path,
                        help='All-map reviewed inventory bound to the exact source comparisons.')
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    files = verified_files(args.candidate.resolve(), args.source_report, args.runtime_report,
                           args.outlier_inventory, read_map_names(repo))
    output = args.output.resolve()
    pending = output.with_name(output.name + '.pending')
    if output.exists() or pending.exists():
        raise ValueError('Use a fresh destination; previous assets are never overwritten.')
    pending.mkdir(parents=True)
    for path, fingerprint in files.items():
        target = pending / path.name
        shutil.copyfile(path, target)
        if sha256(target) != fingerprint:
            raise ValueError(f'Installed asset failed its hash: {path.name}')
    pending.rename(output)
    print(json.dumps({'maps': len(read_map_names(repo)), 'files': len(files),
                      'bytes': sum(path.stat().st_size for path in files), 'output': str(output)}))


if __name__ == '__main__':
    main()
