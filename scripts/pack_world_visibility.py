"""Pack exact offline planes into independently decodable, bounded-size blocks.

Accepts a plane-cache-v1 manifest or a legacy monolithic JSON gzip. Shared
vertex/edge tables are local to each block, so memory use does not grow with
the number of standing heights. Coordinates and layer membership are exact.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import time

from prepare_world_visibility import prepare
from order_world_visibility_tables import order_tables
from seal_world_plane_manifest import digest, seal_path, verify_plane_seal
from world_visibility_binary import DELTA_ENCODING, decode_world, encode_world, write_binary


def read_json(path):
    content = Path(path).read_bytes()
    return json.loads(gzip.decompress(content) if content[:2] == b'\x1f\x8b' else content)


def navigation_asset(path):
    """Retain source package identity without shipping local audit paths."""
    data = read_json(path)
    for record in data.get('source', {}).get('files', []):
        source_path = record.get('path', '').replace('\\', '/')
        marker = 'ShooterGame/Content/'
        if marker in source_path:
            record['path'] = '/Game/' + source_path.split(marker, 1)[1].removesuffix('.json')
        elif source_path.startswith('/Game/'):
            record['path'] = source_path
        else:
            raise ValueError('Navigation source needs an identifiable game package.')
    return gzip.compress(json.dumps(data, separators=(',', ':'), allow_nan=False).encode(), compresslevel=9, mtime=0)


def layer_segments(data, layer):
    if data.get('format') == 'plane-cache-v1':
        return read_json(layer['cacheFile'])['segments']
    vertices, edges = data['vertices'], data['edges']
    return [[vertices[2 * edges[2 * i]:2 * edges[2 * i] + 2],
             vertices[2 * edges[2 * i + 1]:2 * edges[2 * i + 1] + 2]] for i in layer['edges']]


def make_chunk(data, layers):
    chunk = {key: value for key, value in data.items()
             if key not in ('format', 'vertices', 'edges', 'layers', 'menuElevationsCm', 'spatialOrder')}
    chunk.update(vertices=[], edges=[], layers=[])
    vertex_ids, edge_ids = {}, {}
    for layer in layers:
        ids = []
        for a, b in layer_segments(data, layer):
            key = tuple(sorted((tuple(a), tuple(b))))
            if key not in edge_ids:
                endpoints = []
                for point in key:
                    if point not in vertex_ids:
                        vertex_ids[point] = len(vertex_ids)
                        chunk['vertices'].extend(point)
                    endpoints.append(vertex_ids[point])
                edge_ids[key] = len(edge_ids)
                chunk['edges'].extend(endpoints)
            ids.append(edge_ids[key])
        if len(set(ids)) != len(ids):
            raise ValueError('Duplicate undirected edge in a source plane.')
        chunk['layers'].append({'elevationCm': layer['elevationCm'],
                                'globalOrigins': layer.get('globalOrigins', True), 'edges': ids})
    return order_tables(prepare(chunk))


def pack(source, output, layers_per_chunk=4, *, maximum_block_bytes=2 * 1024 * 1024, force=False):
    if not 1 <= layers_per_chunk <= 64:
        raise ValueError('Use between 1 and 64 layers per block.')
    if maximum_block_bytes <= 0:
        raise ValueError('The raw block budget must be positive.')
    started = time.perf_counter()
    source, output = Path(source), Path(output)
    data = read_json(source)
    if data.get('format') == 'plane-cache-v1':
        verify_plane_seal(source)
        data['source'] = {**data['source'], 'planeSealSha256': digest(seal_path(source))}
    elevations = [layer['elevationCm'] for layer in data['layers']]
    if not elevations or any(a >= b for a, b in zip(elevations, elevations[1:])):
        raise ValueError('Source elevations must be nonempty and strictly increasing.')
    if not any(layer.get('globalOrigins', True) for layer in data['layers']):
        raise ValueError('The full map requires a global origin layer.')
    manifest = {key: value for key, value in data.items()
                if key not in ('format', 'vertices', 'edges', 'layers')}
    manifest.update(format='chunked-v1', spatialOrder='bvh-median-v1', layers=[], chunks=[])
    output.mkdir(parents=True, exist_ok=True)
    total_raw, total_compressed, maximum_raw = 0, 0, 0
    pending_groups = [data['layers'][start:start + layers_per_chunk]
                      for start in range(0, len(data['layers']), layers_per_chunk)]
    while pending_groups:
        index = len(manifest['chunks'])
        selected = pending_groups.pop(0)
        chunk = make_chunk(data, selected)
        raw = encode_world(chunk, encoding=DELTA_ENCODING, allow_no_global=True)
        if len(raw) > maximum_block_bytes and len(selected) > 1:
            middle = len(selected) // 2
            pending_groups[:0] = [selected[:middle], selected[middle:]]
            continue
        if decode_world(raw, allow_no_global=True) != chunk:
            raise ValueError('Binary round trip changed geometry.')
        compressed = gzip.compress(raw, compresslevel=9, mtime=0)
        name = f'{data["map"]}_visibility_{index:03d}.bin.gz'
        write_binary(output / name, compressed, force=force)
        manifest['chunks'].append({'asset': name, 'sha256': hashlib.sha256(compressed).hexdigest(),
                                   'compressedBytes': len(compressed), 'uncompressedBytes': len(raw)})
        for local_index, layer in enumerate(selected):
            manifest['layers'].append({'elevationCm': layer['elevationCm'],
                                       'globalOrigins': layer.get('globalOrigins', True),
                                       'chunkIndex': index, 'localLayerIndex': local_index})
        total_raw += len(raw)
        total_compressed += len(compressed)
        maximum_raw = max(maximum_raw, len(raw))
    navigation = source.with_name(data['map'] + '_navigation.json.gz')
    if data.get('format') == 'plane-cache-v1' and not navigation.is_file():
        raise ValueError('A completed plane manifest requires its sealed navigation asset.')
    if navigation.exists():
        navigation_bytes = navigation_asset(navigation)
        write_binary(output / navigation.name, navigation_bytes, force=force)
        manifest['navigationAsset'] = {'asset': navigation.name,
                                       'sha256': hashlib.sha256(navigation_bytes).hexdigest(),
                                       'compressedBytes': len(navigation_bytes)}
    if data.get('format') == 'plane-cache-v1':
        verify_plane_seal(source)
    encoded = json.dumps(manifest, separators=(',', ':'), allow_nan=False).encode()
    write_binary(output / f'{data["map"]}_visibility.manifest.json', encoded, force=force)
    result = {'map': data['map'], 'layers': len(elevations), 'chunks': len(manifest['chunks']),
              'compressedBytes': total_compressed, 'uncompressedBytes': total_raw,
              'maximumBlockBytes': maximum_raw, 'seconds': time.perf_counter() - started}
    print(json.dumps(result), flush=True)
    return manifest, result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--layers-per-chunk', type=int, default=4)
    parser.add_argument('--maximum-block-bytes', type=int, default=2 * 1024 * 1024)
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    pack(args.source, args.output, args.layers_per_chunk,
         maximum_block_bytes=args.maximum_block_bytes, force=args.force)
