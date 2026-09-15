"""Compare the diagnostic native caster with the independent triangle oracle."""
import argparse
import json
from pathlib import Path
import time
import numpy as np
from audit_tactical_target_rays import ReferenceModel
from native_reference_cast import NativeReferenceModel


def verify(revision, name, count):
    native = NativeReferenceModel(revision / 'full-height-input-v1' / name / f'{name}.height.bin.gz',
                                  revision / 'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    oracle = ReferenceModel.__new__(ReferenceModel)
    oracle.__dict__.update(native.__dict__)
    fixtures = json.loads((revision / 'gallery-all-map-lower-provisional-v1' / f'{name}-fixtures.json').read_text())['cases']
    rng = np.random.default_rng(77018)
    queries = []
    for i in range(count):
        q = fixtures[i % len(fixtures)]['query']
        origin = np.array(q[:3]) + rng.uniform(-.5, .5, 3)
        angle = rng.uniform(-np.pi, np.pi)
        target = origin + [np.cos(angle) * q[5], np.sin(angle) * q[5], rng.uniform(-4, 4)]
        queries.append((origin, target, 0. if i % 3 else 1e-5, 0. if i % 4 else 1e-5))
    started = time.perf_counter()
    expected = [oracle.cast(a, b, min_distance=c, end_padding=d) for a, b, c, d in queries]
    python_seconds = time.perf_counter() - started
    started = time.perf_counter()
    actual = [native.cast(a, b, min_distance=c, end_padding=d) for a, b, c, d in queries]
    native_seconds = time.perf_counter() - started
    errors = []; failed = []
    for i, (a, b) in enumerate(zip(expected, actual)):
        error = 0. if a is None and b is None else float('inf') if a is None or b is None else abs(a['distanceMeters'] - b['distanceMeters'])
        errors.append(error)
        if error > 1e-6:
            failed.append(dict(index=i, expected=a, actual=b))
    report = dict(map=name, queries=count, maximumDistanceErrorMeters=max(errors), failures=failed,
                  pythonSeconds=python_seconds, nativeSeconds=native_seconds)
    (revision / f'native-reference-cast-{name}-verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)
    if failed:
        raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('map')
    parser.add_argument('--count', type=int, default=1000)
    args = parser.parse_args()
    verify(args.revision, args.map, args.count)
