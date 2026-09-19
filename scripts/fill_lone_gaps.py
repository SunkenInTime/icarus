"""Fill a gap in a wall piece's bands that no touching neighbour shares.

Ray derivation reads each piece on its own. A recess, a pipe run or a
shadowed face can leave one piece with a slot in its band stack while the
pieces either side stay solid across the same heights. A slot narrower than
a piece (about a third of a metre) is not a window anyone sees through, but
an eye at that height slips through it and the cone leaks past a solid wall
(Haven's Garage west wall had a 0.9 m slot at head height). A real window
spans several pieces, so this only touches a gap that every touching
neighbour on the same stroke (at least MIN_NEIGHBOURS) covers with solid
band. Reviewed and protected pieces are left alone.

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

import shapely

from compile_reviewed_svg_height_map import polygon

MAPS = ['abyss', 'ascent', 'bind', 'breeze', 'corrode', 'fracture', 'haven',
        'icebox', 'lotus', 'pearl', 'split', 'summit', 'sunset']
PROTECTED = re.compile(r'review|reported|gameplay|opening|confirmed|owned|retained|prior-height|finite|tunnel|section|user|profile|station|assembly|ownership|ramp|source|crate|header|jamb|sill|tier|door|window|facade|shrine|balcony|platform|rail|marker|symbol|zipline', re.I)
REVIEWED = Path('work/reviewed-wall-ids.json')
MIN_NEIGHBOURS = 2
TOUCH_SVG = 0.05


def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))


def covered(bands, lo, hi):
    return any(b[0] <= lo + 1e-6 and (b[1] is None or b[1] >= hi - 1e-6) for b in bands)


def filled(bands, neighbours):
    """Merge consecutive bands across every gap the neighbours all cover."""
    out = [list(bands[0])]
    for b in bands[1:]:
        lo, hi = out[-1][1], b[0]
        if lo is not None and all(covered(n['bands'], lo, hi) for n in neighbours):
            out[-1][1] = b[1]
        else:
            out.append(list(b))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets', type=Path, default=Path('assets/maps'))
    ap.add_argument('--out', type=Path, default=Path('work/lone-gaps/candidate'))
    ap.add_argument('--install', action='store_true')
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    reviewed = json.loads(REVIEWED.read_text()) if REVIEWED.exists() else {}
    log = []
    for m in MAPS:
        keep = set(reviewed.get(m, [])) | set(reviewed.get('?', []))
        for s in ('attack', 'defense'):
            model = read(a.assets / f'{m}_svg_height_{s}.json.gz')
            by_stroke = {}
            for w in model['walls']:
                by_stroke.setdefault('-'.join(w['id'].split('-')[:3]), []).append(w)
            changed = 0
            for members in by_stroke.values():
                shapes = [polygon(w).buffer(TOUCH_SVG) for w in members]
                tree = shapely.STRtree(shapes)
                for i, w in enumerate(members):
                    if len(w['bands']) < 2 or w['id'] in keep or PROTECTED.search(w['id']):
                        continue
                    neighbours = [members[int(j)] for j in tree.query(shapes[i], predicate='intersects') if int(j) != i]
                    if len(neighbours) < MIN_NEIGHBOURS:
                        continue
                    bands = filled(w['bands'], neighbours)
                    if bands != w['bands']:
                        log.append(dict(map=m, side=s, wall=w['id'], before=w['bands'], after=bands))
                        w['bands'] = bands
                        changed += 1
            write(a.out / f'{m}_svg_height_{s}.json.gz', model)
            print(f'{m}/{s}: filled gaps in {changed} pieces', flush=True)
    (a.out / 'changes.json').write_text(json.dumps(log, indent=1))
    if a.install:
        for m in MAPS:
            for s in ('attack', 'defense'):
                n = f'{m}_svg_height_{s}.json.gz'; shutil.copyfile(a.out / n, a.assets / n)
        subprocess.run([sys.executable, 'scripts/svg_wall_footprint_integrity.py'], check=True)
        subprocess.run([sys.executable, 'scripts/standing_source_integrity.py'], check=True)


if __name__ == '__main__':
    main()
