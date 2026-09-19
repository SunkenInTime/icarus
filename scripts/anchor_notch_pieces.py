"""Close see-through notches: tiny wall pieces with a lifted base whose
touching neighbours on the same stroke stand on the floor.

Ray derivation probes across a wall's ink; at a corner or a stub the
corridor looks past the wall into open air, and the piece comes out with
its lowest band lifted while the pieces either side are solid from the
floor. A standing eye then slips under it and the cone leaks through a hole
narrower than a player. A doorway is not like this: it is wider than
MAX_SPAN_M and its own pieces are lifted too. So a piece is anchored to the
floor when it is at most MAX_SPAN_M across, every touching neighbour on its
stroke starts at the floor, at least MIN_NEIGHBOURS of them exist, and
their tops reach the piece's lifted base. Reviewed and protected pieces are
left alone.

Writes candidates under --out and, with --install, copies them over
assets/maps and refreshes both certificates.
"""
import argparse
import gzip
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import shapely

from compile_reviewed_svg_height_map import polygon

MAPS = ['abyss', 'ascent', 'bind', 'breeze', 'corrode', 'fracture', 'haven',
        'icebox', 'lotus', 'pearl', 'split', 'summit', 'sunset']
ALIGNMENT = Path('E:/IcarusWorldAudit/2026-09-06/tactical-alignment-sides-v1')
PROTECTED = re.compile(r'review|reported|gameplay|opening|confirmed|owned|retained|prior-height|finite|tunnel|section|user|profile|station|assembly|ownership|ramp|source|crate|header|jamb|sill|tier|door|window|facade|shrine|balcony|platform|rail|marker|symbol|zipline', re.I)
REVIEWED = Path('work/reviewed-wall-ids.json')
MAX_SPAN_M = 1.2      # a player needs more than this to pass; a doorway has it
MIN_LIFT_M = 0.5      # lower bases are kerbs and rounding
MIN_NEIGHBOURS = 2
TOUCH_SVG = 0.05


def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))


def units_per_metre(map_name, side):
    matrix = np.array(json.loads((ALIGNMENT / f'{map_name}.json').read_bytes())[f'nativeTo{side.title()}Svg'])
    return float(np.sqrt(abs(np.linalg.det(matrix[:, :2]))))


def span(shape):
    minx, miny, maxx, maxy = shape.minimum_rotated_rectangle.bounds
    coords = np.array(shape.minimum_rotated_rectangle.exterior.coords)[:4]
    edges = np.linalg.norm(coords[1:] - coords[:-1], axis=1)
    return float(edges.max())


def top_of(bands):
    return float('inf') if bands[-1][1] is None else bands[-1][1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets', type=Path, default=Path('assets/maps'))
    ap.add_argument('--out', type=Path, default=Path('work/notches/candidate'))
    ap.add_argument('--install', action='store_true')
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    reviewed = json.loads(REVIEWED.read_text()) if REVIEWED.exists() else {}
    log = []
    for m in MAPS:
        keep = set(reviewed.get(m, [])) | set(reviewed.get('?', []))
        for s in ('attack', 'defense'):
            model = read(a.assets / f'{m}_svg_height_{s}.json.gz')
            scale = units_per_metre(m, s)
            by_stroke = {}
            for w in model['walls']:
                by_stroke.setdefault('-'.join(w['id'].split('-')[:3]), []).append(w)
            anchored = 0
            for members in by_stroke.values():
                shapes = [polygon(w) for w in members]
                tree = shapely.STRtree([sh.buffer(TOUCH_SVG) for sh in shapes])
                for i, w in enumerate(members):
                    bands = w['bands']
                    if not bands or bands[0][0] < MIN_LIFT_M or w['id'] in keep or PROTECTED.search(w['id']):
                        continue
                    if shapes[i].is_empty or span(shapes[i]) / scale > MAX_SPAN_M:
                        continue
                    neighbours = [members[int(j)] for j in tree.query(shapes[i].buffer(TOUCH_SVG), predicate='intersects') if int(j) != i]
                    if len(neighbours) < MIN_NEIGHBOURS:
                        continue
                    if not all(n['bands'] and n['bands'][0][0] <= 0.05 and top_of(n['bands']) >= bands[0][0]
                               and n['floorElevationMeters'] == w['floorElevationMeters'] for n in neighbours):
                        continue
                    before = [list(b) for b in bands]
                    bands[0][0] = 0.0
                    log.append(dict(map=m, side=s, wall=w['id'], before=before, after=bands,
                                    spanM=round(span(shapes[i]) / scale, 2), neighbours=[n['id'] for n in neighbours]))
                    anchored += 1
            write(a.out / f'{m}_svg_height_{s}.json.gz', model)
            print(f'{m}/{s}: anchored {anchored} notch pieces', flush=True)
    (a.out / 'changes.json').write_text(json.dumps(log, indent=1))
    if a.install:
        for m in MAPS:
            for s in ('attack', 'defense'):
                n = f'{m}_svg_height_{s}.json.gz'; shutil.copyfile(a.out / n, a.assets / n)
        subprocess.run([sys.executable, 'scripts/svg_wall_footprint_integrity.py'], check=True)
        subprocess.run([sys.executable, 'scripts/standing_source_integrity.py'], check=True)


if __name__ == '__main__':
    main()
