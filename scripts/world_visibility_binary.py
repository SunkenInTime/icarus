r"""Lossless binary storage for baked world visibility geometry.

The uncompressed payload starts with b'ICVW\x01\x00\x00\x00', then a uint32
little-endian UTF-8 JSON header length. Zero padding aligns the array data to
four bytes. The header preserves geometry metadata and replaces each layer's
edges with edgeOffset/edgeCount, measured in layerEdges elements.

binaryArrays describes vertices, edges, layerEdges in that order. Each has
byteOffset and elementCount; byte offsets are relative to the aligned data
start. All arrays contain signed int32 little-endian values, with no coordinate
changes. Files use gzip around this payload. The decoder below reconstructs
JSON for offline verification; runtime consumers can retain typed array views.

Optional header encoding='delta-int32-v1' stores independent X/Y vertex
deltas, one edge-endpoint delta chain, and an edge-ID delta chain restarted at
each layer. Every chain starts from zero. Missing encoding means raw integers.
"""
import argparse
from array import array
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import sys
import tempfile


MAGIC = b'ICVW\x01\x00\x00\x00'
ARRAY_NAMES = ('vertices', 'edges', 'layerEdges')
DELTA_ENCODING = 'delta-int32-v1'


def _integer(value, name, *, minimum=None, maximum=None):
    if type(value) is not int or (minimum is not None and value < minimum) or (
            maximum is not None and value > maximum):
        raise ValueError(f'Invalid {name}.')
    return value


def _finite(value, name, *, positive=False):
    if type(value) not in (int, float) or not math.isfinite(value) or (positive and value <= 0):
        raise ValueError(f'Invalid {name}.')


def _validate_geometry(data, *, allow_no_global=False):
    if not isinstance(data, dict) or data.get('version') != 1 or type(data.get('version')) is not int:
        raise ValueError('Invalid world geometry version.')
    if not isinstance(data.get('map'), str) or not data['map']:
        raise ValueError('Invalid world geometry map.')
    for key in ('coordinateScale', 'observerHeightCm'):
        _finite(data.get(key), key, positive=True)
    _finite(data.get('defaultFloorElevationCm'), 'defaultFloorElevationCm')
    vertices, edges, layers = (data.get(key) for key in ('vertices', 'edges', 'layers'))
    if not isinstance(vertices, list) or len(vertices) % 2 or not isinstance(edges, list) or len(edges) % 2:
        raise ValueError('Invalid paired vertex or edge arrays.')
    if not isinstance(layers, list) or not layers:
        raise ValueError('World geometry needs at least one layer.')
    for value in vertices:
        _integer(value, 'quantized vertex', minimum=-(1 << 31), maximum=(1 << 31) - 1)
    for value in edges:
        _integer(value, 'edge vertex index', minimum=0, maximum=len(vertices) // 2 - 1)
        _integer(value, 'int32 edge index', maximum=(1 << 31) - 1)
    for a, b in zip(edges[::2], edges[1::2]):
        if vertices[2*a:2*a+2] == vertices[2*b:2*b+2]:
            raise ValueError('Degenerate world geometry edge.')
    previous = -math.inf
    has_global = False
    for layer in layers:
        if not isinstance(layer, dict) or not isinstance(layer.get('edges'), list):
            raise ValueError('Invalid world geometry layer.')
        elevation = layer.get('elevationCm')
        _finite(elevation, 'layer elevation')
        if elevation <= previous:
            raise ValueError('Layer elevations must be strictly increasing.')
        previous = elevation
        global_origins = layer.get('globalOrigins', True)
        if type(global_origins) is not bool:
            raise ValueError('Invalid layer origin flag.')
        has_global |= global_origins
        for value in layer['edges']:
            _integer(value, 'layer edge index', minimum=0, maximum=len(edges) // 2 - 1)
            _integer(value, 'int32 layer edge index', maximum=(1 << 31) - 1)
        if len(set(layer['edges'])) != len(layer['edges']):
            raise ValueError('Duplicate edge in world geometry layer.')
    if not has_global and not allow_no_global:
        raise ValueError('World geometry needs a global origin layer.')
    if 'menuElevationsCm' in data:
        menu = data['menuElevationsCm']
        if not isinstance(menu, list) or not menu:
            raise ValueError('Invalid elevation menu.')
        for value in menu:
            _finite(value, 'menu elevation')


def _int32_bytes(values):
    packed = array('i', values)
    if packed.itemsize != 4:
        raise ValueError('This platform does not provide four-byte signed integers.')
    if sys.byteorder != 'little':
        packed.byteswap()
    return packed.tobytes()


def _delta_values(values, stride=1):
    previous = [0] * stride
    result = array('i')
    for index, value in enumerate(values):
        axis = index % stride
        delta = value - previous[axis]
        _integer(delta, 'int32 delta; use raw encoding if this overflows',
                 minimum=-(1 << 31), maximum=(1 << 31) - 1)
        result.append(delta)
        previous[axis] = value
    return result


def _decode_deltas(values, start=0, count=None, stride=1):
    count = len(values) - start if count is None else count
    for index in range(start + stride, start + count):
        value = values[index] + values[index - stride]
        _integer(value, 'decoded int32 value', minimum=-(1 << 31), maximum=(1 << 31) - 1)
        values[index] = value


def encode_world(data, *, encoding=None, allow_no_global=False):
    """Return uncompressed ICVW1 bytes, preserving every geometry value."""
    _validate_geometry(data, allow_no_global=allow_no_global)
    if encoding not in (None, DELTA_ENCODING):
        raise ValueError('Unsupported binary encoding.')
    if 'binaryArrays' in data or 'encoding' in data:
        raise ValueError('Source JSON already contains reserved binary encoding metadata.')
    header = {k: v for k, v in data.items() if k not in ('vertices', 'edges', 'layers')}
    if encoding is not None:
        header['encoding'] = encoding
    header['layers'] = []
    layer_ids = array('i')
    for layer in data['layers']:
        if 'edgeOffset' in layer or 'edgeCount' in layer:
            raise ValueError('Source layer contains reserved binary offset metadata.')
        entry = {k: v for k, v in layer.items() if k != 'edges'}
        entry.update(edgeOffset=len(layer_ids), edgeCount=len(layer['edges']))
        header['layers'].append(entry)
        layer_ids.extend(_delta_values(layer['edges']) if encoding else layer['edges'])
    vertex_values = _delta_values(data['vertices'], stride=2) if encoding else data['vertices']
    edge_values = _delta_values(data['edges']) if encoding else data['edges']
    arrays = [_int32_bytes(vertex_values), _int32_bytes(edge_values), _int32_bytes(layer_ids)]
    offset = 0
    header['binaryArrays'] = {}
    for name, content in zip(ARRAY_NAMES, arrays):
        header['binaryArrays'][name] = {'byteOffset': offset, 'elementCount': len(content) // 4}
        offset += len(content)
    encoded_header = json.dumps(header, ensure_ascii=False, allow_nan=False,
                                sort_keys=True, separators=(',', ':')).encode('utf-8')
    if len(encoded_header) >= 1 << 32:
        raise ValueError('Binary header exceeds uint32 length.')
    prefix = MAGIC + struct.pack('<I', len(encoded_header)) + encoded_header
    padding = b'\x00' * (-len(prefix) % 4)
    return b''.join([prefix, padding, *arrays])


def _unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate binary header key.')
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValueError(f'Nonstandard JSON constant in binary header: {value}.')


def decode_world(payload, *, allow_no_global=False):
    """Reconstruct the original JSON object from uncompressed ICVW1 bytes."""
    if len(payload) < 12 or payload[:8] != MAGIC:
        raise ValueError('Invalid ICVW1 binary prefix.')
    header_length = struct.unpack_from('<I', payload, 8)[0]
    header_end = 12 + header_length
    data_start = (header_end + 3) & ~3
    if data_start > len(payload):
        raise ValueError('Truncated binary header or padding.')
    if any(payload[header_end:data_start]):
        raise ValueError('Nonzero binary alignment padding.')
    try:
        header = json.loads(payload[12:header_end].decode('utf-8'), object_pairs_hook=_unique_keys,
                            parse_constant=_invalid_constant)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError('Invalid binary JSON header.') from error
    if not isinstance(header, dict):
        raise ValueError('Binary header must be an object.')
    if 'vertices' in header or 'edges' in header:
        raise ValueError('Binary header cannot contain JSON geometry arrays.')
    encoding = header.get('encoding')
    if 'encoding' in header and encoding != DELTA_ENCODING:
        raise ValueError('Unsupported binary encoding.')
    descriptors = header.get('binaryArrays')
    if not isinstance(descriptors, dict) or set(descriptors) != set(ARRAY_NAMES):
        raise ValueError('Invalid binary array descriptors.')
    arrays, expected_offset = {}, 0
    for name in ARRAY_NAMES:
        descriptor = descriptors[name]
        if not isinstance(descriptor, dict) or set(descriptor) != {'byteOffset', 'elementCount'}:
            raise ValueError('Invalid binary array descriptor.')
        offset = _integer(descriptor['byteOffset'], 'array offset', minimum=0)
        count = _integer(descriptor['elementCount'], 'array element count', minimum=0)
        if offset != expected_offset or data_start + offset + count * 4 > len(payload):
            raise ValueError('Array is unaligned, overlapping, reordered, or truncated.')
        packed = array('i')
        if packed.itemsize != 4:
            raise ValueError('This platform does not provide four-byte signed integers.')
        packed.frombytes(payload[data_start+offset:data_start+offset+count*4])
        if sys.byteorder != 'little':
            packed.byteswap()
        arrays[name] = packed
        expected_offset += count * 4
    if data_start + expected_offset != len(payload):
        raise ValueError('Unexpected trailing binary data.')
    layers = header.get('layers')
    if not isinstance(layers, list) or not layers:
        raise ValueError('Invalid binary layers.')
    if encoding:
        _decode_deltas(arrays['vertices'], stride=2)
        _decode_deltas(arrays['edges'])
    result = {k: v for k, v in header.items() if k not in ('binaryArrays', 'layers', 'encoding')}
    result.update(vertices=arrays['vertices'].tolist(), edges=arrays['edges'].tolist(), layers=[])
    expected_offset = 0
    for layer in layers:
        if not isinstance(layer, dict) or 'edges' in layer:
            raise ValueError('Invalid binary layer metadata.')
        offset = _integer(layer.get('edgeOffset'), 'layer offset', minimum=0)
        count = _integer(layer.get('edgeCount'), 'layer edge count', minimum=0)
        if offset != expected_offset or offset + count > len(arrays['layerEdges']):
            raise ValueError('Layer edge ranges must partition layerEdges in order.')
        if encoding:
            _decode_deltas(arrays['layerEdges'], start=offset, count=count)
        entry = {k: v for k, v in layer.items() if k not in ('edgeOffset', 'edgeCount')}
        entry['edges'] = arrays['layerEdges'][offset:offset+count].tolist()
        result['layers'].append(entry)
        expected_offset += count
    if expected_offset != len(arrays['layerEdges']):
        raise ValueError('Unreferenced layer edge data.')
    _validate_geometry(result, allow_no_global=allow_no_global)
    return result


def write_binary(path, content, *, force=False):
    """Write a new asset, or atomically replace an existing task-owned asset."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not force:
        with path.open('xb') as stream:
            stream.write(content)
        return
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='wb', prefix='.' + path.name + '-', suffix='.tmp',
                                         dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, help='Existing visibility JSON or gzip JSON.')
    parser.add_argument('output', type=Path, help='Destination .bin.gz asset.')
    parser.add_argument('--compression-level', type=int, default=9, choices=range(1, 10))
    parser.add_argument('--verify', action='store_true', help='Reconstruct JSON and require exact value equality.')
    parser.add_argument('--force', action='store_true', help='Atomically replace an existing task-owned output.')
    parser.add_argument('--encoding', choices=('raw', DELTA_ENCODING), default=DELTA_ENCODING,
                        help='Lossless integer encoding; defaults to smaller delta storage.')
    args = parser.parse_args()
    source = args.input.read_bytes()
    raw = gzip.decompress(source) if source.startswith(b'\x1f\x8b') else source
    data = json.loads(raw)
    encoding = None if args.encoding == 'raw' else args.encoding
    payload = encode_world(data, encoding=encoding)
    compressed = gzip.compress(payload, compresslevel=args.compression_level, mtime=0)
    if args.verify and decode_world(gzip.decompress(compressed)) != data:
        raise ValueError('Binary round trip changed geometry or metadata.')
    write_binary(args.output, compressed, force=args.force)
    print(json.dumps({'input': str(args.input), 'output': str(args.output),
                      'inputSha256': hashlib.sha256(source).hexdigest(),
                      'outputSha256': hashlib.sha256(compressed).hexdigest(),
                      'jsonBytes': len(raw), 'binaryBytes': len(payload),
                      'inputFileBytes': len(source), 'binaryGzipBytes': len(compressed),
                      'vertices': len(data['vertices']) // 2, 'edges': len(data['edges']) // 2,
                      'layers': len(data['layers']), 'encoding': args.encoding,
                      'roundTripVerified': args.verify}))


if __name__ == '__main__':
    main()
