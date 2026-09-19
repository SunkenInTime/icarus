"""Cut Split's outline-blob walls into short pieces, like every other map.

Split was the prototype: its wall layer is 69 records, one per painted run,
each carrying a single hand-assigned band. The other twelve maps carry
thousands of pieces about a metre long, each with bands measured from the
3D scene, which is what lets a window, a crate and the wall above it behave
differently. This cuts each Split record into pieces along its medial line
so scripts/derive_wall_bands_by_rays.py can measure them the same way.

Each piece keeps its parent's floor and bands, so before derivation the
model is behaviourally identical to the blob model (the ink union is
asserted unchanged). Records whose names record a reviewed prop cut
(`-low-`, `-counter-`, `-planter-`, `vent...-opening`, ...) stay whole and
are listed in protect-extra.json so the derivation leaves their bands alone.

Ids: `<parent>-local-<n>`, so the parent stroke of a piece is still
readable from its id by the neighbour rules.
"""
import argparse
import gzip
import json
import re
from pathlib import Path

import numpy as np
import shapely

from scipy.spatial import Voronoi

from compile_reviewed_svg_height_map import polygon, rings

SPACING_SVG = 2.0        # seeds this far apart along the medial line (~0.5 m on Split)
BOUNDARY_STEP_SVG = 0.1  # boundary sampling for the medial axis
MEDIAL_MARGIN = 0.35     # a Voronoi vertex this far inside the ink lies on the medial line
GENERIC = re.compile(r'^p\d+-unknown-\d+$')   # a plain painted run; anything else is a reviewed cut


def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d, separators=(',', ':')).encode(), mtime=0))


def nearest_sample_cells(points, shape):
    """Convex nearest-sample cells clipped by explicit perpendicular bisectors.

    Same construction as compile_local_svg_wall_profiles.nearest_sample_cells;
    copied because importing that module pulls in the USD toolchain.
    """
    points = np.asarray(points, dtype=float)
    lower, upper = np.asarray(shape.bounds[:2]) - 1, np.asarray(shape.bounds[2:]) + 1
    origin = (lower + upper) / 2
    points = points - origin
    lower, upper = lower - origin, upper - origin
    rectangle = np.array([lower, [upper[0], lower[1]], upper, [lower[0], upper[1]]])
    neighbors = [set() for _ in points]
    if len(points) > 1:
        _, singular, axes = np.linalg.svd(points - points.mean(0), full_matrices=False)
        if len(points) < 3 or len(singular) < 2 or singular[1] < 1e-9:
            order = np.argsort(points @ axes[0])
            pairs = zip(order[:-1], order[1:])
        else:
            pairs = Voronoi(points).ridge_points
        for a, b in pairs:
            neighbors[a].add(b)
            neighbors[b].add(a)
    cells = []
    for i, point in enumerate(points):
        vertices = rectangle.copy()
        for j in sorted(neighbors[i]):
            normal = points[j] - point
            normal /= np.linalg.norm(normal)
            midpoint = (points[j] + point) / 2
            values = (vertices - midpoint) @ normal
            clipped = []
            for k, a in enumerate(vertices):
                b = vertices[(k + 1) % len(vertices)]
                va, vb = values[k], values[(k + 1) % len(vertices)]
                if va <= 0:
                    clipped.append(a)
                if (va <= 0) != (vb <= 0):
                    clipped.append(a + va / (va - vb) * (b - a))
            vertices = np.asarray(clipped)
            if len(vertices) < 3:
                break
        cells.append(shapely.Polygon(vertices + origin) if len(vertices) >= 3 else shapely.Polygon())
    return cells


def medial_points(shape):
    coords = []
    for part in shapely.get_parts(shape):
        if part.geom_type != 'Polygon':
            continue
        for ring in [part.exterior, *part.interiors]:
            count = max(4, int(ring.length / BOUNDARY_STEP_SVG))
            coords += [ring.interpolate(i * ring.length / count).coords[0] for i in range(count)]
    coords = np.array(coords)
    if len(coords) < 4:
        return np.array([[shape.centroid.x, shape.centroid.y]])
    verts = Voronoi(coords).vertices
    inside = shapely.contains_xy(shape, verts[:, 0], verts[:, 1])
    verts = verts[inside]
    if not len(verts):
        return np.array([[shape.representative_point().x, shape.representative_point().y]])
    boundary = shape.boundary
    dist = shapely.distance(boundary, shapely.points(verts))
    width = 2 * dist.max()
    keep = dist >= MEDIAL_MARGIN * width
    return verts[keep] if keep.any() else verts


def seeds_along(points):
    """Greedy cover: every medial point within SPACING of a seed, seeds ≥ SPACING apart."""
    order = np.lexsort((points[:, 1], points[:, 0]))
    chosen = []
    for p in points[order]:
        if all(np.hypot(*(p - c)) >= SPACING_SVG for c in chosen):
            chosen.append(p)
    return np.array(chosen)


def pieces_of(shape):
    seeds = seeds_along(medial_points(shape))
    if len(seeds) < 2:
        return [shape]
    cells = nearest_sample_cells(seeds, shape)
    out = []
    for cell in cells:
        part = shape.intersection(cell)
        for piece in shapely.get_parts(part):
            if piece.geom_type == 'Polygon' and piece.area > 1e-9:
                out.append(piece)
    return out


def partition(model):
    walls, protect = [], []
    for w in model['walls']:
        shape = shapely.make_valid(polygon(w))
        if not GENERIC.match(w['id']) or shape.is_empty:
            walls.append(w)
            protect.append(w['id'])
            continue
        parts = pieces_of(shape)
        union = shapely.union_all(parts)
        assert abs(union.area - shape.area) < 1e-6 * max(1.0, shape.area), w['id']
        for n, piece in enumerate(parts):
            walls.append(dict(id=f"{w['id']}-local-{n}", rings=rings(piece), fillRule='evenodd',
                              floorElevationMeters=w['floorElevationMeters'],
                              bands=[list(b) for b in w['bands']], unknownHeight=False))
    before = shapely.union_all([polygon(w) for w in model['walls']])
    after = shapely.union_all([polygon(w) for w in walls])
    assert before.symmetric_difference(after).area < 1e-6, 'ink changed'
    model['walls'] = walls
    return model, protect


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets', type=Path, default=Path('assets/maps'))
    ap.add_argument('--out', type=Path, default=Path('work/split-pieces'))
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    extra = {'split': {}}
    for side in ('attack', 'defense'):
        model = read(a.assets / f'split_svg_height_{side}.json.gz')
        count = len(model['walls'])
        model, protect = partition(model)
        extra['split'][side] = protect
        write(a.out / f'split_svg_height_{side}.json.gz', model)
        print(f'split/{side}: {count} records -> {len(model["walls"])} pieces, {len(protect)} reviewed kept whole', flush=True)
    (a.out / 'protect-extra.json').write_text(json.dumps(extra, indent=1))


if __name__ == '__main__':
    main()
