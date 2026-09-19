"""Stop sightlines at the buildings drawn as voids inside the map.

The painted floor has holes: buildings, rock, machinery, crate clusters
that nobody can stand in. The perimeter seal leaves them alone because a
low void (a crate cluster) can be seen over from a box. But a wall bounding
a tall void with a band below the eye lets a ray cross the void and come
out on the far side, which is seeing through a building. Pearl's upper B
Hall looked straight across the tunnel's south wall into the block beyond.

For each interior hole of the receiver at least MIN_VOID_M2 in area, the
scene's solid faces inside it give a roof height: the median of the column
tops on a one-unit grid, so one lamppost does not raise a pond. Every unprotected wall piece whose ink lies mostly against
that hole has [floor, roof] merged into its bands: a low void still lets a
high eye see over, a building blocks every eye below its roof.

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
from demote_unreachable_supports import Ground
from audit_svg_wall_heights_vs_world import (ALIGN, WORLD, decorative_face_ranges,
                                             solid_material_mask)

MAPS = ['abyss', 'ascent', 'bind', 'breeze', 'corrode', 'fracture', 'haven',
        'icebox', 'lotus', 'pearl', 'split', 'summit', 'sunset']
# Tunnel-review pieces are not exempt: a tunnel wall that bounds a void must
# still stop the upper level from looking into the block behind it.
PROTECTED = re.compile(r'review|reported|gameplay|opening|confirmed|owned|retained|prior-height|finite|section|user|profile|station|assembly|ownership|ramp|source|crate|header|jamb|sill|tier|door|window|facade|shrine|balcony|platform|rail|marker|symbol|zipline|garage', re.I)
REVIEWED = Path('work/reviewed-wall-ids.json')
MIN_VOID_M2 = 10.0
CELL_SVG = 1.0
TOUCH_SVG = 0.8
INSIDE_FRACTION = 0.5
BUILDING_RISE_M = 4.0


def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))


def merged(bands, lo, hi):
    """bands with [lo, hi] added, overlaps absorbed, order kept."""
    out = []
    a, b = lo, hi
    for x, y in sorted([list(t) for t in bands] + [[lo, hi]], key=lambda t: t[0]):
        if out and (out[-1][1] is None or x <= out[-1][1] + 1e-6):
            if out[-1][1] is not None:
                out[-1][1] = None if y is None else max(out[-1][1], y)
        else:
            out.append([x, y])
    return out


class Faces:
    def __init__(self, map_name, side):
        data = np.load(WORLD / map_name / 'geometry.npz')
        meta = json.loads((WORLD / map_name / 'geometry.json').read_text())
        keep = solid_material_mask(meta)[data['material_indices']]
        for start, stop in decorative_face_ranges(meta):
            keep[start:stop] = False
        faces = data['faces'][keep]
        centre = data['points'][faces].mean(axis=1)
        m = np.array(json.loads((ALIGN / f'{map_name}.json').read_text())[f'nativeTo{side.title()}Svg'])
        self.xy = centre[:, :2] @ m[:, :2].T + m[:, 2]
        self.z = centre[:, 2]
        self.unit = float(np.sqrt(abs(np.linalg.det(m[:, :2]))))

    def roof(self, hole):
        """Median of the column tops on a 1-unit grid over the hole: a crate
        cluster reads as the crate top, a building as its roof, a pond with a
        lamppost as the water, whatever the tallest single thing inside is."""
        x0, y0, x1, y1 = hole.bounds
        idx = np.flatnonzero((self.xy[:, 0] >= x0) & (self.xy[:, 0] <= x1) & (self.xy[:, 1] >= y0) & (self.xy[:, 1] <= y1))
        idx = idx[shapely.contains_xy(hole, self.xy[idx, 0], self.xy[idx, 1])]
        if len(idx) < 20:
            return None
        cells = {}
        for (x, y), z in zip(self.xy[idx], self.z[idx]):
            key = (int(x // CELL_SVG), int(y // CELL_SVG))
            if z > cells.get(key, -1e9):
                cells[key] = z
        return float(np.median(list(cells.values())))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets', type=Path, default=Path('assets/maps'))
    ap.add_argument('--out', type=Path, default=Path('work/void-walls/candidate'))
    ap.add_argument('--maps', nargs='*', default=MAPS)
    ap.add_argument('--install', action='store_true')
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    reviewed = json.loads(REVIEWED.read_text()) if REVIEWED.exists() else {}
    log = []
    for m in a.maps:
        keep = set(reviewed.get(m, [])) | set(reviewed.get('?', []))
        for s in ('attack', 'defense'):
            model = read(a.assets / f'{m}_svg_height_{s}.json.gz')
            faces = Faces(m, s)
            receiver = shapely.union_all([polygon(r) for r in model['receiver']])
            outer = max(shapely.get_parts(receiver), key=lambda q: q.area)
            holes = []
            for ring in outer.interiors:
                hole = shapely.Polygon(ring)
                if hole.area / faces.unit ** 2 < MIN_VOID_M2:
                    continue
                roof = faces.roof(hole)
                if roof is not None:
                    holes.append((hole, hole.buffer(TOUCH_SVG), roof))
            tree = shapely.STRtree([h[1] for h in holes])
            ground = Ground(model['ground'])
            support_tree = shapely.STRtree([polygon(x) for x in model['supports'] if x.get('automaticStandingAllowed')] or [shapely.Polygon()])
            changed = 0
            for w in model['walls']:
                if w['id'] in keep or PROTECTED.search(w['id']):
                    continue
                shape = polygon(w)
                if shape.area <= 0:
                    continue
                best = None
                for i in tree.query(shape, predicate='intersects'):
                    hole, pad, roof = holes[int(i)]
                    if shape.intersection(pad).area >= INSIDE_FRACTION * shape.area:
                        best = roof if best is None else max(best, roof)
                if best is None:
                    continue
                c = shape.representative_point()
                local = ground.height_at(c.x, c.y)
                if local is None:
                    local = w['floorElevationMeters']
                if best < local + BUILDING_RISE_M:
                    continue
                if any(int(i) for i in [1] if support_tree.query(shape, predicate='intersects').size):
                    continue
                top = round(best - w['floorElevationMeters'], 4)
                if top <= 0.05:
                    continue
                bands = merged(w['bands'], 0.0, top)
                if bands == w['bands']:
                    continue
                log.append(dict(map=m, side=s, wall=w['id'], before=w['bands'], after=bands, roof=round(best, 2)))
                w['bands'] = bands
                changed += 1
            write(a.out / f'{m}_svg_height_{s}.json.gz', model)
            print(f'{m}/{s}: {len(holes)} voids, sealed {changed} bounding pieces', flush=True)
            del faces
    (a.out / 'changes.json').write_text(json.dumps(log, indent=1))
    if a.install:
        for m in a.maps:
            for s in ('attack', 'defense'):
                n = f'{m}_svg_height_{s}.json.gz'; shutil.copyfile(a.out / n, a.assets / n)
        subprocess.run([sys.executable, 'scripts/svg_wall_footprint_integrity.py'], check=True)
        subprocess.run([sys.executable, 'scripts/standing_source_integrity.py'], check=True)


if __name__ == '__main__':
    main()
