"""Freeze identical source-parent route endpoints before and after exact XY W."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
from tactical_alignment_audit import projection
from tactical_alignment_warps import load_warp


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline-directory', type=Path, default=Path('assets/maps/world'))
    args = parser.parse_args()
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']
    rows = []
    rng = np.random.default_rng(314159)
    for row in json.loads(args.inventory.read_text())['maps']:
        name = row['map']
        source_path = (args.baseline_directory / f'{name}_navigation.json.gz').resolve()
        source_bytes = source_path.read_bytes()
        nav = json.loads(gzip.decompress(source_bytes))
        vertices = np.array(nav['vertices']).reshape(-1, 3)
        refined = np.array(nav['refinedFloorHeightsCm'], dtype=float)
        vertices[:, 2] = np.where(np.isnan(refined), vertices[:, 2], refined)
        centers = np.array([vertices[ids].mean(0) for ids in nav['polygons']])
        uv = centers[:, :2] / nav['coordinateScale']
        components = np.array(nav['components'])
        walkable = np.array(nav['walkable'])
        labels, counts = np.unique(components[walkable], return_counts=True)
        main_ids = np.flatnonzero(walkable & (components == labels[counts.argmax()]))
        other_ids = np.flatnonzero(walkable & (components != labels[counts.argmax()]))
        metadata = catalog[name]
        ui = metadata['uiTransform']
        project = projection(metadata, json.loads((args.audit_root / f'registration/results/{name}-registration.json').read_text()))
        origin = project(np.zeros(2))
        matrix = np.column_stack([project(np.array(x)) - origin for x in [[1, 0], [0, 1]]])
        native = np.column_stack(((uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier']),
                                  -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])))
        proof = json.loads(Path(row['proof']).read_text())
        warp = load_warp(Path(proof['controlConstraints']['path']))
        mapped = (warp.apply(project(native)) - origin) @ np.linalg.inv(matrix).T
        target = np.column_stack((ui['XScalarToAdd'] - mapped[:, 1] * 100 * ui['XMultiplier'],
                                   ui['YScalarToAdd'] + mapped[:, 0] * 100 * ui['YMultiplier']))
        pairs = rng.choice(main_ids, (350, 2)).tolist()
        pairs += [[int(a), int(a)] for a in rng.choice(main_ids, 20)]
        if len(other_ids):
            pairs += [[int(rng.choice(main_ids)), int(rng.choice(other_ids))] for _ in range(20)]
        def endpoint(parent):
            return {'parent': parent, 'component': int(components[parent]),
                    'sourceUv': uv[parent].tolist(), 'candidateUv': target[parent].tolist(),
                    'preferredFloorCm': float(centers[parent, 2])}
        rows.append({'map': name, 'baseline': str(source_path), 'candidate': row['navigation'],
                     'baselineSha256': hashlib.sha256(source_bytes).hexdigest(),
                     'candidateSha256': hashlib.sha256(Path(row['navigation']).read_bytes()).hexdigest(),
                     'pairs': [[endpoint(a), endpoint(b)] for a, b in pairs], 'warmupPairs': 50})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({'maps': rows}, separators=(',', ':')))


if __name__ == '__main__':
    main()
