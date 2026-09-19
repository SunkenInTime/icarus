"""Apply Dara's ruling that Haven's C Garage window is see-through from the floor.

See scripts/data/haven-garage-window-review-2026-09-19.json. Two regions,
authored in attack SVG space and mirrored to defense through the alignment:
the window wall itself, whose bands are cut away up to the header so a
standing eye on the garage floor looks through; and the crate frame drawn
under it, whose tops are capped just under that eye. A wall piece that
only partly overlaps a region is split at the region edge so the ruling
does not leak along the rest of the stroke; the ink union is unchanged.
"""
import argparse
import gzip
import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import shapely

from compile_reviewed_svg_height_map import polygon, rings

REVIEW = Path('scripts/data/haven-garage-window-review-2026-09-19.json')
ALIGN = Path('E:/IcarusWorldAudit/2026-09-06/tactical-alignment-sides-v1/haven.json')


def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))


def mirror(box, side, alignment):
    shape = shapely.box(*box)
    if side == 'attack':
        return shape
    a = np.array(alignment['nativeToAttackSvg']); d = np.array(alignment['nativeToDefenseSvg'])
    inv = np.linalg.inv(a[:, :2])
    pts = [d[:, :2] @ (inv @ (np.array(p) - a[:, 2])) + d[:, 2] for p in shape.exterior.coords]
    return shapely.Polygon(pts)


def window_bands(wall, review):
    header = review['headerMeters'] - wall['floorElevationMeters']
    return [[b[0], b[1]] for b in wall['bands'] if b[1] is None or b[1] > header] and \
        [[max(b[0], header), b[1]] for b in wall['bands'] if b[1] is None or b[1] > header]


def crate_bands(wall, review):
    cap = review['standingEyeMeters'] - review['clearanceMeters'] - wall['floorElevationMeters']
    out = []
    for b in wall['bands']:
        if b[0] < cap:
            top = cap if b[1] is None or b[1] > cap else b[1]
            if top > b[0]:
                out.append([b[0], top])
        elif b[0] >= review['headerMeters'] - wall['floorElevationMeters']:
            out.append([b[0], b[1]])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets', type=Path, default=Path('assets/maps'))
    ap.add_argument('--out', type=Path, default=Path('work/garage-window/candidate'))
    ap.add_argument('--install', action='store_true')
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    review = json.loads(REVIEW.read_text()); alignment = json.loads(ALIGN.read_text())
    log = []
    for side in ('attack', 'defense'):
        name = f'haven_svg_height_{side}.json.gz'
        model = read(a.assets / name)
        regions = {k: mirror(v, side, alignment) for k, v in review['attackRegions'].items()}
        rewrite = {'windowWall': window_bands, 'crateFrame': crate_bands}
        walls = []
        for w in model['walls']:
            shape = polygon(w)
            placed = False
            for key, region in regions.items():
                inter = shape.intersection(region)
                # A side wall's corner that pokes into the region is not the window.
                if inter.is_empty or inter.area < 0.5 * shape.area:
                    continue
                inside = [p for p in shapely.get_parts(inter) if p.geom_type == 'Polygon' and p.area > 1e-9]
                outside = [p for p in shapely.get_parts(shape.difference(region)) if p.geom_type == 'Polygon' and p.area > 1e-9]
                if inter.area >= 0.98 * shape.area:
                    before = w['bands']; w['bands'] = rewrite[key](w, review)
                    log.append(dict(side=side, wall=w['id'], region=key, before=before, after=w['bands']))
                    walls.append(w)
                else:
                    for n, piece in enumerate(inside):
                        part = dict(w, id=f"{w['id']}-garage-{key}-{n}", rings=rings(piece), fillRule='evenodd')
                        part['bands'] = rewrite[key](w, review)
                        log.append(dict(side=side, wall=part['id'], region=key, before=w['bands'], after=part['bands']))
                        walls.append(part)
                    for n, piece in enumerate(outside):
                        walls.append(dict(w, id=f"{w['id']}-garage-remainder-{n}", rings=rings(piece), fillRule='evenodd'))
                placed = True
                break
            if not placed:
                walls.append(w)
        before = shapely.union_all([polygon(w) for w in model['walls']])
        after = shapely.union_all([polygon(w) for w in walls])
        assert before.symmetric_difference(after).area < 1e-6, 'ink changed'
        model['walls'] = walls
        model['sourceGarageWindowReviewSha256'] = __import__('hashlib').sha256(REVIEW.read_bytes()).hexdigest()
        write(a.out / name, model)
        print(f'haven/{side}: {sum(1 for l in log if l["side"] == side)} pieces ruled', flush=True)
    (a.out / 'changes.json').write_text(json.dumps(log, indent=1))
    if a.install:
        for side in ('attack', 'defense'):
            n = f'haven_svg_height_{side}.json.gz'; shutil.copyfile(a.out / n, a.assets / n)
        subprocess.run([sys.executable, 'scripts/svg_wall_footprint_integrity.py'], check=True)
        subprocess.run([sys.executable, 'scripts/standing_source_integrity.py'], check=True)


if __name__ == '__main__':
    main()
