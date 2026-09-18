"""Find wall-height anomalies in the bundled SVG-height visibility models.

The runtime rule is flat: a wall stops an eye when the eye height lies inside one
of the wall's bands measured from that wall's floor, and the eye is the standing
surface plus the camera height. Everything here looks for places where that rule
and the painted data disagree with the map a player walks on.

Six detectors, each a candidate list for review and never a verdict:

  borrowed-height         an isolated thin piece carrying a height the 3D column
                          under its own ink cannot support, while its touching
                          neighbours on the same stroke agree with the 3D.
  low-cover-blocks-standing   chest-high cover whose top lands in the narrow
                          window that makes the flat rule opaque.
  see-under               a lifted base with solid 3D geometry beneath it.
  marking-as-wall         parallel thin strokes over flat ground beside a slope:
                          a ramp or staircase drawn as walls.
  edge-reach              a long sightline whose first blocker is outside the
                          painted floor after passing over a wall it sees across.
  level-jump-on-flat      neighbouring floor cells with the same ground under
                          them and no wall between, standing at different eyes.

Outputs work/anomalies/<map>_<side>.json, summary.md and poses.json.
"""
import argparse
import gzip
import json
import math
import sys
import time
from collections import defaultdict
from pathlib import Path

import numpy as np
import shapely

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compile_reviewed_svg_height_map import polygon
# The scene filtering, alignment maths and column stacking are settled in the
# heights audit; importing them keeps one definition of "geometry that blocks".
from audit_svg_wall_heights_vs_world import (
    ALIGN,
    MAPS,
    SIDES,
    Scene,
    column_runs,
    inverse_affine,
    parent_stroke,
    to_native,
)

BLOB_MAPS = {'split'}            # one outline per room; per-piece detectors say nothing.
BUFFER_SVG = 0.25                # the narrow footprint reading, as in the heights audit.
WALL_CHUNK = 128

BORROWED_DROP_M = 2.0            # the bake must exceed its own column by this much.
NEIGHBOUR_AGREE_M = 1.0          # a touching neighbour this close to the 3D agrees with it.
TOUCH_SVG = 0.1                  # pieces of one stroke meet at their shared cut.
THIN_SVG = 1.5                   # rectangle short side above this reads as a filled shape.

LOW_COVER_MIN_M = 1.0            # below this is a kerb, not cover.
LOW_COVER_MAX_M = 1.9            # above this the top is over a standing eye anyway.

LIFTED_BASE_M = 0.4              # a base this far off the ground is drawn as a lintel.
UNDER_SOLID_FRACTION = 0.5       # this much of the gap filled in 3D is a base that exists.
UNDER_MIN_FACES = 6              # fewer faces than this in the footprint is silence.

PAIR_MIN_SVG = 1.5               # two strokes closer than this are one stroke.
PAIR_MAX_SVG = 6.0
PAIR_PARALLEL_DEG = 15.0
PAIR_FLAT_M = 0.3                # ground between the strokes must be this continuous.
SLOPE_PROBE_SVG = 8.0
SLOPE_M = 0.5

REACH_STEP_SVG = 4.0
REACH_HEADINGS = 8
REACH_RANGE_SVG = 100.0
REACH_FAR_SVG = 60.0
REACH_BAND_SVG = 12.5            # march the ray in bands so the query boxes stay small.

JUMP_STEP_SVG = 2.0
JUMP_GROUND_M = 0.3
JUMP_EYE_M = 0.4

BURIED_SUPPORT_M = 3.0           # mirrors SvgHeightVisibility.buriedSupportMeters.
GROUND_MEETING_M = 1.0

POSE_DISTANCES = (6.0, 8.0, 10.0, 12.0)

DETECTORS = ['borrowed-height', 'low-cover-blocks-standing', 'see-under',
             'marking-as-wall', 'edge-reach', 'level-jump-on-flat']


# ---------------------------------------------------------------- small maths

def barycentric_z(tri, x, y):
    """Interpolated z over (T,3,3) triangles at matching xy."""
    a, b, c = tri[:, 0], tri[:, 1], tri[:, 2]
    den = (b[:, 1] - c[:, 1]) * (a[:, 0] - c[:, 0]) + (c[:, 0] - b[:, 0]) * (a[:, 1] - c[:, 1])
    safe = np.where(np.abs(den) < 1e-12, np.nan, den)
    w0 = ((b[:, 1] - c[:, 1]) * (x - c[:, 0]) + (c[:, 0] - b[:, 0]) * (y - c[:, 1])) / safe
    w1 = ((c[:, 1] - a[:, 1]) * (x - c[:, 0]) + (a[:, 0] - c[:, 0]) * (y - c[:, 1])) / safe
    return w0 * a[:, 2] + w1 * b[:, 2] + (1.0 - w0 - w1) * c[:, 2]


def group_offsets(counts):
    """Row indices and within-row offsets for a ragged repeat of `counts`."""
    total = int(counts.sum())
    rows = np.repeat(np.arange(len(counts)), counts)
    starts = np.cumsum(counts) - counts
    return rows, np.arange(total) - np.repeat(starts, counts)


def occupancy_fraction(low, high, bottoms, tops, step=0.1):
    """How much of [low, high] the given vertical spans cover."""
    if high - low <= 0 or not len(bottoms):
        return 0.0
    bins = max(1, int(math.ceil((high - low) / step)))
    lo = np.clip(np.ceil((bottoms - low) / step).astype(np.int64), 0, bins)
    hi = np.clip(np.floor((tops - low) / step).astype(np.int64) + 1, 0, bins)
    marks = np.zeros(bins + 1, dtype=np.int64)
    np.add.at(marks, lo, 1)
    np.add.at(marks, hi, -1)
    return float((np.cumsum(marks)[:bins] > 0).mean())


def rect_of(shapes):
    """Centre, long axis, short width and long length of each oriented envelope."""
    count = len(shapes)
    centre = np.zeros((count, 2))
    axis = np.tile(np.array([1.0, 0.0]), (count, 1))
    short = np.zeros(count)
    long = np.zeros(count)
    envelopes = shapely.oriented_envelope(np.asarray(shapes, dtype=object))
    coords, index = shapely.get_coordinates(envelopes, return_index=True)
    for i in range(count):
        ring = coords[index == i]
        if len(ring) < 4:
            if len(ring):
                centre[i] = ring.mean(axis=0)
            continue
        ring = ring[:4]
        centre[i] = ring.mean(axis=0)
        e1, e2 = ring[1] - ring[0], ring[2] - ring[1]
        l1, l2 = float(np.hypot(*e1)), float(np.hypot(*e2))
        edge, long[i], short[i] = (e1, l1, l2) if l1 >= l2 else (e2, l2, l1)
        norm = float(np.hypot(*edge))
        if norm > 0:
            axis[i] = edge / norm
    return centre, axis, short, long


# ------------------------------------------------------------------ the model

class SideModel:
    """One bundled map side, prepared for vectorised queries of the flat rule."""

    def __init__(self, map_name, side, root):
        self.map = map_name
        self.side = side
        raw = json.loads(gzip.decompress(
            (root / 'assets' / 'maps' / f'{map_name}_svg_height_{side}.json.gz').read_bytes()))
        self.camera = float(raw['defaultCameraHeightMeters'])

        self.receiver = shapely.union_all(
            [shapely.make_valid(polygon(row)) for row in raw['receiver']])
        shapely.prepare(self.receiver)

        walls = raw['walls']
        self.wall_ids = [w['id'] for w in walls]
        self.strokes = [parent_stroke(w['id']) for w in walls]
        self.wall_shapes = [shapely.make_valid(polygon(w)) for w in walls]
        self.wall_tree = shapely.STRtree(self.wall_shapes)
        self.wall_floor = np.array([float(w['floorElevationMeters'] or 0.0) for w in walls])
        self.wall_unknown = np.array([bool(w['unknownHeight']) for w in walls])
        bottoms, tops, counts = [], [], []
        for wall in walls:
            counts.append(len(wall['bands']))
            for low, high in wall['bands']:
                bottoms.append(float(low))
                tops.append(np.inf if high is None else float(high))
        self.band_bottom = np.array(bottoms) if bottoms else np.zeros(0)
        self.band_top = np.array(tops) if tops else np.zeros(0)
        self.band_count = np.array(counts, dtype=np.int64)
        self.band_start = np.cumsum(self.band_count) - self.band_count

        # The top and base a reader would read off the record, in source metres.
        self.assigned_top = np.full(len(walls), -np.inf)
        self.assigned_base = np.full(len(walls), np.inf)
        for i, wall in enumerate(walls):
            if self.wall_unknown[i]:
                self.assigned_top[i] = np.inf
                self.assigned_base[i] = self.wall_floor[i]
                continue
            if not wall['bands']:
                continue
            slice_ = slice(self.band_start[i], self.band_start[i] + self.band_count[i])
            self.assigned_top[i] = self.wall_floor[i] + float(self.band_top[slice_].max())
            self.assigned_base[i] = self.wall_floor[i] + float(self.band_bottom[slice_].min())

        self.area = shapely.area(self.wall_shapes)
        self.length = shapely.length(self.wall_shapes) / 2.0
        points = shapely.centroid(self.wall_shapes)
        self.centroid = np.stack([shapely.get_x(points), shapely.get_y(points)], axis=1)
        inside = shapely.point_on_surface(self.wall_shapes)
        self.ink_point = np.stack([shapely.get_x(inside), shapely.get_y(inside)], axis=1)
        # Ink area over centreline length is the width the piece was painted at.
        # Only a narrow footprint makes a 0.25 unit column reading mean anything.
        self.thin = (self.area <= THIN_SVG * np.maximum(self.length, 1e-9)) & (self.area > 0)
        # Wall ink bounds the painted floor, so most of it sits just outside the
        # fill. Exterior here means detached: ink that bounds nowhere anyone can
        # stand, which is what a sightline leaving the map would end on.
        self.wall_exterior = ~shapely.dwithin(
            np.asarray(self.wall_shapes, dtype=object), self.receiver, 0.5)

        edge_a, edge_b, edge_wall = [], [], []
        for i, wall in enumerate(walls):
            for ring in wall['rings']:
                ring = np.asarray(ring, dtype=np.float64).reshape(-1, 2)
                if len(ring) < 2:
                    continue
                edge_a.append(ring)
                edge_b.append(np.roll(ring, -1, axis=0))
                edge_wall.append(np.full(len(ring), i, dtype=np.int64))
        if edge_a:
            self.edge_a = np.vstack(edge_a)
            self.edge_b = np.vstack(edge_b)
            self.edge_wall = np.concatenate(edge_wall)
            keep = np.linalg.norm(self.edge_b - self.edge_a, axis=1) > 1e-9
            self.edge_a, self.edge_b = self.edge_a[keep], self.edge_b[keep]
            self.edge_wall = self.edge_wall[keep]
        else:
            self.edge_a = self.edge_b = np.zeros((0, 2))
            self.edge_wall = np.zeros(0, dtype=np.int64)
        self.edge_tree = shapely.STRtree(shapely.box(
            np.minimum(self.edge_a[:, 0], self.edge_b[:, 0]),
            np.minimum(self.edge_a[:, 1], self.edge_b[:, 1]),
            np.maximum(self.edge_a[:, 0], self.edge_b[:, 0]),
            np.maximum(self.edge_a[:, 1], self.edge_b[:, 1])))

        ground = raw['ground']
        vertices = np.asarray(ground['vertices'], dtype=np.float64).reshape(-1, 3)
        triangles = np.asarray(ground['triangles'], dtype=np.int64).reshape(-1, 3)
        self.ground_vertices = vertices
        self.ground_tri = vertices[triangles]
        self.ground_tree = shapely.STRtree(shapely.polygons(self.ground_tri[:, :, :2]))
        standing = np.zeros(len(triangles), dtype=bool)
        for index in ground.get('standingTriangles') or []:
            standing[index] = True
        self.ground_standing = standing

        supports = [s for s in raw['supports'] if s.get('automaticStandingAllowed')]
        self.support_ids = [s['id'] for s in supports]
        self.support_labels = [s.get('label') for s in supports]
        self.support_shapes = [shapely.make_valid(polygon(s)) for s in supports]
        self.support_tree = shapely.STRtree(self.support_shapes)
        self.support_rings = [[np.asarray(r, dtype=np.float64).reshape(-1, 2) for r in s['rings']]
                              for s in supports]
        self.support_surface = np.array(
            [float(s['surfaceElevationMeters']) if s.get('surfaceElevationMeters') is not None
             else float(s['heightAboveFloorMeters']) for s in supports])
        self.support_plane = np.full((len(supports), 3), np.nan)
        for i, support in enumerate(supports):
            if support.get('surfacePlane'):
                self.support_plane[i] = support['surfacePlane']
        self._meets = np.zeros(len(supports), dtype=bool)
        self._meets_known = np.zeros(len(supports), dtype=bool)

        self.bounds = self.receiver.bounds
        self.wall_count = len(walls)
        self.ink_ground = self._ink_ground()
        self.components, self.component_of = self._components()

    def _components(self):
        """Painted lines, rebuilt from the 1x1 pieces the partition cut them into.

        A piece on its own has no heading: the compiler splits one stroke into
        unit squares. Pieces of one stroke that touch and carry one height are
        the thing a reader sees on the map, so detectors that need a direction
        or two sides of a line work on these.
        """
        parent = list(range(self.wall_count))

        def root(node):
            while parent[node] != node:
                parent[node] = parent[parent[node]]
                node = parent[node]
            return node

        key = [(self.strokes[i], round(float(self.assigned_top[i]), 3),
                round(float(self.assigned_base[i]), 3)) for i in range(self.wall_count)]
        if self.wall_count:
            left, right = self.wall_tree.query(
                shapely.buffer(np.asarray(self.wall_shapes, dtype=object), TOUCH_SVG),
                predicate='intersects')
            for one, two in zip(left.tolist(), right.tolist()):
                if one != two and key[one] == key[two]:
                    a, b = root(one), root(two)
                    if a != b:
                        parent[a] = b
        members = defaultdict(list)
        for i in range(self.wall_count):
            members[root(i)].append(i)

        groups = list(members.values())
        shapes = [shapely.union_all([self.wall_shapes[i] for i in pieces]) for pieces in groups]
        centre, axis, short, long = rect_of(shapes)
        components, owner = [], np.full(self.wall_count, -1, dtype=np.int64)
        for index, (pieces, shape) in enumerate(zip(groups, shapes)):
            for piece in pieces:
                owner[piece] = index
            lead = max(pieces, key=lambda i: self.length[i])
            half = float(shape.length) / 2.0
            components.append(dict(
                index=index, pieces=pieces, lead=lead, shape=shape,
                stroke=self.strokes[lead], length=half, area=float(shape.area),
                centre=centre[index], axis=axis[index],
                short=float(short[index]), long=float(long[index]),
                # Curved strokes defeat a bounding rectangle; ink area over
                # centreline length is the width a painter would have drawn.
                width=float(shape.area) / half if half > 0 else float('inf'),
                floor=float(self.wall_floor[lead]),
                top=float(self.assigned_top[lead]),
                base=float(self.assigned_base[lead])))
        return components, owner

    def component_axis(self, pieces):
        """Unit normal of the painted line each piece belongs to."""
        out = np.zeros((len(pieces), 2))
        for i, piece in enumerate(pieces):
            axis = self.components[self.component_of[piece]]['axis']
            out[i] = (-axis[1], axis[0])
        return out

    def component_probes(self, components):
        """One floor point either side of each line, clear of every wall's ink."""
        count = len(components)
        base = np.zeros((count, 2))
        normal = np.zeros((count, 2))
        for i, component in enumerate(components):
            ring = shapely.get_coordinates(component['shape'])
            if len(ring) < 2:
                base[i] = component['centre']
                normal[i] = (0.0, 1.0)
                continue
            head, tail = ring[:-1], ring[1:]
            edge = tail - head
            length = np.hypot(edge[:, 0], edge[:, 1])
            pick = int(np.argmax(length))
            base[i] = (head[pick] + tail[pick]) / 2.0
            normal[i] = np.array([-edge[pick, 1], edge[pick, 0]]) / max(length[pick], 1e-9)
        left = np.full((count, 2), np.nan)
        right = np.full((count, 2), np.nan)
        thickness = np.array([c['short'] for c in components])
        for step in (0.6, 1.2, 2.0, 3.0, 4.0):
            for sign, target in ((1.0, left), (-1.0, right)):
                todo = np.flatnonzero(np.isnan(target[:, 0]))
                if not len(todo):
                    continue
                trial = base[todo] + normal[todo] * (sign * (thickness[todo] / 2.0 + step))[:, None]
                hit, _ = self.wall_tree.query(
                    shapely.points(trial[:, 0], trial[:, 1]), predicate='intersects')
                free = np.ones(len(todo), dtype=bool)
                free[np.unique(hit)] = False
                target[todo[free]] = trial[free]
        return left, right, normal

    def _ink_ground(self):
        """Reference ground under each piece's own ink, median of its outline.

        A single centroid reading is meaningless for a long perimeter stroke,
        whose centroid can sit in the middle of the map.
        """
        inside = shapely.point_on_surface(self.wall_shapes)
        sample_x = [shapely.get_x(inside)]
        sample_y = [shapely.get_y(inside)]
        coords, index = shapely.get_coordinates(self.wall_shapes, return_index=True)
        counts = np.bincount(index, minlength=self.wall_count)
        starts = np.cumsum(counts) - counts
        for step in range(8):
            take = starts + (counts * step) // 8
            take = np.clip(take, 0, max(len(coords) - 1, 0))
            chosen = coords[take]
            chosen[counts == 0] = np.nan
            sample_x.append(chosen[:, 0])
            sample_y.append(chosen[:, 1])
        flat_x = np.concatenate(sample_x)
        flat_y = np.concatenate(sample_y)
        usable = ~np.isnan(flat_x)
        height = np.full(len(flat_x), np.nan)
        height[usable], _ = self.ground_at(flat_x[usable], flat_y[usable])
        height = height.reshape(-1, self.wall_count)
        with np.errstate(invalid='ignore'):
            median = np.nanmedian(np.where(np.isnan(height), np.nan, height), axis=0)
        return median

    # ---------------------------------------------------------------- queries

    def ground_at(self, x, y):
        """Height of the lowest-indexed covering triangle, as the runtime reads it."""
        height = np.full(len(x), np.nan)
        which = np.full(len(x), -1, dtype=np.int64)
        if not len(x):
            return height, which
        points, tri = self.ground_tree.query(shapely.points(x, y), predicate='intersects')
        if not len(points):
            return height, which
        order = np.lexsort((tri, points))
        points, tri = points[order], tri[order]
        first = np.ones(len(points), dtype=bool)
        first[1:] = points[1:] != points[:-1]
        points, tri = points[first], tri[first]
        which[points] = tri
        height[points] = barycentric_z(self.ground_tri[tri], x[points], y[points])
        return height, which

    def support_surface_at(self, support, x, y):
        plane = self.support_plane[support]
        flat = np.isnan(plane[:, 0])
        value = plane[:, 0] * x + plane[:, 1] * y + plane[:, 2]
        return np.where(flat, self.support_surface[support], value)

    def blocks(self, wall, height):
        """The flat rule, per (wall, eye height) pair."""
        blocked = self.wall_unknown[wall].copy()
        counts = self.band_count[wall]
        if counts.sum():
            rows, offsets = group_offsets(counts)
            band = self.band_start[wall][rows] + offsets
            relative = height[rows] - self.wall_floor[wall][rows]
            bottom, top = self.band_bottom[band], self.band_top[band]
            inside = ((relative >= bottom) & (relative <= top)) | ((bottom == 0.0) & (relative < 0))
            blocked |= np.bincount(rows, weights=inside, minlength=len(wall)).astype(bool)
        return blocked

    def any_blocks(self, point, wall, height, count):
        """Per point: does any wall covering it block an eye at height[point]?"""
        if not len(point):
            return np.zeros(count, dtype=bool)
        hit = self.blocks(wall, height[point])
        return np.bincount(point, weights=hit, minlength=count) > 0

    def _cross_blocks(self, owner, height, point, wall, count):
        """Per (owner) probe: does any wall at its point block that probe's height?"""
        if not len(owner):
            return np.zeros(0, dtype=bool)
        if not len(point):
            return np.zeros(len(owner), dtype=bool)
        order = np.argsort(point, kind='stable')
        sorted_point, sorted_wall = point[order], wall[order]
        counts = np.bincount(sorted_point, minlength=count)
        starts = np.cumsum(counts) - counts
        local = counts[owner]
        if not local.sum():
            return np.zeros(len(owner), dtype=bool)
        rows, offsets = group_offsets(local)
        chosen = sorted_wall[starts[owner][rows] + offsets]
        hit = self.blocks(chosen, height[rows])
        return np.bincount(rows, weights=hit, minlength=len(owner)) > 0

    def meets_ground(self, support):
        """The runtime's buried-support guard: does the floor come to this level?"""
        if self._meets_known[support]:
            return bool(self._meets[support])
        shape = self.support_shapes[support]
        answer = False
        minx, miny, maxx, maxy = shape.bounds
        vertices = self.ground_vertices
        inside = ((vertices[:, 0] >= minx) & (vertices[:, 0] <= maxx) &
                  (vertices[:, 1] >= miny) & (vertices[:, 1] <= maxy))
        candidate = vertices[inside]
        if len(candidate):
            surface = self.support_surface_at(
                np.full(len(candidate), support), candidate[:, 0], candidate[:, 1])
            near = np.abs(candidate[:, 2] - surface) <= GROUND_MEETING_M
            if near.any():
                near = candidate[near]
                answer = bool(shapely.contains_xy(shape, near[:, 0], near[:, 1]).any())
        if not answer:
            samples = []
            for ring in self.support_rings[support]:
                head, tail = ring, np.roll(ring, -1, axis=0)
                edge = tail - head
                length = np.linalg.norm(edge, axis=1)
                for i in range(len(ring)):
                    if length[i] == 0:
                        continue
                    steps = max(1, int(math.ceil(length[i])))
                    fraction = (np.arange(steps + 1) / steps)[:, None]
                    along = head[i] + edge[i] * fraction
                    normal = np.array([-edge[i, 1], edge[i, 0]]) / length[i]
                    samples.append(along + normal * 0.3)
                    samples.append(along - normal * 0.3)
            if samples:
                probe = np.vstack(samples)
                surface = self.support_surface_at(
                    np.full(len(probe), support), probe[:, 0], probe[:, 1])
                reference, _ = self.ground_at(probe[:, 0], probe[:, 1])
                answer = bool(np.any(np.abs(reference - surface) <= GROUND_MEETING_M))
        self._meets[support] = answer
        self._meets_known[support] = True
        return answer

    def levels(self, x, y):
        """Reference ground, automatic standing eye and chosen support per point.

        Mirrors SvgHeightVisibility.automaticSupportAt for a version-3 model:
        the physical ground opens the choice, a blocked eye closes it, and a
        support far under a clear reference floor only counts if it meets the
        ground somewhere.
        """
        count = len(x)
        result = dict(
            on_floor=np.zeros(count, dtype=bool),
            ground=np.full(count, np.nan),
            eye=np.full(count, np.nan),
            support=np.full(count, -1, dtype=np.int64))
        if not count:
            return result
        in_receiver = shapely.contains_xy(self.receiver, x, y)
        ground, triangle = self.ground_at(x, y)
        result['ground'] = ground
        floor = in_receiver & ~np.isnan(ground)
        result['on_floor'] = floor
        index = np.flatnonzero(floor)
        if not len(index):
            return result
        px, py = x[index], y[index]
        points = shapely.points(px, py)
        wall_point, wall_index = self.wall_tree.query(points, predicate='intersects')

        # clearEye takes a standing surface and asks about the eye above it.
        standing = self.ground_standing[triangle[index]]
        start = np.where(standing, ground[index], -np.inf)
        clear_start = ~self.any_blocks(wall_point, wall_index, start + self.camera, len(index))
        elevation = np.where(clear_start, start, -np.inf)
        reference = ground[index]
        clear_reference = ~self.any_blocks(
            wall_point, wall_index, reference + self.camera, len(index))
        floor_limit = np.where(clear_reference, reference - BURIED_SUPPORT_M, -np.inf)

        surface = reference.copy()
        chosen = np.full(len(index), -1, dtype=np.int64)
        support_point, support_index = self.support_tree.query(points, predicate='intersects')
        if len(support_point):
            height = self.support_surface_at(support_index, px[support_point], py[support_point])
            allowed = height >= floor_limit[support_point]
            for support in np.unique(support_index[~allowed]):
                self.meets_ground(int(support))
            allowed |= self._meets[support_index]
            allowed &= ~self._cross_blocks(
                support_point, height + self.camera, wall_point, wall_index, len(index))
            ranked = np.where(allowed, height, -np.inf)
            order = np.lexsort((ranked, support_point))
            owner = support_point[order]
            best = np.ones(len(owner), dtype=bool)
            best[:-1] = owner[:-1] != owner[1:]
            owner = owner[best]
            top = ranked[order][best]
            pick = support_index[order][best]
            taken = top > elevation[owner]
            surface[owner[taken]] = top[taken]
            chosen[owner[taken]] = pick[taken]
        result['eye'][index] = surface + self.camera
        result['support'][index] = chosen
        return result

    def support_name(self, index):
        return 'ground' if index < 0 else self.support_ids[index]

    def support_label(self, index):
        return 'ground' if index < 0 else (self.support_labels[index] or 'unlabelled')

    # ------------------------------------------------------------------ poses

    def poses(self, targets, directions):
        """A floor stance 6-12 SVG units off each target, looking at it.

        `directions` is (N, K, 2); the first candidate that lands on walkable
        floor outside every wall wins, nearest first.
        """
        count = len(targets)
        if not count:
            return [None] * count
        away = np.concatenate([directions, -directions], axis=1)
        candidates = np.concatenate(
            [targets[:, None, :] + away * distance for distance in POSE_DISTANCES], axis=1)
        flat = candidates.reshape(-1, 2)
        level = self.levels(flat[:, 0], flat[:, 1])
        good = level['on_floor'] & ~np.isnan(level['eye'])
        if good.any():
            hits = np.flatnonzero(good)
            wall_hit, _ = self.wall_tree.query(
                shapely.points(flat[hits, 0], flat[hits, 1]), predicate='intersects')
            good[hits[np.unique(wall_hit)]] = False
        good = good.reshape(count, -1)
        out = []
        for i in range(count):
            where = np.flatnonzero(good[i])
            if not len(where):
                out.append(None)
                continue
            point = candidates[i, where[0]]
            delta = targets[i] - point
            out.append(dict(x=round(float(point[0]), 1), y=round(float(point[1]), 1),
                            facingDeg=round(float(math.degrees(math.atan2(delta[1], delta[0]))) % 360, 1)))
        return out


# --------------------------------------------------------------- 3D measuring

def measure_columns(side, scene, alignment):
    """Narrow-footprint column top and sub-base 3D fill for every wall piece."""
    inverse, offset, _ = inverse_affine(alignment[f'nativeTo{side.side.capitalize()}Svg'])
    column_top = np.full(side.wall_count, np.nan)
    under_fill = np.zeros(side.wall_count)
    under_faces = np.zeros(side.wall_count, dtype=np.int64)
    ground = side.ink_ground
    base = np.where(np.isnan(ground), side.wall_floor, ground)

    wanted = np.flatnonzero(np.isfinite(side.assigned_top) | (side.assigned_base > -np.inf))
    footprints = [to_native(side.wall_shapes[i].buffer(BUFFER_SVG), inverse, offset)
                  for i in wanted]
    for start in range(0, len(wanted), WALL_CHUNK):
        chunk = wanted[start:start + WALL_CHUNK]
        shapes = footprints[start:start + WALL_CHUNK]
        pairs = scene.tree.query(np.asarray(shapes, dtype=object))
        for local, wall in enumerate(chunk):
            candidates = pairs[1][pairs[0] == local]
            if not len(candidates):
                continue
            hit = candidates[shapely.intersects(
                shapely.polygons(scene.tri_xy[candidates]), shapes[local])]
            if not len(hit):
                continue
            solid = scene.solidish[hit]
            if not solid.any():
                continue
            floor = float(base[wall])
            stack = hit[solid]
            slab = hit[~solid & (scene.bottom[hit] > floor + 0.3)]
            stacked = np.concatenate([stack, slab]) if len(slab) else stack
            runs = column_runs(floor, scene.bottom[stacked], scene.top[stacked])
            if runs:
                column_top[wall] = runs[0][1]
            top = float(side.assigned_base[wall])
            if np.isfinite(top) and top - floor > LIFTED_BASE_M:
                under = stack[(scene.top[stack] > floor + 0.1) & (scene.bottom[stack] < top - 0.1)]
                under_faces[wall] = len(under)
                under_fill[wall] = occupancy_fraction(
                    floor + 0.05, top - 0.05,
                    np.maximum(scene.bottom[under], floor), np.minimum(scene.top[under], top))
    return dict(column_top=column_top, under_fill=under_fill,
                under_faces=under_faces, ground=ground)


# ------------------------------------------------------------------ detectors

def detect_borrowed_height(side, measured):
    column = measured['column_top']
    finite = np.isfinite(side.assigned_top) & ~np.isnan(column)
    delta = np.where(finite, side.assigned_top - column, -np.inf)
    candidate = np.flatnonzero(finite & side.thin & (delta >= BORROWED_DROP_M))
    if not len(candidate):
        return []
    agrees = finite & (np.abs(side.assigned_top - column) < NEIGHBOUR_AGREE_M)
    disagrees = finite & (delta >= BORROWED_DROP_M)

    probes = shapely.buffer(
        np.asarray([side.wall_shapes[i] for i in candidate], dtype=object), TOUCH_SVG)
    local, neighbour = side.wall_tree.query(probes, predicate='intersects')
    isolated, witness = [], {}
    for i in range(len(candidate)):
        wall = candidate[i]
        touching = [n for n in neighbour[local == i]
                    if n != wall and side.strokes[n] == side.strokes[wall]]
        good = [n for n in touching if agrees[n]]
        if not good or any(disagrees[n] for n in touching):
            continue
        isolated.append(wall)
        witness[wall] = good
    if not isolated:
        return []

    grouped = defaultdict(list)
    for wall in isolated:
        grouped[side.strokes[wall]].append(wall)
    rows, targets, axes = [], [], []
    for stroke, pieces in grouped.items():
        pieces = sorted(pieces, key=lambda w: -side.length[w])
        lead = pieces[0]
        union = shapely.union_all([side.wall_shapes[w] for w in pieces])
        point = union.centroid
        neighbours = sorted({n for w in pieces for n in witness[w]})
        rows.append(dict(
            detector='borrowed-height', wallId=side.wall_ids[lead], stroke=stroke,
            pieces=[side.wall_ids[w] for w in pieces],
            centroid=[round(point.x, 2), round(point.y, 2)],
            lengthSvg=round(float(sum(side.length[w] for w in pieces)), 2),
            evidence=dict(
                assignedTopM=round(float(side.assigned_top[lead]), 2),
                measuredColumnTopM=round(float(column[lead]), 2),
                dropM=round(float(delta[lead]), 2),
                maxDropM=round(float(max(delta[w] for w in pieces)), 2),
                groundM=None if np.isnan(measured['ground'][lead]) else round(float(measured['ground'][lead]), 2),
                agreeingNeighbours=[side.wall_ids[n] for n in neighbours[:4]],
                neighbourAssignedTopM=[round(float(side.assigned_top[n]), 2) for n in neighbours[:4]],
                neighbourColumnTopM=[round(float(column[n]), 2) for n in neighbours[:4]])))
        targets.append(side.ink_point[lead])
        axes.append(side.component_axis(np.array([lead]))[0][None, :])
    for row, pose in zip(rows, side.poses(np.asarray(targets), np.asarray(axes))):
        row['pose'] = pose
    return rows


def detect_low_cover(side):
    """Chest-high cover whose top lands in the window that makes it opaque.

    The flat rule has no crouching and no partial cover: a top at 1.8 m over
    the floor stops a 1.75 m eye exactly as a building does. These are the
    lines where that convention decides the sightline.
    """
    lines = [c for c in side.components if np.isfinite(c['top'])]
    if not lines:
        return []
    left, right, normal = side.component_probes(lines)
    usable = np.flatnonzero(~np.isnan(left[:, 0]) & ~np.isnan(right[:, 0]))
    if not len(usable):
        return []
    lines = [lines[i] for i in usable]
    left, right, normal = left[usable], right[usable], normal[usable]
    one = side.levels(left[:, 0], left[:, 1])
    two = side.levels(right[:, 0], right[:, 1])
    top = np.array([c['top'] for c in lines])
    base = np.array([c['base'] for c in lines])
    leads = np.array([c['lead'] for c in lines])
    with np.errstate(invalid='ignore'):
        over_one, over_two = top - one['ground'], top - two['ground']
        window = ((over_one >= LOW_COVER_MIN_M) & (over_one <= LOW_COVER_MAX_M) &
                  (over_two >= LOW_COVER_MIN_M) & (over_two <= LOW_COVER_MAX_M))
        grounded = base <= np.fmin(one['ground'], two['ground']) + LIFTED_BASE_M
    ok = one['on_floor'] & two['on_floor'] & ~np.isnan(one['eye']) & ~np.isnan(two['eye'])
    eye_one = np.where(np.isnan(one['eye']), -np.inf, one['eye'])
    eye_two = np.where(np.isnan(two['eye']), -np.inf, two['eye'])
    blocks = side.blocks(leads, eye_one) & side.blocks(leads, eye_two)
    hit = np.flatnonzero(ok & window & grounded & blocks)
    if not len(hit):
        return []
    rows = []
    for i in hit:
        component = lines[i]
        point = component['shape'].centroid
        rows.append(dict(
            detector='low-cover-blocks-standing', wallId=side.wall_ids[component['lead']],
            stroke=component['stroke'],
            pieces=[side.wall_ids[w] for w in component['pieces'][:8]],
            centroid=[round(point.x, 2), round(point.y, 2)],
            lengthSvg=round(float(component['length']), 2),
            evidence=dict(
                assignedTopM=round(float(top[i]), 2),
                overGroundOneM=round(float(over_one[i]), 2),
                overGroundTwoM=round(float(over_two[i]), 2),
                eyeOverGroundM=round(float(min(one['eye'][i] - one['ground'][i],
                                               two['eye'][i] - two['ground'][i])), 2),
                clearsEyeByM=round(float(min(over_one[i], over_two[i]) - side.camera), 2),
                widthSvg=round(float(component['width']), 2),
                pieceCount=len(component['pieces']))))
    targets = np.array([lines[i]['centre'] for i in hit])
    for row, pose in zip(rows, side.poses(targets, normal[hit][:, None, :])):
        row['pose'] = pose
    return rows


def detect_see_under(side, measured):
    base = side.assigned_base
    ground = measured['ground']
    # A band bottom of zero reaches down past its floor by the runtime's own
    # rule, so only a bottom lifted off its floor can be an opening at all.
    lintel = np.isfinite(base) & (base > side.wall_floor + 1e-6)
    lifted = lintel & ~np.isnan(ground) & ((base - ground) > LIFTED_BASE_M)
    solid = (measured['under_fill'] >= UNDER_SOLID_FRACTION) & (measured['under_faces'] >= UNDER_MIN_FACES)
    hit = np.flatnonzero(lifted & solid)
    if not len(hit):
        return []
    # A band lifted off the floor only opens a sightline when no other painted
    # ink over the same footprint stops the eye standing on the ground below.
    shapes = np.asarray([side.wall_shapes[w] for w in hit], dtype=object)
    local, other = side.wall_tree.query(shapes, predicate='intersects')
    covered = np.zeros(len(hit), dtype=bool)
    if len(local):
        own = hit[local]
        overlap = shapely.area(shapely.intersection(
            np.asarray([side.wall_shapes[w] for w in own], dtype=object),
            np.asarray([side.wall_shapes[w] for w in other], dtype=object)))
        real = (own != other) & (overlap > 0.1 * np.maximum(side.area[own], 1e-9))
        if real.any():
            blocked = side.blocks(other[real], ground[own[real]] + side.camera)
            covered[np.unique(local[real][blocked])] = True
    hit = hit[~covered]
    if not len(hit):
        return []
    rows = []
    for wall in hit:
        rows.append(dict(
            detector='see-under', wallId=side.wall_ids[wall], stroke=side.strokes[wall],
            centroid=[round(float(side.centroid[wall, 0]), 2), round(float(side.centroid[wall, 1]), 2)],
            lengthSvg=round(float(side.length[wall]), 2),
            evidence=dict(
                bandBaseM=round(float(base[wall]), 2),
                groundM=round(float(ground[wall]), 2),
                openingM=round(float(base[wall] - ground[wall]), 2),
                solidFractionUnderBase=round(float(measured['under_fill'][wall]), 2),
                facesUnderBase=int(measured['under_faces'][wall]),
                assignedTopM=None if not np.isfinite(side.assigned_top[wall])
                else round(float(side.assigned_top[wall]), 2))))
    targets = side.ink_point[hit]
    axes = side.component_axis(hit)[:, None, :]
    for row, pose in zip(rows, side.poses(targets, axes)):
        row['pose'] = pose
    return rows


def detect_marking_as_wall(side):
    """Parallel lines over flat ground beside a slope: a ramp drawn as walls.

    A staircase painted as a run of steps becomes a run of opaque strokes. The
    tell is that the ground between the lines is flat and the ground beyond
    them climbs, which is a ramp seen from above, not a pair of walls.
    """
    lines = [c for c in side.components
             if np.isfinite(c['top']) and c['width'] <= THIN_SVG
             and c['long'] >= 3.0 and c['short'] > 0 and c['long'] / c['short'] >= 2.5]
    if len(lines) < 2:
        return []
    shapes = np.asarray([c['shape'] for c in lines], dtype=object)
    tree = shapely.STRtree(shapes)
    left, right = tree.query(shapely.buffer(shapes, PAIR_MAX_SVG), predicate='intersects')
    seen, pairs = set(), []
    for one, two in zip(left.tolist(), right.tolist()):
        if one == two:
            continue
        key = (min(one, two), max(one, two))
        if key not in seen:
            seen.add(key)
            pairs.append(key)
    if not pairs:
        return []

    first = np.array([p[0] for p in pairs])
    second = np.array([p[1] for p in pairs])
    centre = np.array([c['centre'] for c in lines])
    axis = np.array([c['axis'] for c in lines])
    extent = np.array([c['long'] for c in lines])
    tops = np.array([c['top'] for c in lines])
    leads = np.array([c['lead'] for c in lines])
    parallel = np.abs((axis[first] * axis[second]).sum(axis=1))
    normal = np.stack([-axis[first, 1], axis[first, 0]], axis=1)
    delta = centre[second] - centre[first]
    across = np.abs((delta * normal).sum(axis=1))
    along = np.abs((delta * axis[first]).sum(axis=1))
    keep = np.flatnonzero(
        (parallel >= math.cos(math.radians(PAIR_PARALLEL_DEG))) &
        (across >= PAIR_MIN_SVG) & (across <= PAIR_MAX_SVG) &
        (along <= (extent[first] + extent[second]) / 4.0))
    if not len(keep):
        return []
    first, second, normal, across = first[keep], second[keep], normal[keep], across[keep]
    outward = normal * np.where((delta[keep] * normal).sum(axis=1) < 0, 1.0, -1.0)[:, None]
    middle = (centre[first] + centre[second]) / 2.0
    heading = axis[first]
    span = np.minimum(extent[first], extent[second]) / 2.0

    offsets = np.linspace(-0.8, 0.8, 5)
    samples = middle[:, None, :] + heading[:, None, :] * (span[:, None, None] * offsets[None, :, None])
    flat = samples.reshape(-1, 2)
    level = side.levels(flat[:, 0], flat[:, 1])
    on_floor = level['on_floor'].reshape(len(first), -1)
    ground = level['ground'].reshape(len(first), -1)
    eye = level['eye'].reshape(len(first), -1)
    middle_index = ground.shape[1] // 2
    ok = on_floor.all(axis=1) & ~np.isnan(eye).any(axis=1)
    with np.errstate(invalid='ignore'):
        continuous = (np.nanmax(ground, axis=1) - np.nanmin(ground, axis=1)) <= PAIR_FLAT_M
    middle_eye = np.where(np.isnan(eye[:, middle_index]), -np.inf, eye[:, middle_index])
    blocks = side.blocks(leads[first], middle_eye) & side.blocks(leads[second], middle_eye)

    reach = across[:, None] / 2.0 + SLOPE_PROBE_SVG
    far_one, far_two = middle + outward * reach, middle - outward * reach
    one = side.levels(far_one[:, 0], far_one[:, 1])
    two = side.levels(far_two[:, 0], far_two[:, 1])
    middle_ground = ground[:, middle_index]
    with np.errstate(invalid='ignore'):
        climb_one = np.where(one['on_floor'], np.abs(one['ground'] - middle_ground), 0.0)
        climb_two = np.where(two['on_floor'], np.abs(two['ground'] - middle_ground), 0.0)
    climb = np.fmax(np.nan_to_num(climb_one), np.nan_to_num(climb_two))
    hit = np.flatnonzero(ok & continuous & blocks & (climb >= SLOPE_M))
    if not len(hit):
        return []

    grouped = defaultdict(list)
    for i in hit:
        grouped[tuple(sorted((lines[first[i]]['stroke'], lines[second[i]]['stroke'])))].append(i)
    rows, targets, axes = [], [], []
    for strokes, items in grouped.items():
        lead = max(items, key=lambda i: extent[first[i]] + extent[second[i]])
        label = (' + '.join(strokes) if strokes[0] != strokes[1]
                 else f'{strokes[0]} (two heights)')
        rows.append(dict(
            detector='marking-as-wall', wallId=side.wall_ids[leads[first[lead]]],
            stroke=label,
            pieces=[side.wall_ids[leads[first[lead]]], side.wall_ids[leads[second[lead]]]],
            centroid=[round(float(middle[lead, 0]), 2), round(float(middle[lead, 1]), 2)],
            lengthSvg=round(float(sum(lines[first[i]]['length'] + lines[second[i]]['length']
                                      for i in items)), 2),
            evidence=dict(
                pairs=len(items),
                separationSvg=round(float(across[lead]), 2),
                lineLengthSvg=[round(float(extent[first[lead]]), 2),
                               round(float(extent[second[lead]]), 2)],
                assignedTopM=[round(float(tops[first[lead]]), 2),
                              round(float(tops[second[lead]]), 2)],
                groundBetweenM=round(float(middle_ground[lead]), 2),
                groundRangeBetweenM=round(float(
                    np.nanmax(ground[lead]) - np.nanmin(ground[lead])), 2),
                climbAcross8UnitsM=round(float(climb[lead]), 2),
                eyeM=round(float(middle_eye[lead]), 2))))
        targets.append(middle[lead])
        axes.append(outward[lead][None, :])
    for row, pose in zip(rows, side.poses(np.asarray(targets), np.asarray(axes))):
        row['pose'] = pose
    return rows


def _ray_hits(side, origin, direction, low, high):
    """Edge crossings of each ray within [low, high), as (ray, wall, distance)."""
    head = origin + direction * low
    tail = origin + direction * high
    lines = shapely.linestrings(
        np.stack([head, tail], axis=1).reshape(-1, 2),
        indices=np.repeat(np.arange(len(origin)), 2))
    ray, edge = side.edge_tree.query(lines)
    if not len(ray):
        return np.zeros(0, np.int64), np.zeros(0, np.int64), np.zeros(0)
    o, d = origin[ray], direction[ray]
    a, b = side.edge_a[edge], side.edge_b[edge]
    span = b - a
    denominator = d[:, 0] * span[:, 1] - d[:, 1] * span[:, 0]
    usable = np.abs(denominator) > 1e-12
    safe = np.where(usable, denominator, 1.0)
    delta = a - o
    distance = (delta[:, 0] * span[:, 1] - delta[:, 1] * span[:, 0]) / safe
    fraction = (delta[:, 0] * d[:, 1] - delta[:, 1] * d[:, 0]) / safe
    good = usable & (fraction >= 0) & (fraction <= 1) & (distance >= low) & (distance < high)
    return ray[good], side.edge_wall[edge[good]], distance[good]


def detect_edge_reach(side):
    minx, miny, maxx, maxy = side.bounds
    xs = np.arange(minx, maxx + REACH_STEP_SVG, REACH_STEP_SVG)
    ys = np.arange(miny, maxy + REACH_STEP_SVG, REACH_STEP_SVG)
    grid_x, grid_y = (v.ravel() for v in np.meshgrid(xs, ys))
    level = side.levels(grid_x, grid_y)
    cells = np.flatnonzero(level['on_floor'] & ~np.isnan(level['eye']))
    if not len(cells):
        return []
    headings = np.arange(REACH_HEADINGS) * (360.0 / REACH_HEADINGS)
    origin = np.repeat(np.stack([grid_x[cells], grid_y[cells]], axis=1), REACH_HEADINGS, axis=0)
    heading = np.tile(headings, len(cells))
    direction = np.stack([np.cos(np.radians(heading)), np.sin(np.radians(heading))], axis=1)
    eye = np.repeat(level['eye'][cells], REACH_HEADINGS)

    active = np.arange(len(origin))
    hit_wall = np.full(len(origin), -1, dtype=np.int64)
    hit_distance = np.full(len(origin), np.inf)
    crossed = np.zeros(len(origin), dtype=bool)
    band = 0.0
    while band < REACH_RANGE_SVG and len(active):
        high = min(band + REACH_BAND_SVG, REACH_RANGE_SVG)
        ray, wall, distance = _ray_hits(side, origin[active], direction[active], band, high)
        if len(ray):
            blocking = side.blocks(wall, eye[active][ray])
            first = np.full(len(active), np.inf)
            np.minimum.at(first, ray[blocking], distance[blocking])
            over = (~blocking & np.isfinite(side.assigned_top[wall]) &
                    (side.assigned_top[wall] < eye[active][ray]) & (distance < first[ray]))
            if over.any():
                crossed[active[np.unique(ray[over])]] = True
            resolved = np.flatnonzero(np.isfinite(first))
            if len(resolved):
                order = np.lexsort((distance[blocking], ray[blocking]))
                rays_sorted = ray[blocking][order]
                lead = np.ones(len(rays_sorted), dtype=bool)
                lead[1:] = rays_sorted[1:] != rays_sorted[:-1]
                picked = rays_sorted[lead]
                hit_wall[active[picked]] = wall[blocking][order][lead]
                hit_distance[active[picked]] = distance[blocking][order][lead]
                active = np.delete(active, resolved)
        band = high

    far = (hit_wall >= 0) & (hit_distance > REACH_FAR_SVG) & crossed
    stats = dict(raysCast=len(origin),
                 raysUnstopped=int((hit_wall < 0).sum()),
                 longSightlinesOverALowWall=int(far.sum()),
                 blockedByFloorBoundaryWall=int((far & ~side.wall_exterior[np.maximum(hit_wall, 0)]).sum()),
                 survivors=0)
    survivors = np.flatnonzero(far & side.wall_exterior[np.maximum(hit_wall, 0)])
    stats['survivors'] = len(survivors)
    if not len(survivors):
        return [], stats
    grouped = defaultdict(list)
    for index in survivors:
        grouped[int(hit_wall[index])].append(index)
    rows = []
    for wall, items in grouped.items():
        lead = max(items, key=lambda i: hit_distance[i])
        rows.append(dict(
            detector='edge-reach', wallId=side.wall_ids[wall], stroke=side.strokes[wall],
            centroid=[round(float(side.centroid[wall, 0]), 2), round(float(side.centroid[wall, 1]), 2)],
            lengthSvg=round(float(hit_distance[lead]), 2),
            evidence=dict(
                rays=len(items),
                firstHitDistanceSvg=round(float(hit_distance[lead]), 2),
                eyeM=round(float(eye[lead]), 2),
                originSvg=[round(float(origin[lead, 0]), 1), round(float(origin[lead, 1]), 1)],
                headingDeg=round(float(heading[lead]), 1),
                blockerOutsideReceiver=True,
                blockerGapToFloorSvg=round(float(
                    shapely.distance(side.wall_shapes[wall], side.receiver)), 2)),
            pose=dict(x=round(float(origin[lead, 0]), 1), y=round(float(origin[lead, 1]), 1),
                      facingDeg=round(float(heading[lead]), 1))))
    return rows, stats


def detect_level_jump(side):
    minx, miny, maxx, maxy = side.bounds
    xs = np.arange(minx, maxx + JUMP_STEP_SVG, JUMP_STEP_SVG)
    ys = np.arange(miny, maxy + JUMP_STEP_SVG, JUMP_STEP_SVG)
    columns, rows_count = len(xs), len(ys)
    grid_x, grid_y = (v.ravel() for v in np.meshgrid(xs, ys))
    level = side.levels(grid_x, grid_y)
    eye = np.where(level['on_floor'], level['eye'], np.nan)
    ground = np.where(level['on_floor'], level['ground'], np.nan)
    support = level['support']

    index = np.arange(columns * rows_count).reshape(rows_count, columns)
    pairs = []
    for shift, axis in ((1, 1), (1, 0)):
        here = index[:, :-1] if axis == 1 else index[:-1, :]
        there = index[:, 1:] if axis == 1 else index[1:, :]
        pairs.append(np.stack([here.ravel(), there.ravel()], axis=1))
    pairs = np.vstack(pairs)
    one, two = pairs[:, 0], pairs[:, 1]
    with np.errstate(invalid='ignore'):
        keep = np.flatnonzero(
            ~np.isnan(eye[one]) & ~np.isnan(eye[two]) &
            (np.abs(ground[one] - ground[two]) <= JUMP_GROUND_M) &
            (np.abs(eye[one] - eye[two]) >= JUMP_EYE_M) &
            (support[one] != support[two]))
    if not len(keep):
        return []
    one, two = one[keep], two[keep]
    head = np.stack([grid_x[one], grid_y[one]], axis=1)
    tail = np.stack([grid_x[two], grid_y[two]], axis=1)
    direction = tail - head
    span = np.linalg.norm(direction, axis=1)
    unit = direction / span[:, None]
    ray, wall, distance = _ray_hits(side, head, unit, 0.0, float(span.max()) + 1e-9)
    separated = np.zeros(len(one), dtype=bool)
    if len(ray):
        within = distance <= span[ray]
        ray, wall = ray[within], wall[within]
        blocked = side.blocks(wall, eye[one][ray]) | side.blocks(wall, eye[two][ray])
        if blocked.any():
            separated[np.unique(ray[blocked])] = True
    live = np.flatnonzero(~separated)
    if not len(live):
        return []

    grouped = defaultdict(list)
    for i in live:
        high, low = (one[i], two[i]) if eye[one[i]] >= eye[two[i]] else (two[i], one[i])
        grouped[(side.support_name(support[high]), side.support_name(support[low]))].append((i, high, low))
    rows, targets, axes = [], [], []
    for (upper, lower), items in grouped.items():
        lead, high, low = max(items, key=lambda item: abs(eye[one[item[0]]] - eye[two[item[0]]]))
        middle = (np.array([grid_x[high], grid_y[high]]) + np.array([grid_x[low], grid_y[low]])) / 2.0
        centre = (float(np.mean([grid_x[h] for _, h, _ in items])),
                  float(np.mean([grid_y[h] for _, h, _ in items])))
        rows.append(dict(
            detector='level-jump-on-flat', wallId=None, stroke=f'{upper} over {lower}',
            centroid=[round(float(middle[0]), 2), round(float(middle[1]), 2)],
            lengthSvg=round(float(len(items) * JUMP_STEP_SVG), 2),
            evidence=dict(
                cells=len(items),
                upperSupport=upper,
                upperSupportLabel=side.support_label(support[high]),
                lowerSupport=lower,
                lowerSupportLabel=side.support_label(support[low]),
                upperEyeM=round(float(eye[high]), 2),
                lowerEyeM=round(float(eye[low]), 2),
                eyeStepM=round(float(abs(eye[high] - eye[low])), 2),
                groundM=round(float(ground[high]), 2),
                groundDeltaM=round(float(abs(ground[high] - ground[low])), 2),
                clusterCentreSvg=[round(centre[0], 1), round(centre[1], 1)])))
        targets.append(middle)
        step = np.array([grid_x[high] - grid_x[low], grid_y[high] - grid_y[low]])
        norm = float(np.hypot(*step)) or 1.0
        axes.append((step / norm)[None, :])
    for row, pose in zip(rows, side.poses(np.asarray(targets), np.asarray(axes))):
        row['pose'] = pose
    return rows


# -------------------------------------------------------------------- reports

def write_summary(out_dir, report, notes, elapsed, skipped):
    lines = [
        '# Wall-height anomalies in the bundled SVG-height models', '',
        'Candidates for review, not verdicts. The runtime rule under every number '
        'here is the flat one: a wall blocks an eye when the eye height lies inside '
        'one of its bands above that wall\'s floor, and the eye is the standing '
        f'surface plus the camera height.  Full run {elapsed / 60:.1f} minutes.', '',
        'Detectors:', '',
        '* **borrowed-height** — a thin piece whose band top clears the 3D column '
        f'under its own ink by {BORROWED_DROP_M} m or more while its touching '
        'neighbours on the same stroke match the 3D. Grouped per stroke.',
        '* **low-cover-blocks-standing** — band top '
        f'{LOW_COVER_MIN_M}–{LOW_COVER_MAX_M} m over the local ground on both sides, '
        'and still opaque to a standing eye. A convention question, not a bug.',
        f'* **see-under** — lowest band bottom more than {LIFTED_BASE_M} m off the '
        'local ground with solid 3D geometry filling the gap.',
        f'* **marking-as-wall** — two thin parallel strokes {PAIR_MIN_SVG}–{PAIR_MAX_SVG} '
        'SVG apart, both opaque at standing height, flat ground between them and a '
        f'{SLOPE_M} m climb across {SLOPE_PROBE_SVG:.0f} units on one side.',
        f'* **edge-reach** — a ray from a floor cell that passes over a wall whose top '
        f'is under the eye and is first stopped more than {REACH_FAR_SVG:.0f} units away '
        'by a wall detached from the painted floor.',
        f'* **level-jump-on-flat** — neighbouring floor cells within {JUMP_GROUND_M} m '
        f'of ground whose automatic standing eye differs by {JUMP_EYE_M} m with no '
        'wall between them. Grouped by the supports that differ.', '',
        'lengthSvg is painted stroke length for the wall detectors, sightline '
        'distance for edge-reach, and cluster extent (cells x grid step) for '
        'level-jump-on-flat.', '']
    if skipped:
        lines += [f'Piece detectors skipped on the outline-blob model: {", ".join(sorted(skipped))}.', '']

    lines += ['| map/side | ' + ' | '.join(DETECTORS) + ' |',
              '|---|' + '---|' * len(DETECTORS)]
    totals = defaultdict(int)
    for (map_name, side), rows in report.items():
        counts = defaultdict(int)
        for row in rows:
            counts[row['detector']] += 1
            totals[row['detector']] += 1
        lines.append(f'| {map_name}/{side} | ' +
                     ' | '.join(str(counts[name]) for name in DETECTORS) + ' |')
    lines.append('| **all** | ' + ' | '.join(f'**{totals[name]}**' for name in DETECTORS) + ' |')
    lines.append('')

    if notes:
        lines += ['## edge-reach: the perimeter seal, confirmed', '',
                  'A wall piece counts as receiver-exterior only when its ink is '
                  'detached from the painted floor, because ordinary wall ink bounds '
                  'the floor and sits just outside the fill. The middle column is the '
                  'loose reading: every long sightline over a low wall, whatever '
                  'stopped it. The last column shows how many of those ended on a wall '
                  'that does bound the floor, which is the seal doing its job.', '',
                  '| map/side | rays | unstopped at 100 | long over a low wall | '
                  'stopped by a floor-bounding wall | survivors |',
                  '|---|---|---|---|---|---|']
        for (map_name, side), stat in notes.items():
            lines.append(f'| {map_name}/{side} | {stat["raysCast"]} | {stat["raysUnstopped"]} | '
                         f'{stat["longSightlinesOverALowWall"]} | '
                         f'{stat["blockedByFloorBoundaryWall"]} | {stat["survivors"]} |')
        lines.append('')

    everything = [row for rows in report.values() for row in rows]
    for name in DETECTORS:
        picks = sorted((r for r in everything if r['detector'] == name),
                       key=lambda r: -r['lengthSvg'])[:5]
        lines += [f'## {name}: five largest', '']
        if not picks:
            lines += ['None found.', '']
            continue
        keys = sorted({k for row in picks for k in row['evidence']})
        lines.append('| map/side | wall / group | length | at | pose | ' + ' | '.join(keys) + ' |')
        lines.append('|---|---|---|---|---|' + '---|' * len(keys))
        for row in picks:
            pose = row['pose']
            pose_text = ('-' if pose is None
                         else f'{pose["x"]},{pose["y"]} @ {pose["facingDeg"]}deg')
            values = ' | '.join(str(row['evidence'].get(k, '')) for k in keys)
            lines.append(
                f'| {row["map"]}/{row["side"]} | {row["stroke"]} | {row["lengthSvg"]:.0f} | '
                f'{row["centroid"][0]:.0f},{row["centroid"][1]:.0f} | {pose_text} | {values} |')
        lines.append('')
    (out_dir / 'summary.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')


def write_poses(out_dir, report, limit=6):
    poses = {}
    for (map_name, side), rows in report.items():
        chosen = []
        for name in DETECTORS:
            ranked = sorted((r for r in rows if r['detector'] == name and r['pose']),
                            key=lambda r: -r['lengthSvg'])[:limit]
            chosen += [f'{r["pose"]["x"]},{r["pose"]["y"]},{r["pose"]["facingDeg"]}' for r in ranked]
        if chosen:
            poses[f'{map_name}/{side}'] = chosen
    (out_dir / 'poses.json').write_text(json.dumps(poses, indent=1) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument('--maps', nargs='*', default=MAPS)
    parser.add_argument('--sides', nargs='*', default=SIDES)
    parser.add_argument('--detectors', nargs='*', default=DETECTORS)
    parser.add_argument('--out', default=None)
    args = parser.parse_args()

    root = Path(args.root)
    out_dir = Path(args.out) if args.out else root / 'work' / 'anomalies'
    out_dir.mkdir(parents=True, exist_ok=True)
    wanted = set(args.detectors)

    started = time.time()
    report, notes, skipped = {}, {}, set()
    for map_name in args.maps:
        blob = map_name in BLOB_MAPS
        needs_scene = bool(wanted & {'borrowed-height', 'see-under'}) and not blob
        scene = alignment = None
        if needs_scene:
            clock = time.time()
            scene = Scene(map_name)
            alignment = json.loads((ALIGN / f'{map_name}.json').read_text())
            print(f'[{map_name}] scene {scene.face_count}/{scene.total_faces} faces '
                  f'in {time.time() - clock:.1f}s', flush=True)
        for side_name in args.sides:
            clock = time.time()
            side = SideModel(map_name, side_name, root)
            rows = []
            if blob:
                skipped.add(map_name)
            measured = None
            if scene is not None:
                measured = measure_columns(side, scene, alignment)
            if not blob:
                if 'borrowed-height' in wanted and measured:
                    rows += detect_borrowed_height(side, measured)
                if 'low-cover-blocks-standing' in wanted:
                    rows += detect_low_cover(side)
                if 'see-under' in wanted and measured:
                    rows += detect_see_under(side, measured)
                if 'marking-as-wall' in wanted:
                    rows += detect_marking_as_wall(side)
            if 'edge-reach' in wanted:
                found, stats = detect_edge_reach(side)
                rows += found
                notes[(map_name, side_name)] = stats
            if 'level-jump-on-flat' in wanted:
                rows += detect_level_jump(side)
            for row in rows:
                row['map'] = map_name
                row['side'] = side_name
                row.setdefault('pose', None)
            rows = [dict(map=r['map'], side=r['side'], detector=r['detector'],
                         wallId=r['wallId'], stroke=r['stroke'], pieces=r.get('pieces'),
                         centroid=r['centroid'], lengthSvg=r['lengthSvg'],
                         evidence=r['evidence'], pose=r['pose']) for r in rows]
            report[(map_name, side_name)] = rows
            (out_dir / f'{map_name}_{side_name}.json').write_text(
                json.dumps(rows, indent=1) + '\n', encoding='utf-8')
            counts = defaultdict(int)
            for row in rows:
                counts[row['detector']] += 1
            print(f'[{map_name}/{side_name}] ' +
                  ', '.join(f'{name}={counts[name]}' for name in DETECTORS) +
                  f' ({time.time() - clock:.1f}s)', flush=True)
        del scene

    elapsed = time.time() - started
    write_summary(out_dir, report, notes, elapsed, skipped)
    write_poses(out_dir, report)
    print(f'done in {elapsed / 60:.1f} minutes -> {out_dir}', flush=True)


if __name__ == '__main__':
    main()
