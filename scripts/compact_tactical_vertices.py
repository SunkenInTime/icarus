"""Remove only bit-identical duplicate/unused vertices without changing ray geometry."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct

import numpy as np
from tactical_alignment_audit import pack
from tactical_alignment_cells import encode


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pack', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    compressed_source = args.pack.read_bytes()
    source_raw = gzip.decompress(compressed_source)
    header, arrays = pack(args.pack)
    used, face_to_used = np.unique(arrays['faces'], return_inverse=True)
    vertices = np.ascontiguousarray(arrays['vertices'][used])
    # Byte comparison keeps signed zero and any other distinct float bit pattern.
    _, first, inverse = np.unique(vertices.view(np.dtype((np.void, 24))).reshape(-1),
                                  return_index=True, return_inverse=True)
    ordered = np.argsort(first)
    rank = np.empty_like(ordered)
    rank[ordered] = np.arange(len(ordered))
    compact_vertices = vertices[first[ordered]]
    compact_faces = rank[inverse[face_to_used]].reshape(arrays['faces'].shape).astype(np.uint32)
    for start in range(0, len(compact_faces), 100000):
        after = compact_vertices[compact_faces[start:start + 100000]].view(np.uint64)
        before = arrays['vertices'][arrays['faces'][start:start + 100000]].view(np.uint64)
        if not np.array_equal(after, before):
            raise ValueError('Compaction changed a face vertex')
    changed = {**arrays, 'vertices': compact_vertices, 'faces': compact_faces}
    header['losslessVertexCompactionSourcePackSha256'] = sha(compressed_source)
    raw, compressed = encode(header, changed, source_raw)
    output = args.output / args.pack.name
    output.write_bytes(compressed)
    checked_header, checked = pack(output)
    for key in arrays:
        if key not in ['vertices', 'faces'] and checked[key].tobytes() != arrays[key].tobytes():
            raise ValueError(f'Compaction changed {key}')
    source_size = struct.unpack_from('<I', source_raw, 4)[0]
    source_base = (8 + source_size + 7) // 8 * 8
    target_size = struct.unpack_from('<I', raw, 4)[0]
    target_base = (8 + target_size + 7) // 8 * 8
    for before, after in zip(header['textures'], checked_header['textures']):
        count = before['width'] * before['height']
        if source_raw[source_base + before['offset']:source_base + before['offset'] + count] != raw[target_base + after['offset']:target_base + after['offset'] + count]:
            raise ValueError('Compaction changed an alpha texture')
    report = {'sourcePackSha256': sha(compressed_source), 'candidatePackSha256': sha(compressed),
              'sourceVertices': len(arrays['vertices']), 'candidateVertices': len(compact_vertices),
              'sourceCompressedBytes': len(compressed_source), 'candidateCompressedBytes': len(compressed),
              'sourceRawBytes': len(source_raw), 'candidateRawBytes': len(raw),
              'faceOrderPreserved': True, 'everyFaceVertexBitIdentical': True,
              'maskedUvMaterialArraysUnchanged': True, 'alphaTexturesUnchanged': True,
              'bvhArraysUnchanged': True, 'adopted': False}
    (args.output / 'proof.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
