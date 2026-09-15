"""Build navigation independently so chart metadata and runtime checks can iterate."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
from tactical_alignment_audit import projection
from tactical_alignment_navigation import warp_navigation
from tactical_alignment_warps import load_warp


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--map', required=True)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--warp-file', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--chart-selector', type=Path)
    parser.add_argument('--local-only', action='store_true', default=True)
    parser.add_argument('--full-grid', dest='local_only', action='store_false',
                        help='Diagnostic legacy mode; subdivides identity regions too')
    args = parser.parse_args()
    if args.output.exists(): raise FileExistsError(args.output)
    name = args.map
    source_bytes = Path(f'assets/maps/world/{name}_navigation.json.gz').read_bytes()
    nav = json.loads(gzip.decompress(source_bytes))
    if args.chart_selector:
        selector = json.loads(args.chart_selector.read_text())
        if selector['map'] != name: raise ValueError('Wrong chart selector map')
        nav['tacticalGroundChartIds'] = selector['parentVariants']
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps'][name]
    ui = catalog['uiTransform']
    project = projection(catalog, json.loads((args.audit_root / f'registration/results/{name}-registration.json').read_text()))
    origin = project(np.zeros(2))
    matrix = np.column_stack((project(np.array([1., 0])) - origin, project(np.array([0., 1])) - origin))
    inverse = np.linalg.inv(matrix)
    def uv_to_svg(uv):
        xy = np.column_stack(((uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier']), -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])))
        return project(xy)
    def svg_to_uv(svg):
        xy = (svg - origin) @ inverse.T
        return np.column_stack((ui['XScalarToAdd'] - xy[:, 1] * 100 * ui['XMultiplier'], ui['YScalarToAdd'] + xy[:, 0] * 100 * ui['YMultiplier']))
    nav, proof = warp_navigation(nav, uv_to_svg, svg_to_uv, load_warp(args.warp_file), local_only=args.local_only)
    encoded = gzip.compress(json.dumps(nav, separators=(',', ':')).encode(), compresslevel=9, mtime=0)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(encoded)
    proof.update({'sourceNavigationSha256': hashlib.sha256(source_bytes).hexdigest(),
                  'candidateNavigationSha256': hashlib.sha256(encoded).hexdigest()})
    args.output.with_suffix('.proof.json').write_text(json.dumps(proof, indent=2))
    print(json.dumps(proof, indent=2))


if __name__ == '__main__':
    main()
