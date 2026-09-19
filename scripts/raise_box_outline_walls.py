"""Make a standing box's outline as tall as the box.

A boost step or crate is a measured standing volume with a surface height,
and the map draws it as an outline stroke around that footprint. Ray probing
across a small box is unreliable (the corridor sees the lid or nothing), so
the outline ends up as slivers or gaps and a player beside the box sees
through it. Here a wall piece whose outer ring encloses a box support, and is
not much bigger than the box, rises to at least the support surface with its
base on the floor: a ground eye is stopped by the box and an eye on the box
sees over it. Reviewed and protected pieces are left alone, so are supports
taller than a box or wide enough to be floors.

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
MAX_SUPPORT_AREA = 400.0   # svg units^2; bigger supports are floors, not boxes
MIN_SUPPORT_AREA = 1.0     # slivers are not boxes
COVERED_FRACTION = 0.8     # support area inside the wall's outer ring
MAX_HULL_RATIO = 4.0       # outer ring area over support area; bigger is a room
MIN_RISE = 0.3             # metres over the wall floor; lower is a kerb
MAX_RISE = 6.0             # metres; taller is a roof, not a box you stand beside


def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))


def outer(wall):
    """What an outline stroke encloses. Box outlines are open C and U shapes
    as often as closed rings, so the convex hull stands in for the enclosed
    area; the hull-to-box area cap keeps long walls from qualifying."""
    shape = polygon(wall)
    return None if shape.is_empty else shape.convex_hull


def merged(bands, target):
    """Anchor the lowest band to 0 and lift it to target, absorbing overlaps."""
    low = [0.0, None if bands[0][1] is None else max(target, bands[0][1])]
    out = []
    for b in bands[1:]:
        if low[1] is None or b[0] <= low[1]:
            low[1] = None if (b[1] is None or low[1] is None) else max(low[1], b[1])
        else:
            out.append([b[0], b[1]])
    return [low] + out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets', type=Path, default=Path('assets/maps'))
    ap.add_argument('--out', type=Path, default=Path('work/box-outline/candidate'))
    ap.add_argument('--install', action='store_true')
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    reviewed = json.loads(REVIEWED.read_text()) if REVIEWED.exists() else {}
    log = []
    for m in MAPS:
        keep = set(reviewed.get(m, [])) | set(reviewed.get('?', []))
        for s in ('attack', 'defense'):
            model = read(a.assets / f'{m}_svg_height_{s}.json.gz')
            boxes = []
            for sup in model['supports']:
                if not sup.get('automaticStandingAllowed') or sup.get('surfaceElevationMeters') is None:
                    continue
                shape = polygon(sup)
                if MIN_SUPPORT_AREA <= shape.area <= MAX_SUPPORT_AREA:
                    boxes.append((sup, shape))
            tree = shapely.STRtree([b[1] for b in boxes])
            changed = 0
            for w in model['walls']:
                if w['id'] in keep or PROTECTED.search(w['id']) or not w['bands']:
                    continue
                hull = outer(w)
                if hull is None or hull.area <= 0:
                    continue
                best = None
                for i in tree.query(hull, predicate='intersects'):
                    sup, shape = boxes[int(i)]
                    if hull.area > MAX_HULL_RATIO * shape.area:
                        continue
                    if shape.intersection(hull).area < COVERED_FRACTION * shape.area:
                        continue
                    rise = sup['surfaceElevationMeters'] - w['floorElevationMeters']
                    if MIN_RISE <= rise <= MAX_RISE and (best is None or rise > best):
                        best = rise
                if best is None:
                    continue
                target = round(best, 4)
                first = w['bands'][0]
                if first[0] <= 0.05 and (first[1] is None or first[1] >= target):
                    continue
                before = [list(b) for b in w['bands']]
                w['bands'] = merged(w['bands'], target)
                log.append(dict(map=m, side=s, wall=w['id'], before=before, after=w['bands']))
                changed += 1
            write(a.out / f'{m}_svg_height_{s}.json.gz', model)
            print(f'{m}/{s}: raised {changed} box outline pieces', flush=True)
    (a.out / 'changes.json').write_text(json.dumps(log, indent=1))
    if a.install:
        for m in MAPS:
            for s in ('attack', 'defense'):
                n = f'{m}_svg_height_{s}.json.gz'; shutil.copyfile(a.out / n, a.assets / n)
        subprocess.run([sys.executable, 'scripts/svg_wall_footprint_integrity.py'], check=True)
        subprocess.run([sys.executable, 'scripts/standing_source_integrity.py'], check=True)


if __name__ == '__main__':
    main()
