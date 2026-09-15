"""Measure the packaged native DLL with frozen moving poses and a ground field."""
import argparse
import ctypes as C
import json
from pathlib import Path
import time
import numpy as np
from build_global_tactical_candidate import GroundField


class Query(C.Structure):
    _fields_ = [(name, C.c_double) for name in 'x y z dx dy range cone'.split()]


class Batch(C.Structure):
    _fields_ = [('structSize', C.c_uint32), ('status', C.c_uint32), ('stamp', C.c_uint64), ('lease', C.c_uint64),
               ('positions', C.POINTER(C.c_float)), ('offsets', C.POINTER(C.c_uint32)),
               ('floatCount', C.c_uint32), ('coneCount', C.c_uint32)] + [(name, C.c_double) for name in ('query', 'alpha', 'mesh', 'wall')]


def run(library_path, folder, fixture_path, field_path, output, moving_index):
    library = C.CDLL(str(library_path.resolve()))
    library.ih_open.argtypes = [C.c_char_p, C.c_uint32, C.c_uint32, C.c_char_p, C.c_uint32]
    library.ih_open.restype = C.c_void_p
    library.ih_compute.argtypes = [C.c_void_p, C.POINTER(Query), C.c_uint32, C.c_uint64, C.POINTER(Batch)]
    library.ih_release.argtypes = [C.c_void_p, C.c_uint64]
    library.ih_close.argtypes = [C.c_void_p]
    queries = np.fromfile(fixture_path, dtype='<f8').reshape(-1, 10, 7).copy()
    if field_path:
        field = GroundField(field_path)
        flat = queries.reshape(-1, 7)
        flat[:, 2] -= field.heights(flat[:, :2])
    error = C.create_string_buffer(4096)
    started = time.perf_counter()
    handle = library.ih_open(str(folder.resolve()).encode(), 4, 10, error, len(error))
    if not handle:
        raise RuntimeError(error.value)
    load_ms = (time.perf_counter() - started) * 1000
    results = {}
    try:
        for mode in ('moving-one', 'all-ten'):
            measurements = []
            for index, rows in enumerate(queries):
                selected = rows[moving_index:moving_index + 1] if mode == 'moving-one' else rows
                data = (Query * len(selected))(*(Query(*row) for row in selected))
                batch = Batch()
                batch.structSize = C.sizeof(batch)
                started = time.perf_counter()
                status = library.ih_compute(handle, data, len(selected), index, C.byref(batch))
                wall = (time.perf_counter() - started) * 1000
                if status:
                    raise RuntimeError(f'Native compute status {status}')
                assert library.ih_release(handle, batch.lease) == 0
                if index >= 60:
                    measurements.append([wall, batch.wall / 1000, batch.query / 1000, batch.alpha / 1000, batch.mesh / 1000, batch.floatCount])
            values = np.array(measurements)
            results[mode] = dict(samples=len(values), wallMs=dict(p50=float(np.percentile(values[:, 0], 50)), p95=float(np.percentile(values[:, 0], 95)), maximum=float(values[:, 0].max())),
                                 within144HzBudget=int(np.sum(values[:, 0] <= 1000 / 144)), p95NativeWallMs=float(np.percentile(values[:, 1], 95)),
                                 p95PhaseCpuMs=dict(query=float(np.percentile(values[:, 2], 95)), alpha=float(np.percentile(values[:, 3], 95)), mesh=float(np.percentile(values[:, 4], 95))),
                                 maximumMeshFloats=int(values[:, 5].max()))
            print(mode, results[mode], flush=True)
    finally:
        closed = library.ih_close(handle)
        if closed:
            raise RuntimeError(f'Native close status {closed}')
    report = dict(loadMs=load_ms, workers=4, movingIndex=moving_index, naturalShutdown=True, modes=results,
                  scope='Synchronous native computation only; excludes Dart queue, renderer and GPU. Offline bake contention must be excluded for authoritative timing.')
    output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('library', 'folder', 'fixture', 'output'):
        parser.add_argument(name, type=Path)
    parser.add_argument('--field', type=Path)
    parser.add_argument('--moving-index', type=int, default=4)
    args = parser.parse_args()
    run(args.library, args.folder, args.fixture, args.field, args.output, args.moving_index)
