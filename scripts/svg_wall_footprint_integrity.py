"""Reject wall fragments that have no area on the source-overlay grid."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import shapely

from compile_reviewed_svg_height_map import polygon

GRID_SVG = 1e-8


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_sha(path):
    return hashlib.sha256(Path(path).read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def collapsed_wall(wall):
    shape = polygon(wall)
    return shape.area <= 1e-7 and shapely.set_precision(shape, GRID_SVG).area == 0


def remove_collapsed_walls(walls):
    retained, removed = [], []
    for wall in walls:
        if collapsed_wall(wall):
            shape = polygon(wall)
            removed.append(dict(wallId=wall['id'], areaSvg=float(shape.area),
                                boundsSvg=list(shape.bounds), reason='no-area-on-source-overlay-grid'))
        else:
            retained.append(wall)
    return retained, removed


def certify(asset_dir, output):
    paths = sorted(asset_dir.glob('*_svg_height_*.json.gz'))
    if len(paths) != 26:
        raise ValueError(f'Expected all 26 map sides; found {len(paths)}')
    assets = {}
    for path in paths:
        model = json.loads(gzip.decompress(path.read_bytes()))
        _, bad = remove_collapsed_walls(model['walls'])
        if bad:
            raise ValueError((str(path), 'Collapsed blocking footprints', bad))
        assets[str(path).replace('\\', '/')] = dict(sha256=sha(path), wallCount=len(model['walls']))
    certificate = dict(version=1, gridSvg=GRID_SVG, status='passed',
                       algorithmSha256=source_sha(Path(__file__)),
                       polygonReaderSha256=source_sha(Path(__file__).with_name('compile_reviewed_svg_height_map.py')),
                       assets=assets)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(certificate, indent=2) + '\n')
    print(json.dumps(dict(status='passed', assetCount=len(assets))), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--asset-dir', type=Path, default=Path('assets/maps'))
    parser.add_argument('--certificate', type=Path,
                        default=Path('scripts/data/svg-wall-footprint-certificate.json'))
    args = parser.parse_args()
    certify(args.asset_dir, args.certificate)
