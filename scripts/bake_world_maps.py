"""Run independent map bakes with bounded memory and resumable plane caches."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path, help='Audit root containing world/ and nav/baked/.')
    parser.add_argument('output', type=Path)
    parser.add_argument('--maps', nargs='+')
    parser.add_argument('--workers', type=int, default=4)
    parser.add_argument('--layer-step-cm', type=float, default=5)
    parser.add_argument('--elevations-folder', type=Path)
    parser.add_argument('--world-folder', type=Path, help='Override the placed-world input folder, for verified repairs.')
    parser.add_argument('--cache-only', action='store_true')
    parser.add_argument('--elevations-suffix', default='.json')
    args = parser.parse_args()
    if not 1 <= args.workers <= 16:
        parser.error('Use between 1 and 16 workers.')
    world_folder = args.world_folder or args.root / 'world'
    maps = args.maps or sorted(p.parent.name for p in world_folder.glob('*/geometry.npz'))
    args.output.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()

    def run(name):
        command = [sys.executable, str(Path(__file__).with_name('world_geometry_bake.py')),
                   str(world_folder / name),
                   str(args.root / 'nav' / 'baked' / f'{name}_navigation.json'),
                   str(args.output / (f'{name}.planes.json' if args.cache_only else f'{name}_visibility.json.gz')),
                   '--layer-step-cm', str(args.layer_step_cm),
                   '--texture-properties-root', str(args.root / 'materials' / 'texture-properties' / 'properties')]
        if args.elevations_folder:
            values = args.elevations_folder / f'{name}{args.elevations_suffix}'
            if values.exists():
                command.extend(['--elevations-file', str(values)])
        if args.cache_only:
            command.append('--cache-only')
        log_path = args.output / f'{name}.log'
        print(json.dumps({'map': name, 'status': 'started'}), flush=True)
        with log_path.open('w', encoding='utf-8') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        row = {'map': name, 'exitCode': result.returncode, 'log': str(log_path)}
        audit_path = args.output / (f'{name}.planes.audit.json' if args.cache_only else f'{name}_visibility.json.audit.json')
        if result.returncode == 0:
            row['summary'] = json.loads(audit_path.read_text())['summary']
        print(json.dumps(row), flush=True)
        return row

    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        for future in as_completed([executor.submit(run, name) for name in maps]):
            results.append(future.result())
    manifest = {'maps': sorted(results, key=lambda row: row['map']),
                'seconds': time.perf_counter() - started}
    (args.output / 'bake-manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    if any(row['exitCode'] for row in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
