"""Build an isolated clamped-ramp IHD1 candidate with exact triangle cuts.

The chart is an explicit tactical flattening policy. Its local validity bounds
must accompany comparisons; this does not flatten every floor on a map.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct
import time
import numpy as np

from audit_tactical_target_rays import ReferenceModel
from experimental_floor_relative_visibility import FloorPatch, clip_face_to_patch


CHARTS = {
    'annotated-clove': dict(agent=4, plane=[-.0008666449638487635, .3341111103508276, -8.178836523857138],
                           lower=4.5, upper=6.5, validBounds=[13, 26, 27, 52]),
    'annotated-iso': dict(agent=6, plane=[-.4385308706497614, .003706211914338157, 26.444433945935856],
                         lower=2., upper=5.5, validBounds=[40, 37, 65, 52]),
    'annotated-deadlock': dict(agent=8, plane=[-.3000684310358, .00001557920549316256, 17.001552706571996],
                              lower=3.5, upper=5., validBounds=[30, 77, 53, 91]),
}


def _polygon_clip(points, plane, level, keep_lower):
    result = []
    for a, b in zip(points, points[1:] + points[:1]):
        da, db = a @ plane[:2] + plane[2] - level, b @ plane[:2] + plane[2] - level
        if not keep_lower:
            da, db = -da, -db
        if da <= 0:
            result.append(a)
        if (da > 0) != (db > 0):
            result.append(a + (b - a) * (da / (da - db)))
    return result


def build(pack, output, case):
    started = time.perf_counter()
    if output.exists():
        raise FileExistsError('Use a fresh experimental output folder.')
    chart = CHARTS[case]
    plane = np.array(chart['plane'])
    low, high = chart['lower'], chart['upper']
    source = ReferenceModel(pack)
    if low + 1.75 < source.header['heightDomainMeters'][0] or high + 1.75 > source.header['heightDomainMeters'][1]:
        raise ValueError('Chart eye heights leave the complete source pack domain.')
    points, faces = source.arrays['vertices'], source.arrays['faces']
    field = points[:, :2] @ plane[:2] + plane[2]
    flat_points = points.copy()
    flat_points[:, 2] -= np.clip(field, low, high)
    levels = np.where(field <= low, 0, np.where(field >= high, 2, 1))
    face_levels = levels[faces]
    crossing = np.flatnonzero(np.any(face_levels != face_levels[:, :1], axis=1))
    unchanged = np.flatnonzero(np.all(face_levels == face_levels[:, :1], axis=1))
    minimum, maximum = points[:, :2].min(0) - 1, points[:, :2].max(0) + 1
    box = [minimum, np.array([maximum[0], minimum[1]]), maximum, np.array([minimum[0], maximum[1]])]
    regions = [FloorPatch(np.array(_polygon_clip(box, plane, low, True)), np.array([0., 0., low])),
               FloorPatch(np.array(_polygon_clip(_polygon_clip(box, plane, low, False), plane, high, True)), plane),
               FloorPatch(np.array(_polygon_clip(box, plane, high, False)), np.array([0., 0., high]))]
    added_points, added_faces, added_source, added_weights = [], [], [], []
    maximum_inverse_error = 0.
    for source_id in crossing:
        original = points[faces[source_id]]
        for region in regions:
            pieces = clip_face_to_patch(original, region)
            for index in range(1, len(pieces) - 1):
                piece = np.array([pieces[0], pieces[index], pieces[index + 1]])
                triangle = piece[:, :3].copy()
                triangle[:, 2] -= region.height(triangle[:, :2])
                if np.linalg.norm(np.cross(triangle[1] - triangle[0], triangle[2] - triangle[0])) < 1e-13:
                    continue
                reconstructed = triangle.copy()
                reconstructed[:, 2] += region.height(triangle[:, :2])
                maximum_inverse_error = max(maximum_inverse_error, float(np.abs(reconstructed - piece[:, 3:] @ original).max()))
                offset = len(points) + len(added_points)
                added_points.extend(triangle)
                added_faces.append([offset, offset + 1, offset + 2])
                added_source.append(source_id)
                added_weights.append(piece[:, 3:])
    points = np.vstack([flat_points, np.array(added_points).reshape(-1, 3)])
    faces = np.vstack([faces[unchanged], np.array(added_faces, dtype=np.uint32).reshape(-1, 3)])
    correspondence = np.r_[unchanged, added_source].astype(np.uint32)
    source_masks = source.arrays['faceMasks'][correspondence]
    masked = np.flatnonzero(source_masks >= 0)
    masks = np.full(len(faces), -1, dtype=np.int32)
    masks[masked] = np.arange(len(masked), dtype=np.int32)
    uvs = source.arrays['maskedUvs'][source_masks[masked]].copy()
    for index in masked[masked >= len(unchanged)]:
        weights = added_weights[index - len(unchanged)]
        uvs[masks[index]] = weights @ source.arrays['maskedUvs'][source_masks[index]]
    material_ids = source.arrays['maskedMaterials'][source_masks[masked]].copy()
    print(f'{case}: {len(crossing)} crossing source faces, {len(added_faces)} cut pieces', flush=True)

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
    header.update(status='isolated-tactical-ramp-chart', arrays={}, textures=[],
                  heightDomainMeters=[1.749999, 1.750001], retainedFaces=len(faces),
                  vertices=len(points), nodes=len(nodes), maskedFaces=len(masked),
                  tacticalFloorChart=chart, sourcePackSha256=hashlib.sha256(Path(pack).read_bytes()).hexdigest(),
                  referenceEquivalence='Exact clamped floor-following transform; not straight 3D sightline equivalence.')
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
    encoded = json.dumps(header, separators=(',', ':'), allow_nan=False).encode()
    base = (8 + len(encoded) + 7) // 8 * 8
    raw = bytearray(base + offset)
    raw[:8] = struct.pack('<4sI', b'IHD1', len(encoded))
    raw[8:8 + len(encoded)] = encoded
    for at, data in payloads:
        raw[base + at:base + at + len(data)] = data
    output.mkdir(parents=True)
    target = output / 'split.height.bin.gz'
    target.write_bytes(gzip.compress(raw, compresslevel=9, mtime=0))
    native = output / 'native'
    native.mkdir()
    (native / 'height-source.raw').write_bytes(raw)
    (native / 'arrays.txt').write_text('\n'.join(f'{name} {base + item["offset"]} {item["count"]}' for name, item in header['arrays'].items()))
    (native / 'alpha-textures.txt').write_text('\n'.join(f'{index} {item["width"]} {item["height"]} {base + item["offset"]}' for index, item in enumerate(header['textures'])))
    wraps = {'repeat': 0, 'clamp': 1, 'mirror': 2, 'black': 3}
    (native / 'alpha-materials.txt').write_text('\n'.join(f'{item["material"]} {item["texture"]} {item["threshold"]:.17g} {item["alphaScale"]:.17g} {item["alphaBias"]:.17g} {wraps[item["wrapS"]]} {wraps[item["wrapT"]]}' for item in header['materials']))
    (native / 'parameters.txt').write_text('1.749999 1.750001')
    np.savez_compressed(output / 'correspondence.npz', sourceFaces=correspondence[order],
                        addedSourceFaces=np.asarray(added_source), addedBarycentrics=np.asarray(added_weights))
    report = dict(case=case, chart=chart, sourceFaces=len(source.arrays['faces']), retainedFaces=len(faces),
                  crossingSourceFaces=len(crossing), cutPieces=len(added_faces), sourceCoverage=len(np.unique(correspondence)),
                  maximumInverseCoordinateErrorMeters=maximum_inverse_error, rawBytes=len(raw), compressedBytes=target.stat().st_size,
                  seconds=time.perf_counter() - started, packSha256=hashlib.sha256(target.read_bytes()).hexdigest(),
                  sourcePackSha256=header['sourcePackSha256'],
                  scope='Only local ramp chart semantics. Other map regions are not certified by extrapolation.')
    (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pack', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--case', choices=CHARTS, required=True)
    args = parser.parse_args()
    build(args.pack, args.output, args.case)
