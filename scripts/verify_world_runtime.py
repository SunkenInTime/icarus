"""Run the Flutter factory and polygon audit sequentially for every map.

The aggregate separates runtime failures from source differences requiring
review. No source outlier is waived automatically, including top-edge grazes.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False), encoding='utf-8')
    temporary.replace(path)


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read_map_names(repo):
    source = (repo / 'lib/const/maps.dart').read_text(encoding='utf-8')
    match = re.search(r'\benum\s+MapValue\s*\{([^}]+)\}', source)
    if not match:
        raise ValueError('Cannot locate the complete MapValue enum.')
    values = [value.strip() for value in match[1].split(',') if value.strip()]
    if not values or len(set(values)) != len(values) or any(
            not re.fullmatch(r'[a-z][a-z0-9_]*', value) for value in values):
        raise ValueError('Unsupported MapValue syntax; refusing partial map discovery.')
    return values


def check_asset(folder, descriptor, suffix):
    name = descriptor.get('asset')
    if not isinstance(name, str) or not re.fullmatch(r'[a-z0-9_-]+' + re.escape(suffix), name):
        raise ValueError('Invalid asset name in manifest.')
    path = folder / name
    expected = descriptor.get('sha256')
    if not isinstance(expected, str) or not re.fullmatch(r'[a-f0-9]{64}', expected):
        raise ValueError(f'Missing SHA-256 for {name}.')
    if path.stat().st_size != descriptor.get('compressedBytes') or sha256(path) != expected:
        raise ValueError(f'Asset checksum or byte count mismatch: {name}.')
    return {'path': str(path), 'sha256': expected}


def preflight(map_name, world, references):
    manifest_path = world / f'{map_name}_visibility.manifest.json'
    reference_path = references / f'{map_name}.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    reference = json.loads(reference_path.read_text(encoding='utf-8'))
    if manifest.get('map') != map_name or manifest.get('format') != 'chunked-v1':
        raise ValueError('Manifest map or format mismatch.')
    if reference.get('map') != map_name:
        raise ValueError('Reference map mismatch.')
    for key in ('geometrySha256', 'navigationSha256'):
        expected = reference.get('source', {}).get(key)
        if not expected or manifest.get('source', {}).get(key) != expected:
            raise ValueError(f'Manifest/reference source mismatch: {key}.')
    origins = reference.get('origins', [])
    rays = reference.get('rays', [])
    directions = reference.get('sampling', {}).get('directions')
    if not origins or not isinstance(directions, int) or directions <= 0 or len(rays) != len(origins) * directions:
        raise ValueError('Incomplete reference origins or rays.')
    if len({entry['id'] for entry in origins}) != len(origins):
        raise ValueError('Duplicate reference origins.')
    if any('planeReference' not in ray or 'planeElevationCm' not in ray for ray in rays):
        raise ValueError('Every reference ray must include its selected-plane 3D cast.')
    chunks = manifest.get('chunks')
    if not isinstance(chunks, list) or not chunks:
        raise ValueError('Manifest has no chunks.')
    assets = [check_asset(world, chunk, '.bin.gz') for chunk in chunks]
    if len({asset['path'] for asset in assets}) != len(assets):
        raise ValueError('Duplicate manifest chunks.')
    navigation = manifest.get('navigationAsset')
    if not isinstance(navigation, dict) or navigation.get('asset') != f'{map_name}_navigation.json.gz':
        raise ValueError('Manifest must identify its navigation asset and checksum.')
    assets.append(check_asset(world, navigation, '.json.gz'))
    if reference.get('floorAlternativeCompletion') is not None:
        from verify_world_reference_metadata import verify_floor_completion
        proof_files = verify_floor_completion(reference_path, world / navigation['asset'])
        assets.extend({'path': str(path), 'sha256': sha256(path)} for path in proof_files)
    assets += [{'path': str(path), 'sha256': sha256(path)} for path in (manifest_path, reference_path)]
    return {
        'map': map_name, 'origins': len(origins), 'rays': len(rays), 'directions': directions,
        'referenceFingerprints': reference['source'], 'assets': assets,
        'layers': len(manifest['layers']), 'chunks': len(chunks),
    }


def report_failures(report, source):
    failures = []
    if report.get('map') != source['map'] or report.get('referenceFingerprints') != source['referenceFingerprints']:
        failures.append('Report map or reference fingerprints differ from preflight.')
    if report.get('validatedAllChunks') is not True:
        failures.append('Every runtime chunk must be decoded and validated.')
    for key in ('outsideNavigationOrigins', 'differentSelectedPlaneRays', 'unexplainedSelectedFloorOrigins'):
        if report.get(key) != []:
            failures.append(f'{key} is nonempty or missing.')
    alternatives = report.get('differentSelectedFloorOrigins', [])
    details = report.get('differentSelectedFloorDetails', [])
    if len(set(alternatives)) != len(alternatives) or {entry.get('origin') for entry in details} != set(alternatives) or any(
            entry.get('matchesSourceFloorAlternative') is not True for entry in details):
        failures.append('Excluded floor origins are not proven source alternatives.')
    compared = report.get('comparedOrigins', 0)
    if report.get('origins') != source['origins'] or compared <= 0 or compared + len(alternatives) != source['origins']:
        failures.append('Runtime origin coverage is incomplete.')
    expected_rays = compared * source['directions']
    for key in ('allComparedRays', 'samePlane3dReferenceRays'):
        if report.get(key, {}).get('count') != expected_rays:
            failures.append(f'{key} does not cover every admitted origin/direction.')
    for key, outliers in (('allComparedRays', 'outliersAbove2Cm'),
                          ('samePlane3dReferenceRays', 'planeOutliersAbove2Cm')):
        metric = report.get(key, {})
        count, within = metric.get('count', 0), metric.get('within2Cm', -1)
        if not 0 <= within <= count or len(report.get(outliers, [])) != count - within:
            failures.append(f'{outliers} does not report every difference above 2 cm.')
    polygon = report.get('polygonBoundaryAgainstExactRays', {})
    if polygon.get('count', 0) <= 0 or not 0 <= polygon.get('maximumMeters', float('inf')) < .02:
        failures.append('Polygon boundary differs from exact rays by 2 cm or more.')
    for key in ('maximumDefenseDistanceErrorMeters', 'maximumPolygonCenterErrorMeters'):
        if not 0 <= report.get(key, float('inf')) < 1e-6:
            failures.append(f'{key} exceeds the projection/center-ray tolerance.')
    return failures


def combined_metrics(entries):
    measured = [entry['metrics'] for entry in entries if 'metrics' in entry]
    totals = {'mapsWithMetrics': len(measured),
              'origins': sum(item['origins'] for item in measured),
              'comparedOrigins': sum(item['comparedOrigins'] for item in measured),
              'provenAlternativeFloorOrigins': sum(len(item['differentSelectedFloorDetails']) for item in measured)}
    for key in ('allComparedRays', 'samePlane3dReferenceRays', 'exactHeightRays', 'polygonBoundaryAgainstExactRays'):
        metrics = [item[key] for item in measured]
        totals[key] = {field: sum(item.get(field, 0) for item in metrics)
                       for field in ('count', 'within2Cm', 'within10Cm')}
        totals[key]['maximumMeters'] = max((item.get('maximumMeters', 0) for item in metrics), default=0)
    return totals


def flutter_command(launcher):
    path = Path(shutil.which(launcher) or launcher).resolve()
    if not path.is_file():
        raise FileNotFoundError(f'Flutter launcher not found: {path}')
    if os.name == 'nt' and path.suffix.lower() in ('.bat', '.cmd'):
        # Invoke the same prepared SDK snapshot as flutter.bat through an exe.
        # This keeps paths as structured arguments, outside cmd.exe expansion.
        sdk = path.parent.parent
        dart = sdk / 'bin/cache/dart-sdk/bin/dart.exe'
        snapshot = sdk / 'bin/cache/flutter_tools.snapshot'
        packages = sdk / 'packages/flutter_tools/.dart_tool/package_config.json'
        if not all(item.is_file() for item in (dart, snapshot, packages)):
            raise ValueError('Prepare this SDK with flutter --version before the audit.')
        return [str(dart), f'--packages={packages}', str(snapshot)], {'FLUTTER_ROOT': str(sdk)}
    return [str(path)], {}


def launch(command, repo, environment, log_path, timeout):
    with log_path.open('w', encoding='utf-8') as log:
        process = subprocess.Popen(command, cwd=repo, env=environment, stdout=log, stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0,
                                   start_new_session=os.name != 'nt')
        try:
            return process.wait(timeout=timeout), False
        except subprocess.TimeoutExpired:
            if os.name == 'nt':
                subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                               stdout=log, stderr=subprocess.STDOUT, check=False)
            else:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            return process.returncode, True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--world-directory', type=Path, required=True)
    parser.add_argument('--reference-directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--maps', nargs='+', help='Explicit subset for smoke tests; default is every MapValue.')
    parser.add_argument('--timeout-seconds', type=int, default=600)
    parser.add_argument('--overwrite', action='store_true')
    args = parser.parse_args(argv)
    repo, world, references, output = [path.resolve() for path in (
        args.repo, args.world_directory, args.reference_directory, args.output)]
    output.mkdir(parents=True, exist_ok=True)
    aggregate_path = output / 'aggregate.json'
    if aggregate_path.exists() and not args.overwrite:
        parser.error('Output already contains an audit. Choose another directory or --overwrite.')
    all_maps = read_map_names(repo)
    selected = args.maps or all_maps
    if len(set(selected)) != len(selected) or any(name not in all_maps for name in selected):
        parser.error('--maps must contain unique MapValue names.')
    if args.timeout_seconds <= 0:
        parser.error('--timeout-seconds must be positive.')
    aggregate = {
        'schemaVersion': 1, 'startedUtc': datetime.now(timezone.utc).isoformat(),
        'scope': 'all_maps' if set(selected) == set(all_maps) else 'explicit_subset',
        'requiredMaps': all_maps, 'requestedMaps': selected, 'worldDirectory': str(world),
        'referenceDirectory': str(references), 'runtimeStatus': 'preflight',
        'completeAllMapCoverage': False, 'maps': [], 'sourceReview': {'status': 'not_run'},
    }
    runtime_files = [*repo.glob('lib/view_cone/*.dart'),
        *repo.glob('lib/page_transition/navigation_geometry*.dart'),
        repo / 'lib/const/maps.dart', repo / 'tool/verify_world_factory_rays_test.dart',
        *repo.glob('lib/providers/*geometry*provider.dart')]
    aggregate['runtimeFiles'] = [{'path': str(path), 'sha256': sha256(path)}
                                 for path in sorted(set(runtime_files)) if path.is_file()]
    write_json(aggregate_path, aggregate)
    sources = {}
    for name in selected:
        try:
            sources[name] = preflight(name, world, references)
        except (OSError, ValueError, KeyError, TypeError) as error:
            aggregate['maps'].append({'map': name, 'runtimeStatus': 'failed', 'failures': [str(error)]})
    if aggregate['maps']:
        aggregate['runtimeStatus'] = 'preflight_failed'
        aggregate['notRunMaps'] = [name for name in selected if name in sources]
        write_json(aggregate_path, aggregate)
        print(f'Preflight failed. No Flutter checks ran. See {aggregate_path}', flush=True)
        return 1
    try:
        command, overrides = flutter_command(args.flutter)
    except (OSError, ValueError) as error:
        aggregate.update(runtimeStatus='configuration_failed', failure=str(error))
        write_json(aggregate_path, aggregate)
        print(f'Configuration failed: {error}', flush=True)
        return 1
    environment = {**os.environ, **overrides}
    reports, logs = output / 'reports', output / 'logs'
    reports.mkdir(exist_ok=True)
    logs.mkdir(exist_ok=True)
    source_outliers, plane_outliers = [], []
    aggregate['runtimeStatus'] = 'running'
    for index, name in enumerate(selected):
        print(f'[{index + 1}/{len(selected)}] {name}: factory, all chunks, and polygon rays', flush=True)
        started = time.perf_counter()
        report_path, log_path = reports / f'{name}-factory-rays.json', logs / f'{name}.log'
        report_path.unlink(missing_ok=True)
        arguments = command + ['test', '--no-pub', f'--dart-define=WORLD_DIRECTORY={world.as_posix()}',
            f'--dart-define=REFERENCE_DIRECTORY={references.as_posix()}', f'--dart-define=WORLD_MAP={name}',
            '--dart-define=WORLD_CHUNKED=true', '--dart-define=WORLD_VALIDATE_ALL_CHUNKS=true',
            f'--dart-define=WORLD_OUTPUT_DIRECTORY={reports.as_posix()}', 'tool/verify_world_factory_rays_test.dart']
        entry = {'map': name, 'log': str(log_path), 'report': str(report_path), 'input': sources[name]}
        failures = []
        try:
            code, timed_out = launch(arguments, repo, environment, log_path, args.timeout_seconds)
            entry.update({'exitCode': code, 'timedOut': timed_out})
            if code != 0 or timed_out:
                failures.append('Flutter audit timed out.' if timed_out else f'Flutter audit exited with {code}.')
            report = json.loads(report_path.read_text(encoding='utf-8'))
            failures += report_failures(report, sources[name])
            entry['metrics'] = {key: report[key] for key in ('origins', 'comparedOrigins',
                'differentSelectedFloorDetails', 'allComparedRays', 'samePlane3dReferenceRays',
                'exactHeightRays', 'polygonBoundaryAgainstExactRays')}
            source_outliers.extend({'map': name, **item} for item in report['outliersAbove2Cm'])
            plane_outliers.extend({'map': name, **item} for item in report['planeOutliersAbove2Cm'])
            for asset in sources[name]['assets'] + aggregate['runtimeFiles']:
                if sha256(Path(asset['path'])) != asset['sha256']:
                    failures.append(f'Input changed during verification: {asset["path"]}')
        except (OSError, ValueError, KeyError, TypeError) as error:
            failures.append(str(error))
        entry.update({'runtimeStatus': 'failed' if failures else 'passed', 'failures': failures,
                      'seconds': time.perf_counter() - started})
        aggregate['maps'].append(entry)
        write_json(aggregate_path, aggregate)
        print(f'{name}: {entry["runtimeStatus"]} in {entry["seconds"]:.1f}s', flush=True)
    passed = all(item['runtimeStatus'] == 'passed' for item in aggregate['maps'])
    aggregate.update({'runtimeStatus': 'passed' if passed else 'failed',
        'completeAllMapCoverage': passed and set(selected) == set(all_maps),
        'finishedUtc': datetime.now(timezone.utc).isoformat(),
        'totals': combined_metrics(aggregate['maps']),
        'sourceReview': {
            'status': 'required' if source_outliers or plane_outliers else 'no_outliers_above_2cm',
            'policy': 'No outliers waived. Source geometry, sampled-height differences, and top-edge proofs require separate review.',
            'trueEyeOutliersAbove2Cm': source_outliers, 'samePlaneOutliersAbove2Cm': plane_outliers,
        }})
    write_json(aggregate_path, aggregate)
    print(f'Runtime {aggregate["runtimeStatus"]}; source review {aggregate["sourceReview"]["status"]}. {aggregate_path}', flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
