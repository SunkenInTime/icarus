"""Export reviewed registration fields as display meshes, leaving native data intact."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

import numpy as np
import shapely

from tactical_alignment_audit import projection
from tactical_alignment_warps import load_warp


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def area2(cells):
    a, b = cells[:, 1] - cells[:, 0], cells[:, 2] - cells[:, 0]
    return a[:, 0] * b[:, 1] - a[:, 1] * b[:, 0]


def export_map(row, root, output, catalog):
    name = row['map']
    proof_path = Path(row['proof'])
    proof = json.loads(proof_path.read_text())
    warp_path = Path(proof['controlConstraints']['path'])
    if sha(warp_path) != proof['controlConstraints']['sha256']:
        raise ValueError(f'{name}: reviewed registration changed')
    sides_path = root / f'tactical-alignment-sides-v1/{name}.json'
    sides = json.loads(sides_path.read_text())
    registration_path = root / f'registration/results/{name}-registration.json'
    project = projection(catalog[name], json.loads(registration_path.read_text()))
    origin = project(np.zeros(2))
    matrix = np.column_stack([project(np.array(v)) - origin for v in [[1, 0], [0, 1]]])
    affine = np.column_stack([matrix, origin])
    if not np.allclose(affine, sides['nativeToAttackSvg'], atol=1e-10, rtol=0):
        raise ValueError(f'{name}: side and registration transforms disagree')
    warp = load_warp(warp_path)
    source = warp.points
    target = source + warp.delta
    triangles = warp.tri.simplices
    source_native = (source - origin) @ np.linalg.inv(matrix).T
    source_cells, target_cells = source[triangles], target[triangles]
    jacobian = area2(target_cells) / area2(source_cells)
    source_edges = np.stack((source_cells[:, 0] - source_cells[:, 2], source_cells[:, 1] - source_cells[:, 2]), axis=2)
    target_edges = np.stack((target_cells[:, 0] - target_cells[:, 2], target_cells[:, 1] - target_cells[:, 2]), axis=2)
    stretches = np.linalg.svd(target_edges @ np.linalg.inv(source_edges), compute_uv=False)
    if not np.all(np.isfinite(jacobian)) or np.min(jacobian) <= 0:
        raise ValueError(f'{name}: folded or degenerate display field')
    source_union = shapely.union_all(shapely.polygons(source_cells))
    target_union = shapely.union_all(shapely.polygons(target_cells))
    # A continuous field with a fixed outer boundary extends by identity.
    boundary = source_union.boundary
    boundary_ids = shapely.distance(shapely.points(source), boundary) < 1e-9
    boundary_shift = np.linalg.norm(warp.delta[boundary_ids], axis=1).max(initial=0)
    if boundary_shift != 0 or source_union.symmetric_difference(target_union).area > 1e-7:
        raise ValueError(f'{name}: field boundary is not fixed')
    overlap = float(np.abs(area2(target_cells)).sum() / 2 - target_union.area)
    if abs(overlap) > 1e-7:
        raise ValueError(f'{name}: target cells overlap')
    boxes, art = {}, {}
    for side, suffix in [('attack', ''), ('defense', '_defense')]:
        path = Path(f'assets/maps/{name}_map{suffix}.svg')
        art[side] = {'file': path.as_posix(), 'sha256': sha(path)}
        if art[side]['sha256'] != sides[f'{side}Sha256']:
            raise ValueError(f'{name}: {side} art changed after side registration')
        boxes[side] = [float(v) for v in ET.parse(path).getroot().get('viewBox').split()]
        if boxes[side] != sides[f'{side}ViewBox']:
            raise ValueError(f'{name}: {side} viewBox changed')
    box = np.array(boxes['attack'])
    defense_translation = box[:2] * 2 + box[2:] + np.array(sides['defenseDeltaAfterReflectionSvg'])
    ab = boxes['attack']
    db = boxes['defense']
    attack_box = shapely.box(ab[0], ab[1], ab[0] + ab[2], ab[1] + ab[3])
    defense_canonical_box = shapely.box(*(defense_translation - np.array(db[:2]) - np.array(db[2:])),
                                          *(defense_translation - np.array(db[:2])))
    uncovered = {side: float(shape.difference(target_union).area)
                 for side, shape in [('attack', attack_box), ('defense', defense_canonical_box)]}
    if max(uncovered.values()) != 0:
        raise ValueError(f'{name}: display mesh does not cover both full receiver viewBoxes: {uncovered}')
    # Exact double JSON is the CPU inverse/query domain. GPU positions are float32.
    target32 = target.astype(np.float32).astype(np.float64)
    source32 = source.astype(np.float32).astype(np.float64)
    f32_area = area2(target32[triangles])
    flip = f32_area * area2(target_cells) < 0
    collapse = f32_area == 0
    float_proof = {
        'maximumTargetPositionErrorSvg': float(np.linalg.norm(target32 - target, axis=1).max()),
        'maximumSourceTextureCoordinateErrorSvg': float(np.linalg.norm(source32 - source, axis=1).max()),
        'collapsedTargetCells': int(collapse.sum()),
        'flippedTargetCells': int(flip.sum()),
        'collapsedOrFlippedOriginalAreaSvg2': float(np.abs(area2(target_cells)[collapse | flip]).sum() / 2),
    }
    if float_proof['flippedTargetCells']:
        raise ValueError(f'{name}: float32 GPU coordinates flip cells')
    record = {
        'format': 'icarus-display-warp-v1', 'version': 1, 'map': name,
        'sourceNativeMeters': source_native.ravel().tolist(),
        'targetAttackSvg': target.ravel().tolist(),
        'triangles': triangles.ravel().tolist(),
        'projection': {'origin': origin.tolist(), 'axisU': matrix[:, 0].tolist(), 'axisV': matrix[:, 1].tolist()},
        'attackViewBox': boxes['attack'], 'defenseViewBox': boxes['defense'],
        'attackToDefenseSvg': {'axisU': [-1.0, 0.0], 'axisV': [0.0, -1.0], 'origin': defense_translation.tolist()},
        'outsideMesh': 'identity-in-source-svg',
        'maximumStretch': float(stretches.max()),
        'outerHullMaximumDisplacementSvg': float(boundary_shift),
        'sourceGeometrySha256': catalog[name]['sourceGeometrySha256'],
        'art': art,
        'provenance': {'warpSha256': sha(warp_path), 'compositionProofSha256': sha(proof_path),
                       'sideRegistrationSha256': sha(sides_path), 'registrationSha256': sha(registration_path),
                       'controlGeometryPackSha256': proof['candidatePackSha256'],
                       'unwarpedControlSourcePackSha256': proof['sourcePackSha256']},
    }
    # JSON round-trip is exact for binary64. The exported CPU geometry has no quantization.
    encoded = json.dumps(record, separators=(',', ':'), allow_nan=False).encode()
    restored = json.loads(encoded)
    if not np.array_equal(np.array(restored['sourceNativeMeters']).reshape(-1, 2), source_native):
        raise ValueError('Native coordinates changed during serialization')
    if not np.array_equal(np.array(restored['targetAttackSvg']).reshape(-1, 2), target):
        raise ValueError('Target coordinates changed during serialization')
    restored_source = project(source_native)
    source_error = float(np.linalg.norm(restored_source - source, axis=1).max())
    if source_error > 1e-9:
        raise ValueError('Native affine round-trip exceeds tolerance')
    packed = gzip.compress(encoded, compresslevel=9, mtime=0)
    filename = f'{name}.display-warp.json.gz'
    (output / filename).write_bytes(packed)
    validation = {
        'map': name, 'file': filename, 'sha256': hashlib.sha256(packed).hexdigest(),
        'bytes': len(packed), 'rawBytes': len(encoded), 'vertices': len(source), 'triangles': len(triangles),
        'minimumJacobian': float(jacobian.min()), 'maximumJacobian': float(jacobian.max()),
        'minimumStretch': float(stretches.min()), 'maximumStretch': float(stretches.max()),
        'boundaryMaximumDisplacementSvg': float(boundary_shift),
        'targetCellOverlapAreaSvg2': overlap, 'uncoveredFullViewBoxAreaSvg2': uncovered,
        'maximumNativeProjectionRoundTripErrorSvg': source_error,
        'float32GpuProof': float_proof, 'acceptedForGameplay': False,
        'sourceGeometrySha256': catalog[name]['sourceGeometrySha256'],
        'art': art, 'provenance': record['provenance'],
    }
    (output / f'{name}.proof.json').write_text(json.dumps(validation, indent=2))
    return validation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']
    records = []
    for row in json.loads(args.inventory.read_text())['maps']:
        record = export_map(row, args.root, args.output, catalog)
        records.append(record)
        print(record['map'], record['bytes'], record['vertices'], record['triangles'], flush=True)
        (args.output / 'manifest.json').write_text(json.dumps({
            'format': 'icarus-display-warp-staging-v1', 'maps': records,
            'note': 'Display-only fields. Native query geometry, path costs and metric ranges must stay unwarped. No production assets promoted.'}, indent=2))


if __name__ == '__main__':
    main()
