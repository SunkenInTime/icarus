"""Bounded serial full-source bakes, released only after independent ray checks."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def run(revision, maps):
    output = revision / 'global-ground-complete-v2'
    output.mkdir(parents=True, exist_ok=True)
    progress_path = output / 'batch-progress.json'
    progress = dict(completed=[], running=None, failed=None)
    def save():
        temporary = progress_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(progress, indent=2) + '\n')
        temporary.replace(progress_path)
    for name in maps:
        target = output / name
        if target.exists():
            raise FileExistsError(f'{target} already exists; do not overwrite a reviewed bake')
        source = revision / 'full-height-input-v1' / name / (name + '.height.bin.gz')
        field = revision / 'global-ground-v1' / (name + '.tactical-ground.json.gz')
        progress['running'] = name
        save()
        print(f'BUILD {name}', flush=True)
        with (output / (name + '.build.log')).open('w') as log:
            result = subprocess.run([sys.executable, 'scripts/build_global_tactical_candidate.py', str(source), str(field), str(target)], stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            progress['failed'] = dict(map=name, phase='build', exitCode=result.returncode)
            save()
            raise RuntimeError(progress['failed'])
        with (target / 'transform-rays.log').open('w') as log:
            result = subprocess.run([sys.executable, 'scripts/verify_tactical_transform.py', str(source), str(target / (name + '.height.bin.gz')),
                                     str(field), str(revision / 'gallery-v1' / (name + '-fixtures.json')), str(target / 'transform-rays.json')], stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            progress['failed'] = dict(map=name, phase='source-ray-verification', exitCode=result.returncode)
            save()
            raise RuntimeError(progress['failed'])
        summary = json.loads((target / 'summary.json').read_text())
        progress['completed'].append(dict(map=name, packSha256=summary['packSha256'], compressedBytes=summary['compressedBytes']))
        progress['running'] = None
        save()
        print('READY ' + json.dumps(progress['completed'][-1]), flush=True)
    print('All requested maps baked and source-ray checked.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('maps', nargs='+')
    args = parser.parse_args()
    run(args.revision, args.maps)
