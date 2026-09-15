"""Replay the synthetic descending-ramp policy through an existing app DLL."""
import argparse
import ctypes as C
import gzip
import hashlib
import json
from pathlib import Path
import struct

import numpy as np
import shapely

from audit_finite_receiver_shadows import scenes
from benchmark_tactical_native import Query, Batch
from experimental_floor_relative_visibility import FloorPatch, flatten_triangles


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(folder):
    _, _, original, receivers = scenes()[0]
    flat, source_faces, weights = flatten_triangles(original, [FloorPatch(r.footprint, r.floor_plane) for r in receivers])
    vertices = flat.reshape(-1, 3).astype('<f8')
    faces = np.arange(len(vertices), dtype='<u4').reshape(-1, 3)
    arrays = dict(vertices=vertices, faces=faces,
                  bounds=np.array([[*vertices.min(0), *vertices.max(0)]], dtype='<f8'),
                  nodes=np.array([[0, len(faces), -1, -1]], dtype='<i4'),
                  faceMasks=np.full(len(faces), -1, dtype='<i4'),
                  maskedUvs=np.array([], dtype='<f8'), maskedMaterials=np.array([], dtype='<u4'))
    header = dict(map='synthetic-standing-ramp', heightDomainMeters=[0., 6.],
                  arrays={}, textures=[], materials=[])
    offset, payload = 0, []
    for name, values in arrays.items():
        offset = (offset + 7) // 8 * 8
        header['arrays'][name] = dict(offset=offset, count=values.size, dtype=str(values.dtype), shape=list(values.shape))
        payload.append((offset, values.tobytes()))
        offset += values.nbytes
    encoded = json.dumps(header, separators=(',', ':')).encode()
    base = (8 + len(encoded) + 7) // 8 * 8
    raw = bytearray(base + offset)
    raw[:8] = struct.pack('<4sI', b'IHD1', len(encoded))
    raw[8:8 + len(encoded)] = encoded
    for at, data in payload:
        raw[base + at:base + at + len(data)] = data
    folder.mkdir(parents=True, exist_ok=False)
    (folder / 'height-source.raw').write_bytes(raw)
    (folder / 'synthetic.height.bin.gz').write_bytes(gzip.compress(raw, mtime=0))
    (folder / 'arrays.txt').write_text('\n'.join(f'{name} {base + value["offset"]} {value["count"]}' for name, value in header['arrays'].items()))
    (folder / 'parameters.txt').write_text('0 6')
    (folder / 'alpha-materials.txt').write_text('')
    (folder / 'alpha-textures.txt').write_text('')
    np.savez_compressed(folder / 'source-correspondence.npz', originalTriangles=original,
                        flattenedTriangles=flat, sourceFaces=source_faces, barycentrics=weights)


def replay(library_path, folder):
    library = C.CDLL(str(library_path.resolve()))
    library.ih_open.argtypes = [C.c_char_p, C.c_uint32, C.c_uint32, C.c_char_p, C.c_uint32]
    library.ih_open.restype = C.c_void_p
    library.ih_compute.argtypes = [C.c_void_p, C.POINTER(Query), C.c_uint32, C.c_uint64, C.POINTER(Batch)]
    library.ih_release.argtypes = [C.c_void_p, C.c_uint64]
    library.ih_close.argtypes = [C.c_void_p]
    error = C.create_string_buffer(4096)
    handle = library.ih_open(str(folder.resolve()).encode(), 1, 1, error, len(error))
    if not handle:
        raise RuntimeError(error.value)
    query = [1., 0., 1.75, 1., 0., 20., 103 * np.pi / 180]
    try:
        batch = Batch()
        batch.structSize = C.sizeof(batch)
        code = library.ih_compute(handle, (Query * 1)(Query(*query)), 1, 1, C.byref(batch))
        assert code == 0, code
        try:
            mesh = np.ctypeslib.as_array(batch.positions, shape=(batch.floatCount,)).copy().reshape(-1, 3, 2)
        finally:
            assert library.ih_release(handle, batch.lease) == 0
    finally:
        assert library.ih_close(handle) == 0
    polygons = shapely.polygons(mesh.astype(float) + np.array(query[:2]))
    shadow = shapely.union_all(polygons)
    targets = [{'sourceXY': [x, 0], 'visible': not bool(shapely.covers(shadow, shapely.Point(x, 0)))} for x in [4., 8., 12.]]
    assert [row['visible'] for row in targets] == [True, False, False], targets
    return dict(library=str(library_path.resolve()), librarySha256=digest(library_path),
                query=query, targetCoverage=targets, triangles=len(mesh),
                meshSha256=hashlib.sha256(mesh.tobytes()).hexdigest(), naturalClose=True), mesh


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--library', type=Path, action='append', required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    native = args.output / 'native'
    prepare(native)
    records = []
    for index, library in enumerate(args.library):
        row, mesh = replay(library, native)
        records.append(row)
        np.save(args.output / f'native-shadow-{index}.npy', mesh)
    report = dict(status='actual-native-current-policy-regression-reproduced', records=records,
                  nativePackSha256=digest(native / 'synthetic.height.bin.gz'),
                  nativeInputSha256={path.name: digest(path) for path in native.iterdir() if path.is_file()},
                  independentExpectedHeadVisibility={'near8m': False, 'far12m': True},
                  conclusion='Existing app native output hides both near and far standing targets; independent original-height oracle sees the far head.',
                  limitation='Synthetic source pack and existing compiled DLL; no Flutter pixels, no live-game pose, no production asset changes.',
                  scriptSha256=digest(Path(__file__)))
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(status=report['status'], libraries=len(records), records=records)))


if __name__ == '__main__':
    main()
