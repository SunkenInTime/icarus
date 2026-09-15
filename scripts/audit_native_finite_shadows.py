"""Check native projection against independent rays and frozen real workloads."""
import argparse
import json
from pathlib import Path
import time

import numpy as np
import shapely

from audit_finite_receiver_shadows import scenes
from experimental_floor_relative_visibility import first_hit
from finite_receiver_shadows import Receiver, build_shadows, renderer_mesh_checked
from lift_reviewed_wall_source_heights import sha
from native_finite_shadows import NativeFiniteShadows


def mesh_shape(mesh, eye):
    if not len(mesh):
        return shapely.Polygon()
    return shapely.union_all(shapely.polygons(mesh.astype(float) + np.asarray(eye[:2])))


def audit(library, real_fixtures, output):
    if output.exists():
        raise FileExistsError(output)
    if not real_fixtures.is_dir():
        raise ValueError('Real fixture directory does not exist')
    fixture_report = json.loads((real_fixtures/'report.json').read_text())
    expected_files = {f"{row['id']}.npz" for row in fixture_report['records']}
    actual_files = {path.name for path in real_fixtures.glob('*.npz')}
    if not expected_files or actual_files != expected_files:
        raise ValueError('Real fixture files must match the nonempty frozen report exactly')
    native = NativeFiniteShadows(library)
    results = []
    for name, eye, triangles, receivers in scenes():
        for receiver_index, receiver in enumerate(receivers):
            mesh, fallback = native.project(eye, triangles, receiver)
            assert not fallback.any(), (name, fallback)
            low, high = receiver.footprint.min(0), receiver.footprint.max(0)
            xy = np.array(np.meshgrid(np.linspace(low[0]+.0137, high[0]-.0173, 113),
                np.linspace(low[1]+.0191, high[1]-.0119, 37))).reshape(2, -1).T
            expected = np.array([first_hit(triangles, eye, target) is not None for target in receiver.lift(xy)])
            observed = shapely.covers(mesh_shape(mesh, eye), shapely.points(xy))
            assert np.array_equal(expected, observed), (name, int((expected != observed).sum()))
            results.append(dict(scene=name, receiver=receiver_index, queries=len(xy), blocked=int(expected.sum())))
    workloads = []
    for path in sorted(real_fixtures.glob('*.npz')):
        with np.load(path) as archive:
            data = {k: archive[k] for k in archive.files}
        eye = data['observer']; receiver = Receiver(data['receiverFootprint'], data['receiverPlane'])
        opaque = data['faceMasks'] < 0
        triangles = data['sourceTriangles'][opaque]
        mesh, fallback = native.project(eye, triangles, receiver)
        python_rows, python_fallback = build_shadows(eye, triangles, [receiver])
        python_mesh, quantized_fallback = renderer_mesh_checked(eye, python_rows)
        python_fallback.extend(quantized_fallback)
        python_ids = {row['sourceFace'] for row in python_fallback}
        assert set(np.flatnonzero(fallback)) == python_ids, (path.name, 'fallback identities differ')
        native_shape, python_shape = mesh_shape(mesh, eye), mesh_shape(python_mesh, eye)
        difference = float(shapely.symmetric_difference(native_shape, python_shape).area)
        assert difference < 1e-6, (path.name, difference)
        # Prepared local workload only. Allocation/ctypes included; broadphase,
        # receiver selection, masking fallbacks and app rendering are excluded.
        times = []
        for i in range(120):
            begin = time.perf_counter()
            native.project(eye, triangles, receiver)
            elapsed = (time.perf_counter()-begin)*1000
            if i >= 20:
                times.append(elapsed)
        workloads.append(dict(id=path.stem, fixtureSha256=sha(path), opaqueFaces=len(triangles),
            maskedFaces=int((~opaque).sum()), fallbackFaces=int((fallback > 0).sum()),
            fallbackSourceFaces=data['sourceFaceIds'][opaque][fallback > 0].tolist(),
            float32FallbackFaces=int((fallback == 7).sum()),
            rendererTriangles=len(mesh), nativePythonSymmetricDifferenceSquareMeters=difference,
            milliseconds={k:float(np.quantile(times,q)) for k,q in [('p50',.5),('p95',.95),('p99',.99)]}))
    output.mkdir(parents=True)
    report = dict(scope=__doc__, syntheticIndependentRays=sum(r['queries'] for r in results), synthetic=results,
        realPreparedWorkloads=workloads, librarySha256=sha(library), auditorSha256=sha(Path(__file__)),
        realFixtureReportSha256=sha(real_fixtures/'report.json'), expectedRealWorkloads=len(expected_files),
        cppSha256=sha(Path(__file__).parent/'native_finite_shadows/projection.cpp'), productionMutation=False,
        limitations=['Opaque projection only, explicit unresolved contacts retained.',
            'Prepared local workload timings exclude broadphase, receiver/layer selection, masked fallback and app rendering.',
            'Concurrent background work; no quiet whole-map high-refresh result.',
            'Real workload coverage compared to Python prototype. Independent real blocked-wall controls are separate.'])
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['synthetic','realPreparedWorkloads']},indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['library', 'real_fixtures', 'output']:
        parser.add_argument(key,type=Path)
    audit(**vars(parser.parse_args()))
