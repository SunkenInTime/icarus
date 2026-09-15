"""Compose reviewed-candidate controls with verified full-source map bakes, serially."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--maps', nargs='+', required=True)
    parser.add_argument('--skip-runtime', action='store_true', help='Leave Flutter checks pending for the shared test slot')
    args = parser.parse_args()
    root, output = args.audit_root, args.output
    source_root = root / 'tactical-visibility-revision/global-ground-complete-v2'
    completed = {x['map']: x for x in json.loads((source_root / 'batch-progress.json').read_text())['completed']}
    output.mkdir(parents=True, exist_ok=True)
    progress = {'completed': [], 'failed': [], 'running': None}
    def save():
        (output / 'batch-progress.json').write_text(json.dumps(progress, indent=2))
    for name in args.maps:
        if name not in completed:
            raise ValueError(f'{name} has not passed the source bake verification')
        source = source_root / name / f'{name}.height.bin.gz'
        if hashlib.sha256(source.read_bytes()).hexdigest() != completed[name]['packSha256']:
            raise ValueError(f'{name} verified source hash mismatch')
        folder = output / name
        warp = root / f'tactical-alignment-warps-v1/{name}/warp.npz'
        ground = output / 'ground' / f'{name}.tactical-ground.json.gz'
        progress['running'] = name
        save()
        def run(argv, log_name):
            result = subprocess.run([str(x) for x in argv], capture_output=True, text=True)
            (output / f'{name}-{log_name}.log').write_text(result.stdout + result.stderr)
            if result.returncode:
                raise ValueError(f'{name} {log_name} failed; see log')
        try:
            run([sys.executable, 'scripts/tactical_alignment_candidate.py', '--map', name,
                 '--warp-file', warp, '--audit-root', root, '--output', folder,
                 '--split-cells', '--split-navigation', '--pack', source], 'geometry-navigation')
            run([sys.executable, 'scripts/tactical_alignment_ground.py', '--source',
                 root / f'tactical-visibility-revision/global-ground-v1/{name}.tactical-ground.json.gz',
                 '--warp-file', warp, '--audit-root', root, '--output', ground], 'ground')
            run([sys.executable, 'scripts/tactical_alignment_floor_fixtures.py', '--map', name,
                 '--audit-root', root, '--warp-file', warp, '--output', folder / 'floor-query-fixtures.json'], 'floor-fixtures')
            run([sys.executable, 'scripts/tactical_alignment_prepare.py',
                 '--pack', folder / f'{name}.height.bin.gz',
                 '--output', folder / 'native'], 'native-prepare')
            if not args.skip_runtime:
                run(['E:/src/flutter/bin/flutter.bat', 'test', 'tool/verify_tactical_alignment_navigation_test.dart',
                     '--no-pub', f'--dart-define=NAVIGATION_MAP={name}',
                     f'--dart-define=NAVIGATION_CANDIDATE={folder / f"{name}_navigation.json.gz"}', '--reporter', 'expanded'], 'navigation-runtime')
                run(['E:/src/flutter/bin/flutter.bat', 'test', 'tool/verify_tactical_alignment_ground_test.dart',
                     '--no-pub', f'--dart-define=TACTICAL_GROUND_CANDIDATE={ground}', '--reporter', 'expanded'], 'ground-runtime')
            report = json.loads((folder / 'candidate.json').read_text())
            proof = report['navigationPartition']
            if proof['unreachableInternalParents'] or proof['missingOriginalPortalPairs'] or proof['newUnauthorizedParentPairs']:
                raise ValueError(f'{name} navigation graph proof failed')
            progress['completed'].append({'map': name, 'packSha256': report['candidatePackSha256'],
                                          'navigationSha256': report['candidateNavigationSha256'],
                                          'groundSha256': hashlib.sha256(ground.read_bytes()).hexdigest(),
                                          'runtimeChecks': 'pending' if args.skip_runtime else 'passed'})
            print(name, 'composed; runtime checks pending' if args.skip_runtime else 'composed and runtime checked', flush=True)
        except Exception as error:
            progress['failed'].append({'map': name, 'error': str(error)})
            print(name, str(error), flush=True)
        progress['running'] = None
        save()


if __name__ == '__main__':
    main()
