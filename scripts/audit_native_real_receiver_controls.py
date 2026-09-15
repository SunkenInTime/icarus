"""Compare native Float32 shadow output to frozen alpha-aware source rays."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from finite_receiver_shadows import Receiver
from native_finite_shadows import NativeFiniteShadows


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', type=Path)
    parser.add_argument('fixtures', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    source_report_path = args.fixtures/'report.json'
    source = json.loads(source_report_path.read_bytes())
    native = NativeFiniteShadows(args.library)
    records = []
    for row in source['records']:
        path = args.fixtures/(row['id']+'.npz')
        with np.load(path) as data:
            receiver = Receiver(data['receiverFootprint'], data['receiverPlane'])
            eye = data['observer']
            opaque = data['faceMasks'] < 0
            mesh, fallback = native.project(eye, data['sourceTriangles'][opaque], receiver)
            fallback_ids = data['sourceFaceIds'][opaque][fallback > 0].tolist()
        assert np.isfinite(mesh).all()
        shape = shapely.union_all(shapely.polygons(mesh.astype(float)+eye[:2])) if len(mesh) else shapely.Polygon()
        actual = [bool(shapely.covers(shape, shapely.Point(ray['target'][:2]))) for ray in row['rays']]
        expected = [ray['sourceHit'] is not None for ray in row['rays']]
        mismatches = [i for i, (a, b) in enumerate(zip(actual, expected)) if a != b]
        records.append(dict(id=row['id'], fixtureSha256=sha(path), rays=len(actual), blocked=sum(expected),
                            mismatchingRayIndices=mismatches, sourceContactFallbackIds=fallback_ids,
                            maskedFallbackIds=row['maskedFallbackFaces'], rendererTriangles=len(mesh),
                            meshSha256=hashlib.sha256(mesh.tobytes()).hexdigest()))
    report = dict(scope=__doc__, sourceReportSha256=sha(source_report_path), librarySha256=sha(args.library),
                  cppSha256=sha(Path(__file__).parent/'native_finite_shadows/projection.cpp'),
                  auditorSha256=sha(Path(__file__)), completeSourcePackSha256=source['completePackSha256'],
                  rays=sum(x['rays'] for x in records), blocked=sum(x['blocked'] for x in records),
                  mismatches=sum(len(x['mismatchingRayIndices']) for x in records), records=records,
                  limitations=['Independent source rays are frozen from the hash-bound original-height scene report.',
                               'Sample agreement does not resolve receiver-layer ownership, masked or coplanar fallback.',
                               'This verifies the native Float32 source-XY mesh contract, not app raster or live game behavior.'])
    (args.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'records'}, indent=2))
    if report['mismatches']:
        raise AssertionError('Native renderer mesh disagrees with frozen original-source rays')


if __name__ == '__main__':
    main()
