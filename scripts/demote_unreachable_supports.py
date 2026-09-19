"""Stop levels nobody can climb to from being chosen automatically.

The standing model carries every measured mesh top as a support, including
rooftops and skybox pieces far above the floor. Dragging an agent across
one lifts the eye by tens of metres and the cone becomes a bird's-eye view
over every wall (Haven B site carried a surface 40 m up). A support is
reachable when some point of it lies within CLIMB_M above the reference
ground, or when it touches a reachable support (automatic or not) and is
within CLIMB_M above it at the seam; ramps, stairs and stacked boxes all
pass. Anything else
keeps its geometry for explicit selection but is no longer eligible for
automatic standing. Sightline reference floors are untouched.

Writes candidates under --out and, with --install, copies them over
assets/maps and refreshes both certificates.
"""
import argparse
import gzip
import json
import shutil
import subprocess
import sys
from collections import deque
from pathlib import Path

import numpy as np
import shapely

from compile_reviewed_svg_height_map import polygon

MAPS = ['abyss', 'ascent', 'bind', 'breeze', 'corrode', 'fracture', 'haven',
        'icebox', 'lotus', 'pearl', 'split', 'summit', 'sunset']
CLIMB_M = 2.5        # a jump from a boost reaches this; a roof does not
MIN_GAP_M = 5.0      # demote only surfaces this far above the ground everywhere
MESH_CLASSES = ('-measured-mesh-', '-physical-top-')   # tops lifted straight off the mesh
FIXTURES = Path('test/fixtures')


def fixture_points(map_name, side):
    """(x, y, expected floor) for every reviewed standing case on this side."""
    points = []
    for path in list(FIXTURES.glob(f'{map_name}_*.json')) + list(FIXTURES.glob(f'{map_name}_*.json.gz')):
        if 'regional_standing' in path.name:
            # A mechanical dump of every measured domain, roofs included; the
            # regional test checks those levels exist, not that they are automatic.
            continue
        raw = path.read_bytes()
        if path.suffix == '.gz':
            raw = gzip.decompress(raw)
        try:
            data = json.loads(raw)
        except ValueError:
            continue
        stack = [data]
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                svg = node.get('svg')
                floor = node.get('expectedFloorMeters')
                if isinstance(svg, dict) and side in svg and isinstance(floor, (int, float)):
                    x, y = svg[side]
                    points.append((float(x), float(y), float(floor)))
                stack.extend(node.values())
            elif isinstance(node, list):
                stack.extend(node)
    return points


def pinned_ids(sups, shapes, points):
    if not points:
        return set()
    tree = shapely.STRtree(shapes)
    pinned = set()
    for x, y, floor in points:
        for i in tree.query(shapely.Point(x, y), predicate='intersects'):
            i = int(i)
            if abs(surface_at(sups[i], x, y) - floor) <= 0.02:
                pinned.add(sups[i]['id'])
    return pinned
TOUCH_SVG = 0.15     # supports closer than this share a seam
MAX_SAMPLES = 60     # ring vertices sampled per support


def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))


class Ground:
    def __init__(self, ground):
        v = np.array(ground['vertices'], dtype=float).reshape(-1, 3)
        t = np.array(ground['triangles'], dtype=int).reshape(-1, 3)
        self.v, self.t = v, t
        self.tree = shapely.STRtree(shapely.polygons(v[t][:, :, :2]))

    def height_at(self, x, y):
        for i in self.tree.query(shapely.Point(x, y), predicate='intersects'):
            a, b, c = self.v[self.t[int(i)]]
            d = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
            if abs(d) < 1e-12:
                continue
            wa = ((b[1] - c[1]) * (x - c[0]) + (c[0] - b[0]) * (y - c[1])) / d
            wb = ((c[1] - a[1]) * (x - c[0]) + (a[0] - c[0]) * (y - c[1])) / d
            return wa * a[2] + wb * b[2] + (1 - wa - wb) * c[2]
        return None


def surface_at(sup, x, y):
    plane = sup.get('surfacePlane')
    if plane:
        return plane[0] * x + plane[1] * y + plane[2]
    return sup.get('surfaceElevationMeters')


def samples(shape):
    pts = [shape.representative_point()]
    for part in shapely.get_parts(shape):
        if part.geom_type == 'Polygon':
            coords = list(part.exterior.coords)
            step = max(1, len(coords) // MAX_SAMPLES)
            pts += [shapely.Point(c) for c in coords[::step]]
    return pts


def reachable_ids(model):
    ground = Ground(model['ground'])
    # Every support is a step on the way up, automatic or not: a stack of
    # crates that only explicit selection may stand on still carries a
    # player to the platform above it.
    sups = [s for s in model['supports'] if s.get('surfaceElevationMeters') is not None]
    shapes = [polygon(s) for s in sups]
    padded = [sh.buffer(TOUCH_SVG) for sh in shapes]
    tree = shapely.STRtree(padded)
    reachable = set()
    min_gap = {}
    for i, (sup, shape) in enumerate(zip(sups, shapes)):
        gaps = []
        for p in samples(shape):
            g = ground.height_at(p.x, p.y)
            if g is not None:
                gaps.append(surface_at(sup, p.x, p.y) - g)
        if gaps:
            min_gap[i] = min(gaps)
            if min_gap[i] <= CLIMB_M:
                reachable.add(i)
    queue = deque(reachable)
    while queue:
        i = queue.popleft()
        for j in tree.query(padded[i], predicate='intersects'):
            j = int(j)
            if j == i or j in reachable:
                continue
            seam = padded[i].intersection(padded[j])
            if seam.is_empty:
                continue
            p = seam.representative_point()
            if surface_at(sups[j], p.x, p.y) - surface_at(sups[i], p.x, p.y) <= CLIMB_M:
                reachable.add(j)
                queue.append(j)
    return ({sups[i]['id'] for i in reachable}, sups, shapes, ground,
            {sups[i]['id']: gap for i, gap in min_gap.items()})


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets', type=Path, default=Path('assets/maps'))
    ap.add_argument('--out', type=Path, default=Path('work/unreachable/candidate'))
    ap.add_argument('--maps', nargs='*', default=MAPS)
    ap.add_argument('--install', action='store_true')
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    log = []
    for m in a.maps:
        for s in ('attack', 'defense'):
            model = read(a.assets / f'{m}_svg_height_{s}.json.gz')
            keep = set(model.get('sightlineFloorSupportIds') or [])
            reachable, sups, shapes, ground, min_gap = reachable_ids(model)
            pinned = pinned_ids(sups, shapes, fixture_points(m, s))
            demoted = 0
            for sup, shape in zip(sups, shapes):
                if sup['id'] in reachable or sup['id'] in keep or not sup.get('automaticStandingAllowed'):
                    continue
                if not any(c in sup['id'] for c in MESH_CLASSES) or min_gap.get(sup['id'], 0) < MIN_GAP_M:
                    continue
                if sup['id'] in pinned:
                    continue
                sup['automaticStandingAllowed'] = False
                c = shape.representative_point()
                g = ground.height_at(c.x, c.y)
                log.append(dict(map=m, side=s, support=sup['id'], label=sup.get('label'),
                                surface=round(sup['surfaceElevationMeters'], 2),
                                minGapToGround=round(min_gap[sup['id']], 2),
                                groundAtCentre=None if g is None else round(g, 2),
                                areaSvg=round(shape.area, 2), centre=[round(c.x, 1), round(c.y, 1)]))
                demoted += 1
            automatic = sum(1 for x in model['supports'] if x.get('automaticStandingAllowed'))
            write(a.out / f'{m}_svg_height_{s}.json.gz', model)
            print(f'{m}/{s}: demoted {demoted} unreachable supports, {automatic} automatic remain', flush=True)
    (a.out / 'changes.json').write_text(json.dumps(log, indent=1))
    if a.install:
        for m in a.maps:
            for s in ('attack', 'defense'):
                n = f'{m}_svg_height_{s}.json.gz'; shutil.copyfile(a.out / n, a.assets / n)
        subprocess.run([sys.executable, 'scripts/svg_wall_footprint_integrity.py'], check=True)
        subprocess.run([sys.executable, 'scripts/standing_source_integrity.py'], check=True)


if __name__ == '__main__':
    main()
