"""Freeze source-origin queries against the independently verified native build."""
import argparse
import ctypes as C
import gzip
import hashlib
import json
import math
import struct
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--references', type=Path, required=True)
parser.add_argument('--packs', type=Path, required=True)
parser.add_argument('--library', type=Path, required=True)
parser.add_argument('--work', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()

class Query(C.Structure):
    _fields_ = [(name, C.c_double) for name in 'x y z dx dy range cone'.split()]

class Batch(C.Structure):
    _fields_ = [('structSize', C.c_uint32), ('status', C.c_uint32),
                ('stamp', C.c_uint64), ('lease', C.c_uint64),
                ('positions', C.POINTER(C.c_float)), ('offsets', C.POINTER(C.c_uint32)),
                ('floatCount', C.c_uint32), ('coneCount', C.c_uint32)] + [
                    (name, C.c_double) for name in ['query', 'alpha', 'mesh', 'wall']]

library = C.CDLL(str(args.library.resolve()))
library.ih_open.argtypes = [C.c_char_p, C.c_uint32, C.c_uint32, C.c_char_p, C.c_uint32]
library.ih_open.restype = C.c_void_p
library.ih_compute.argtypes = [C.c_void_p, C.POINTER(Query), C.c_uint32, C.c_uint64, C.POINTER(Batch)]
library.ih_release.argtypes = [C.c_void_p, C.c_uint64]
library.ih_close.argtypes = [C.c_void_p]
error = C.create_string_buffer(4096)
result = {'version': 1, 'baselineLibrarySha256': hashlib.sha256(args.library.read_bytes()).hexdigest(),
          'scope': 'Transfer and build regression against the frozen, source-verified native algorithm. These samples are not new game certification.', 'maps': {}}
args.work.mkdir(parents=True, exist_ok=True)
for pack in sorted(args.packs.glob('*/*.height.bin.gz')):
    name = pack.parent.name
    source_bytes = (args.references / f'{name}.json').read_bytes()
    source = json.loads(source_bytes)
    compressed = pack.read_bytes()
    raw = gzip.decompress(compressed)
    size = struct.unpack_from('<I', raw, 4)[0]
    header = json.loads(raw[8:8 + size])
    base = (8 + size + 7) // 8 * 8
    folder = args.work / name
    folder.mkdir(exist_ok=True)
    (folder / 'height-source.raw').write_bytes(raw)
    (folder / 'arrays.txt').write_text('\n'.join(
        f'{key} {base + entry["offset"]} {entry["count"]}' for key, entry in header['arrays'].items()))
    (folder / 'alpha-textures.txt').write_text('\n'.join(
        f'{index} {entry["width"]} {entry["height"]} {base + entry["offset"]}' for index, entry in enumerate(header['textures'])))
    wraps = {'repeat': 0, 'clamp': 1, 'mirror': 2, 'black': 3}
    (folder / 'alpha-materials.txt').write_text('\n'.join(
        f'{entry["material"]} {entry["texture"]} {entry["threshold"]:.17g} '
        f'{entry["alphaScale"]:.17g} {entry["alphaBias"]:.17g} '
        f'{wraps[entry["wrapS"]]} {wraps[entry["wrapT"]]}' for entry in header['materials']))
    (folder / 'parameters.txt').write_text(' '.join(map(str, header['heightDomainMeters'])))
    handle = library.ih_open(str(folder.resolve()).encode(), 4, 10, error, len(error))
    if not handle:
        raise RuntimeError(error.value)
    queries = []
    try:
        for index in range(16):
            origin_index = index * (len(source['origins']) - 1) // 15
            origin = source['origins'][origin_index]['positionMeters']
            facing = index * 2 * math.pi / 16 + .30997188027889533
            values = [origin[0], origin[1], origin[2] + 1.75,
                      math.cos(facing), math.sin(facing), 43., 103 * math.pi / 180]
            query = Query(*values)
            output = Batch()
            output.structSize = C.sizeof(Batch)
            if library.ih_compute(handle, C.byref(query), 1, index, C.byref(output)):
                raise RuntimeError(f'{name} query {index} failed')
            data = C.string_at(output.positions, output.floatCount * 4)
            queries.append({'originIndex': origin_index, 'values': values,
                            'floatCount': output.floatCount, 'meshSha256': hashlib.sha256(data).hexdigest()})
            assert library.ih_release(handle, output.lease) == 0
    finally:
        assert library.ih_close(handle) == 0
    result['maps'][name] = {'sourceReferenceSha256': hashlib.sha256(source_bytes).hexdigest(),
                            'packSha256': hashlib.sha256(compressed).hexdigest(), 'queries': queries}
    print(f'{name}: {len(queries)} frozen source-origin queries')
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2) + '\n')
