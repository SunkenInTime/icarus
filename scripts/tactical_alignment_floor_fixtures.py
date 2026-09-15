"""Freeze source-floor queries and their exact warped XY for runtime validation."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
from tactical_alignment_audit import projection
from tactical_alignment_candidate import Warp
from tactical_alignment_warps import load_warp


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--map', required=True)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-navigation', type=Path)
    parser.add_argument('--warp-file', type=Path)
    args = parser.parse_args()
    name = args.map
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps'][name]
    ui = catalog['uiTransform']
    project = projection(catalog, json.loads((args.audit_root / f'registration/results/{name}-registration.json').read_text()))
    origin = project(np.zeros(2))
    matrix = np.column_stack((project(np.array([1., 0])) - origin, project(np.array([0., 1])) - origin))
    inverse = np.linalg.inv(matrix)
    source = args.source_navigation or Path(f'assets/maps/world/{name}_navigation.json.gz')
    source_bytes = source.read_bytes()
    nav = json.loads(gzip.decompress(source_bytes))
    field = nav['floorMesh']
    vertices = np.array(field['vertices']).reshape(-1, 3)
    triangles = np.array(field['triangles']).reshape(-1, 4)
    triangles = triangles[::max(1, len(triangles) // 3000)]
    centers = vertices[triangles[:, 1:]].mean(1)
    uv = centers[:, :2] / field['coordinateScale']
    native = np.column_stack(((uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier']), -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])))
    warp = load_warp(args.warp_file) if args.warp_file else Warp()
    target_native = (warp.apply(project(native)) - origin) @ inverse.T
    target = np.column_stack((ui['XScalarToAdd'] - target_native[:, 1] * 100 * ui['XMultiplier'], ui['YScalarToAdd'] + target_native[:, 0] * 100 * ui['YMultiplier']))
    samples = [{'sourceUv': a.tolist(), 'candidateUv': b.tolist(), 'preferredElevationCm': float(z)} for a, b, z in zip(uv, target, centers[:, 2])]
    args.output.write_text(json.dumps({'map': name, 'sourceNavigationSha256': hashlib.sha256(source_bytes).hexdigest(), 'samples': samples}, separators=(',', ':')))
    print(len(samples))


if __name__ == '__main__':
    main()
