"""IHD1 experimental writer; source face and alpha correspondence are retained."""
import gzip
import hashlib
import json
from pathlib import Path
import struct
import numpy as np

def write_pack(source, pack, output, points, faces, masks, uvs, material_ids, correspondence, field_hash, height_domain, proof, header_overrides=None, fragment_proof=None):
    # Shared cut endpoints and original vertices are bit-identical in many
    # neighboring faces. Compact exact duplicates without quantization.
    used, remapped = np.unique(faces, return_inverse=True)
    compact, inverse = np.unique(points[used], axis=0, return_inverse=True)
    faces = inverse[remapped].reshape(-1, 3)
    points = compact
    masked = np.flatnonzero(masks >= 0)
    triangles = points[faces]
    lower, upper = triangles.min(1), triangles.max(1)
    centers = (lower + upper) * .5
    order = np.arange(len(faces), dtype=np.uint32)
    bounds, nodes = [], []
    def partition(start, end):
        node = len(nodes)
        nodes.append(None)
        ids = order[start:end]
        minimum, maximum = lower[ids].min(0), upper[ids].max(0)
        bounds.append([*minimum, *maximum])
        if end - start <= 16:
            nodes[node] = [start, end - start, -1, -1]
        else:
            axis, half = int(np.argmax(maximum - minimum)), len(ids) // 2
            order[start:end] = ids[np.argpartition(centers[ids, axis], half)]
            left, right = partition(start, start + half), partition(start + half, end)
            nodes[node] = [0, 0, left, right]
        return node
    partition(0, len(faces))
    arrays = {'vertices': points.astype('<f8'), 'faces': faces[order].astype('<u4'),
              'bounds': np.asarray(bounds, dtype='<f8'), 'nodes': np.asarray(nodes, dtype='<i4'),
              'faceMasks': masks[order].astype('<i4'), 'maskedUvs': uvs.astype('<f8'),
              'maskedMaterials': material_ids.astype('<u4')}
    header = dict(source.header)
    header.update(status='experimental-global-tactical-ground', arrays={}, textures=[],
                  heightDomainMeters=height_domain, retainedFaces=len(faces),
                  vertices=len(points), nodes=len(nodes), maskedFaces=len(masked),
                  coordinatePolicy='tactical-floor-relative-v1', tacticalGroundFieldSha256=field_hash, sourcePackSha256=hashlib.sha256(Path(pack).read_bytes()).hexdigest(),
                  referenceEquivalence='Source geometry and alpha attributes preserved under the declared continuous tactical transform; gameplay equivalence is not claimed.')
    header['tacticalTransformProof'] = proof
    header['tacticalTransformProof']['fullHeightSourceInput'] = source.header.get('heightDomainProof', {}).get('format') == 'icarus-full-height-tactical-input-v1'
    payloads, offset = [], 0
    for name, values in arrays.items():
        offset = (offset + 7) // 8 * 8
        header['arrays'][name] = dict(offset=offset, count=values.size, shape=list(values.shape), dtype=str(values.dtype))
        payloads.append((offset, values.tobytes()))
        offset += values.nbytes
    # Recover texture bytes directly, avoiding normalization/requantization.
    original_length = struct.unpack_from('<I', source.raw, 4)[0]
    original_base = (8 + original_length + 7) // 8 * 8
    for texture in source.header['textures']:
        count = texture['width'] * texture['height']
        data = source.raw[original_base + texture['offset']:original_base + texture['offset'] + count]
        header['textures'].append(dict(offset=offset, width=texture['width'], height=texture['height']))
        payloads.append((offset, data))
        offset += count
    if header_overrides:
        header.update(header_overrides)
    encoded = json.dumps(header, separators=(',', ':'), allow_nan=False).encode()
    base = (8 + len(encoded) + 7) // 8 * 8
    raw = bytearray(base + offset)
    raw[:8] = struct.pack('<4sI', b'IHD1', len(encoded))
    raw[8:8 + len(encoded)] = encoded
    for at, data in payloads:
        raw[base + at:base + at + len(data)] = data
    output.mkdir(parents=True, exist_ok=True)
    target = output / (header['map'] + '.height.bin.gz')
    target.write_bytes(gzip.compress(raw, compresslevel=9, mtime=0))
    native = output / 'native'
    native.mkdir()
    (native / 'height-source.raw').write_bytes(raw)
    (native / 'arrays.txt').write_text('\n'.join(f'{name} {base + item["offset"]} {item["count"]}' for name, item in header['arrays'].items()))
    (native / 'alpha-textures.txt').write_text('\n'.join(f'{index} {item["width"]} {item["height"]} {base + item["offset"]}' for index, item in enumerate(header['textures'])))
    wraps = {'repeat': 0, 'clamp': 1, 'mirror': 2, 'black': 3}
    (native / 'alpha-materials.txt').write_text('\n'.join(f'{item["material"]} {item["texture"]} {item["threshold"]:.17g} {item["alphaScale"]:.17g} {item["alphaBias"]:.17g} {wraps[item["wrapS"]]} {wraps[item["wrapT"]]}' for item in header['materials']))
    (native / 'parameters.txt').write_text(' '.join(format(x, '.17g') for x in height_domain))
    np.savez_compressed(output / 'correspondence.npz', sourceFaces=correspondence[order],
                        addedSourceFaces=np.asarray([], dtype=np.uint32), addedBarycentrics=np.asarray([]))
    if fragment_proof is not None:
        inverse_order = np.empty(len(order), dtype=np.int64)
        inverse_order[order] = np.arange(len(order))
        generated = inverse_order[fragment_proof['inputFaceIds']]
        proof_order = np.argsort(generated)
        saved = dict(generatedFaceIds=generated[proof_order],
                     generatedBarycentrics=fragment_proof['barycentrics'][proof_order],
                     generatedEdges=fragment_proof['edges'][proof_order])
        if 'warpCells' in fragment_proof:
            saved['generatedWarpCells'] = fragment_proof['warpCells'][proof_order]
        if 'regionCells' in fragment_proof:
            saved['generatedRegionCells'] = fragment_proof['regionCells'][proof_order]
        for key in ['discardedSourceFaces','discardedBarycentrics','discardedEdges','discardedRegionCells']:
            if key in fragment_proof:
                saved[key] = fragment_proof[key]
        np.savez_compressed(output / 'normalized-face-provenance.npz', **saved)
    return dict(rawBytes=len(raw), compressedBytes=target.stat().st_size, packSha256=hashlib.sha256(target.read_bytes()).hexdigest(), retainedFaces=len(faces), vertices=len(points))
