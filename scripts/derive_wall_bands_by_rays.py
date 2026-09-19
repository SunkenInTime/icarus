"""Re-derive SVG wall blocking bands by probing the 3D scene with horizontal rays.

A band says: at these eye heights a horizontal sightline crossing this painted
stroke is stopped. Earlier passes read that off a whole object's bounding box, so
a handrail beside a warehouse inherited the warehouse. Reading the footprint's own
column failed differently: the ink sits a few tenths of a metre off the real face,
so the column often misses the wall it is drawn on.

This measures the quantity the band actually encodes. At stations along the
stroke we cast a short horizontal segment across the ink, perpendicular to it, and
ask at every 0.1 m of height whether any solid face crosses that segment. The
corridor is a metre either side, which forgives the offset between ink and face
without reaching the next room.

Output is candidate data for review, not a claim about in-game behaviour.
"""
import argparse
import gzip
import json
import math
import sys
import time
from pathlib import Path

import numpy as np
import shapely

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compile_reviewed_svg_height_map import polygon
# The material rules, decor exclusions and alignment maths are already settled in the
# heights audit; importing them keeps one definition of "a face we trust as a blocker".
from audit_svg_wall_heights_vs_world import (
    ALIGN,
    HORIZONTAL_NZ,
    MAPS,
    SIDES,
    WORLD,
    decorative_face_ranges,
    inverse_affine,
    parent_stroke,
    solid_material_mask,
)

CORRIDOR_M = 0.5          # half the probe; the ink can sit this far off the real face.
OFFSET_BIN_M = 0.05       # resolution at which we remember how far off the ink a face sat.
SETBACK_M = 0.3           # a run this much further back than the lowest one is not this wall.
PROBE_REACH_M = 40.0      # metres of eye height worth asking about above the ground.
Z_STEP_M = 0.1
THIN_WIDTH_SVG = 1.5      # area / centreline length above this reads as a filled shape.
STATION_STEP_SVG = 0.5    # along a thin stroke.
TANGENT_BASELINE_SVG = 2.0  # half-baseline for reading a curved stroke's local heading.
SQUARE_ASPECT = 1.6       # a stub this close to square has no heading worth trusting.
AXIS_FIT = 1.5            # a stroke longer than this times its rectangle does not lie on an axis.
SNAKE_MIN_SVG = 8.0       # ...but only a shape this big; a stub's rectangle is meaningless.
BOUNDARY_STEP_SVG = 1.0   # along a filled shape's rings.
MIN_STATIONS = 3
MAX_STATIONS = 60
BLOCKED_FRACTION = 0.6    # a doorway must not open a stroke whose other stations are solid.
PROBED_FRACTION = 0.5     # heights fewer stations could reach than this are not judged.
MERGE_GAP_M = 0.3
MIN_RUN_M = 0.15
GROUND_SLACK_M = 0.3      # horizontal faces within this of the ground are the ground.
ANCHOR_M = 0.4            # a run starting this close to the ground starts at the floor.
MIN_EVIDENCE_FACES = 6    # fewer faces than this in the corridor is silence, not an answer.
MIN_BAND_M = 0.05         # the loader rejects a band no taller than this.
OFFSET_LEVELS = int(round(CORRIDOR_M / OFFSET_BIN_M)) + 1
SKIP_MAPS = {}   # Split's blobs are cut into pieces by partition_split_walls.py first
UNCHANGED_M = 0.3
EPS = 1e-9


def model_path(source, map_name, side):
    return source / f'{map_name}_svg_height_{side}.json.gz'


def load_model(source, map_name, side):
    return json.loads(gzip.decompress(model_path(source, map_name, side).read_bytes()))


class Scene:
    """Solid triangles in native metres, indexed by their xy footprint."""

    def __init__(self, map_name):
        directory = WORLD / map_name
        data = np.load(directory / 'geometry.npz')
        meta = json.loads((directory / 'geometry.json').read_text())
        # supplemented-v2 stores points in metres already, not native centimetres.
        points = data['points']
        faces = data['faces']

        keep = solid_material_mask(meta)[data['material_indices']]
        for start, stop in decorative_face_ranges(meta):
            keep[start:stop] = False
        kept = np.flatnonzero(keep).astype(np.int64)

        tri = points[faces[kept]]                        # (K, 3, 3)
        self.tri = np.ascontiguousarray(tri, dtype=np.float32)
        self.top = tri[:, :, 2].max(axis=1)
        self.bottom = tri[:, :, 2].min(axis=1)
        normal = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
        length = np.linalg.norm(normal, axis=1)
        with np.errstate(invalid='ignore', divide='ignore'):
            normal_z = np.where(length > 0, np.abs(normal[:, 2]) / np.maximum(length, 1e-12), 1.0)
        self.flat = normal_z >= HORIZONTAL_NZ
        self.tree = shapely.STRtree(shapely.box(
            tri[:, :, 0].min(1), tri[:, :, 1].min(1),
            tri[:, :, 0].max(1), tri[:, :, 1].max(1)))
        self.face_count = len(kept)
        self.total_faces = len(faces)
        del tri, points, faces, data


class Ground:
    """Reference floor triangles in SVG xy with metre z."""

    def __init__(self, ground):
        vertices = np.asarray(ground['vertices'], dtype=np.float64).reshape(-1, 3)
        triangles = np.asarray(ground['triangles'], dtype=np.int64).reshape(-1, 3)
        self.tri = vertices[triangles] if len(triangles) else np.zeros((0, 3, 3))
        self.tree = shapely.STRtree(shapely.polygons(self.tri[:, :, :2])) if len(self.tri) else None

    def at_points(self, points, prefer):
        """Height under each SVG xy point, choosing the floor nearest `prefer`."""
        out = np.full(len(points), np.nan)
        if self.tree is None or not len(points):
            return out
        pairs = self.tree.query(shapely.points(points), predicate='intersects')
        if not pairs.size:
            return out
        which, hit = pairs[0], pairs[1]
        z = barycentric_z(self.tri[hit], points[which])
        order = np.lexsort((np.abs(z - prefer), which))
        which, z = which[order], z[order]
        first = np.unique(which, return_index=True)[1]
        out[which[first]] = z[first]
        return out


def barycentric_z(tri, points):
    a, b, c = tri[:, 0], tri[:, 1], tri[:, 2]
    denominator = (b[:, 1] - c[:, 1]) * (a[:, 0] - c[:, 0]) + (c[:, 0] - b[:, 0]) * (a[:, 1] - c[:, 1])
    safe = np.where(np.abs(denominator) < 1e-12, 1.0, denominator)
    x, y = points[:, 0], points[:, 1]
    w0 = ((b[:, 1] - c[:, 1]) * (x - c[:, 0]) + (c[:, 0] - b[:, 0]) * (y - c[:, 1])) / safe
    w1 = ((c[:, 1] - a[:, 1]) * (x - c[:, 0]) + (a[:, 0] - c[:, 0]) * (y - c[:, 1])) / safe
    z = w0 * a[:, 2] + w1 * b[:, 2] + (1.0 - w0 - w1) * c[:, 2]
    return np.where(np.abs(denominator) < 1e-12, tri[:, :, 2].max(axis=1), z)


def unit(vectors):
    length = np.linalg.norm(vectors, axis=-1, keepdims=True)
    return vectors / np.maximum(length, 1e-12)


def thin_stations(shape, rectangle):
    """Centres and local directions along a stroke's centreline, in SVG units."""
    corner = np.array(rectangle.exterior.coords[:5])
    edges = corner[1:] - corner[:4]
    sides = np.linalg.norm(edges, axis=1)
    axis = unit(edges[int(np.argmax(sides))])
    across = np.array([-axis[1], axis[0]])
    # A stub barely longer than it is wide has no heading; probe it both ways.
    square = max(sides) <= SQUARE_ASPECT * max(min(sides), 1e-9)

    outline = shapely.get_coordinates(shape)
    along_t = outline @ axis
    across_t = outline @ across
    low, high = float(along_t.min()), float(along_t.max())
    span = high - low
    count = int(np.clip(np.ceil(span / STATION_STEP_SVG), MIN_STATIONS, MAX_STATIONS))
    ts = low + (np.arange(count) + 0.5) * (span / count if span > EPS else 0.0)
    w_low, w_high = float(across_t.min()) - 0.5, float(across_t.max()) + 0.5

    # A point is t*axis + w*across exactly, the basis being orthonormal.
    starts = ts[:, None] * axis + w_low * across
    ends = ts[:, None] * axis + w_high * across
    cuts = shapely.intersection(
        shapely.linestrings(np.stack([starts, ends], axis=1)), shape)
    centres = np.array([[c.centroid.x, c.centroid.y] for c in cuts if not c.is_empty])
    if not len(centres):
        return None
    flat = np.repeat(across[None, :], len(centres), axis=0)
    sideways = np.repeat(axis[None, :], len(centres), axis=0)
    if square:
        return centres, [flat, sideways]
    if len(centres) < 2:
        return centres, [flat]

    # The rectangle's axis is global, so a curved stroke needs a local reading; but the
    # centre of a ragged cut wobbles, so the baseline has to be long enough to outvote it.
    window = int(np.ceil(TANGENT_BASELINE_SVG / STATION_STEP_SVG))
    if len(centres) <= 2 * window:
        return centres, [flat]
    index = np.arange(len(centres))
    forward = centres[np.minimum(index + window, len(centres) - 1)] - centres[np.maximum(index - window, 0)]
    tangent = unit(forward)
    tangent[np.linalg.norm(forward, axis=1) < EPS] = axis
    return centres, [np.stack([-tangent[:, 1], tangent[:, 0]], axis=1)]


def boundary_stations(shape):
    """Centres and outward normals along a filled shape's rings, in SVG units."""
    rings = []
    for part in getattr(shape, 'geoms', [shape]):
        if part.geom_type != 'Polygon' or part.is_empty:
            continue
        rings.append(part.exterior)
        rings.extend(part.interiors)
    rings = [r for r in rings if r.length > EPS]
    if not rings:
        return None
    perimeter = sum(r.length for r in rings)
    step = max(BOUNDARY_STEP_SVG, perimeter / MAX_STATIONS)
    centres, directions = [], []
    for ring in rings:
        count = max(1, int(ring.length / step))
        for index in range(count):
            distance = (index + 0.5) * ring.length / count
            point = ring.interpolate(distance)
            delta = 0.05 * ring.length if ring.length < 0.2 else 0.05
            back = ring.interpolate(max(0.0, distance - delta))
            ahead = ring.interpolate(min(ring.length, distance + delta))
            tangent = np.array([ahead.x - back.x, ahead.y - back.y])
            if np.linalg.norm(tangent) < EPS:
                continue
            tangent = tangent / np.linalg.norm(tangent)
            centres.append([point.x, point.y])
            directions.append([-tangent[1], tangent[0]])
    if len(centres) < 1:
        return None
    return np.array(centres[:MAX_STATIONS]), [np.array(directions[:MAX_STATIONS])]


def stations_for(shape):
    length = shape.length / 2.0
    width = shape.area / length if length > EPS else 0.0
    rectangle = shape.minimum_rotated_rectangle
    if rectangle.geom_type == 'Polygon':
        corner = np.array(rectangle.exterior.coords[:5])
        longest = float(np.linalg.norm(corner[1:] - corner[:4], axis=1).max())
    else:
        longest = 0.0
    if width > THIN_WIDTH_SVG:
        kind = 'fill'                       # a filled shape, probed across its edges
    elif longest >= SNAKE_MIN_SVG and length > AXIS_FIT * longest:
        kind = 'snaking'                    # a stroke that wanders off any single axis
    else:
        kind = 'thin'
    found = thin_stations(shape, rectangle) if kind == 'thin' else boundary_stations(shape)
    if found is None:
        return None
    return kind, found[0], found[1]


def blocked_heights(scene, p0, p1, z_low, z_base, bins):
    """Per station, which sampled heights a solid face crosses the probe at."""
    count = len(p0)
    boxes = shapely.box(np.minimum(p0[:, 0], p1[:, 0]), np.minimum(p0[:, 1], p1[:, 1]),
                        np.maximum(p0[:, 0], p1[:, 0]), np.maximum(p0[:, 1], p1[:, 1]))
    blank = np.full((count, bins), np.inf)
    pairs = scene.tree.query(boxes)
    blocked = np.zeros((count, bins + 1), dtype=np.int32)
    empty = np.zeros(0, dtype=np.int64)
    if not pairs.size:
        return blank, empty
    which, face = pairs[0], pairs[1]

    base = z_low[which]
    # Evidence: anything standing clear of the ground here, whatever its height.
    standing = scene.top[face] > base + GROUND_SLACK_M
    # Blocking: only faces whose own z range reaches into the probed band can matter, and
    # a horizontal face down at the ground is the ground, not something to see through.
    solid = (scene.top[face] >= base - GROUND_SLACK_M) & (scene.bottom[face] <= base + PROBE_REACH_M)
    solid &= ~(scene.flat[face] & (scene.top[face] < base + GROUND_SLACK_M))
    keep = standing | solid
    which, face, standing, solid = which[keep], face[keep], standing[keep], solid[keep]
    if not len(which):
        return blank, empty

    tri = scene.tri[face].astype(np.float64)
    origin = p0[which]
    direction = unit(p1[which] - origin)
    normal = np.stack([-direction[:, 1], direction[:, 0]], axis=1)
    reach = np.linalg.norm(p1[which] - origin, axis=1)

    relative = tri[:, :, :2] - origin[:, None, :]
    side = np.einsum('kij,kj->ki', relative, normal)       # signed distance to the probe plane
    along = np.einsum('kij,kj->ki', relative, direction)   # metres from p0
    height = tri[:, :, 2]

    a = np.array([0, 1, 2])
    b = np.array([1, 2, 0])
    da, db = side[:, a], side[:, b]
    crosses = (da >= 0) != (db >= 0)
    with np.errstate(invalid='ignore', divide='ignore'):
        t = np.where(crosses, da / np.where(da - db == 0, 1.0, da - db), np.nan)
    cut_s = along[:, a] + t * (along[:, b] - along[:, a])
    cut_z = height[:, a] + t * (height[:, b] - height[:, a])

    live = crosses.any(axis=1)
    if not live.any():
        return blank, empty
    cut_s, cut_z, crosses = cut_s[live], cut_z[live], crosses[live]
    live_which, reach = which[live], reach[live]
    live_face, standing, solid = face[live], standing[live], solid[live]
    # Two of the three edges cross; take the first and the last of them. Sorting the pair
    # by s would collapse them, because a vertical face meets the probe's vertical plane
    # in a vertical line where both ends share one s.
    rows = np.arange(len(cut_s))
    first = np.argmax(crosses, axis=1)
    last = 2 - np.argmax(crosses[:, ::-1], axis=1)
    s_a, z_a = cut_s[rows, first], cut_z[rows, first]
    s_b, z_b = cut_s[rows, last], cut_z[rows, last]
    flip = s_a > s_b
    s_a, s_b = np.where(flip, s_b, s_a), np.where(flip, s_a, s_b)
    z_a, z_b = np.where(flip, z_b, z_a), np.where(flip, z_a, z_b)

    # The face crosses the probe's vertical plane along one straight segment; clip it
    # to the probe's own length and the heights it still covers are the blocked ones.
    inside = (s_b >= -EPS) & (s_a <= reach + EPS)
    upright = np.abs(s_b - s_a) < 1e-9
    span = np.where(upright, 1.0, s_b - s_a)
    s_lo = np.clip(s_a, 0.0, reach)
    s_hi = np.clip(s_b, 0.0, reach)
    z_lo = np.where(upright, z_a, z_a + (s_lo - s_a) / span * (z_b - z_a))
    z_hi = np.where(upright, z_b, z_a + (s_hi - s_a) / span * (z_b - z_a))
    low = np.minimum(z_lo, z_hi)
    high = np.maximum(z_lo, z_hi)
    corridor = np.unique(live_face[inside & standing])

    start = np.ceil((low - z_base) / Z_STEP_M - 1e-6).astype(np.int64)
    stop = np.floor((high - z_base) / Z_STEP_M + 1e-6).astype(np.int64)
    ok = inside & solid & np.isfinite(low) & np.isfinite(high) & (stop >= 0) & (start <= bins - 1)
    # How far behind the ink the crossing sat. A low wall with a tall building set back
    # behind it reads as two runs at two different offsets, and that is how we tell them
    # apart: the building has its own stroke and must not be stacked onto this one.
    offset = np.abs(np.clip(0.5 * (s_lo + s_hi), 0.0, reach) - CORRIDOR_M)
    level = np.clip(np.rint(offset / OFFSET_BIN_M).astype(np.int64), 0, OFFSET_LEVELS - 1)

    start = np.clip(start[ok], 0, bins - 1)
    stop = np.clip(stop[ok], 0, bins - 1)
    rows = live_which[ok]
    level = level[ok]
    order = np.argsort(level, kind='stable')
    start, stop, rows, level = start[order], stop[order], rows[order], level[order]
    edges = np.searchsorted(level, np.arange(OFFSET_LEVELS + 1))

    # Sweep the offset levels nearest-first; the level that first covers a cell is the
    # nearest crossing at that height, which is one cumulative sum per level, not per face.
    nearest = np.full((count, bins), np.inf)
    for step in range(OFFSET_LEVELS):
        first, last = edges[step], edges[step + 1]
        if first == last:
            continue
        np.add.at(blocked, (rows[first:last], start[first:last]), 1)
        np.add.at(blocked, (rows[first:last], stop[first:last] + 1), -1)
        fresh = (np.cumsum(blocked, axis=1)[:, :bins] > 0) & ~np.isfinite(nearest)
        nearest[fresh] = step * OFFSET_BIN_M
    return nearest, corridor


def runs_from(mask, z_base):
    if not mask.any():
        return []
    padded = np.concatenate([[False], mask, [False]])
    edges = np.flatnonzero(padded[1:] != padded[:-1])
    spans = [(int(edges[i]), int(edges[i + 1]) - 1) for i in range(0, len(edges), 2)]
    merged = [list(spans[0])]
    for lo, hi in spans[1:]:
        if (lo - merged[-1][1] - 1) * Z_STEP_M < MERGE_GAP_M:
            merged[-1][1] = hi
        else:
            merged.append([lo, hi])
    return [(lo, hi, z_base + lo * Z_STEP_M, z_base + hi * Z_STEP_M)
            for lo, hi in merged if (hi - lo) * Z_STEP_M >= MIN_RUN_M - 1e-9]


def drop_set_back(runs, nearest, blocked):
    """Keep the runs that belong to this stroke, drop the ones standing behind it.

    Every run carries how far off the ink its crossings sat. The lowest run is the wall
    the stroke was painted on, by definition. A run further up that consistently sits
    further back is a taller structure behind low cover: it has its own stroke, and
    stacking it here would block an elevated eye that can really see over the cover.
    """
    medians = []
    for lo_bin, hi_bin, _, _ in runs:
        window = nearest[:, lo_bin:hi_bin + 1]
        seen = window[blocked[:, lo_bin:hi_bin + 1]]
        medians.append(round(float(np.median(seen)), 3) if seen.size else 0.0)
    if not runs:
        return runs, [], medians
    keep, set_back, kept_medians = [runs[0]], [], [medians[0]]
    for run, median in zip(runs[1:], medians[1:]):
        if median > medians[0] + SETBACK_M:
            set_back.append((run, median))
        else:
            keep.append(run)
            kept_medians.append(median)
    return keep, set_back, kept_medians


def floor_relative_bands(runs, floor, reference_ground, bins, fraction):
    """Absolute blocked runs to bands measured from the wall's own floor.

    A band cannot describe anything below its floor: a bottom of 0 already means "and
    everything underneath too". So a run ending at or below the floor is not a band at
    all, and a run reaching down to the floor starts at 0. Without this a floor sitting
    above the measured ground produced a negative top, which the runtime refuses to load.
    """
    bands, shares, dropped_top = [], [], None
    for index, (lo_bin, hi_bin, low, high) in enumerate(runs):
        unbounded = index == len(runs) - 1 and hi_bin >= bins - 1
        share = round(float(fraction[lo_bin:hi_bin + 1].mean()), 4)
        if not unbounded and high <= floor + MIN_BAND_M:
            dropped_top = high
            continue
        grounded = (low <= floor + ANCHOR_M
                    or low - reference_ground <= ANCHOR_M
                    or (dropped_top is not None and low - dropped_top < MERGE_GAP_M))
        bottom = 0.0 if (not bands and grounded) else round(max(0.0, low - floor), 5)
        bands.append([bottom, None if unbounded else round(high - floor, 5)])
        shares.append(share)
        dropped_top = None
    return tidy_bands(bands, shares)


def tidy_bands(bands, shares):
    """Ordered, disjoint, each taller than MIN_BAND_M, an open top only on the last."""
    clean, kept = [], []
    for (bottom, top), share in zip(bands, shares):
        bottom = max(0.0, bottom)
        if top is not None and top <= bottom + MIN_BAND_M:
            continue
        if clean:
            previous = clean[-1][1]
            if previous is None:                      # already open to the sky
                kept[-1] = max(kept[-1], share)
                continue
            if bottom <= previous + EPS:              # touching or overlapping
                clean[-1][1] = None if top is None else max(previous, top)
                kept[-1] = max(kept[-1], share)
                continue
        clean.append([bottom, top])
        kept.append(share)
    return clean, kept


def check_loader_rules(walls, derived, label):
    """Exactly what SvgHeightVisibility.fromJson demands, before it ever sees the file."""
    for wall in walls:
        if not isinstance(wall['unknownHeight'], bool):
            raise ValueError(f'{label} {wall["id"]}: unknownHeight must be a bool')
        previous = None
        for index, band in enumerate(wall['bands']):
            if len(band) != 2:
                raise ValueError(f'{label} {wall["id"]}: band {band} is not a pair')
            bottom, top = band
            if not math.isfinite(bottom):
                raise ValueError(f'{label} {wall["id"]}: band bottom {bottom} is not finite')
            if top is not None and not math.isfinite(top):
                raise ValueError(f'{label} {wall["id"]}: band top {top} is not finite')
            if bottom < 0:
                raise ValueError(f'{label} {wall["id"]}: band bottom {bottom} is below the floor')
            if top is not None and top <= bottom:
                raise ValueError(f'{label} {wall["id"]}: reversed band {band}')
            if top is None and index != len(wall['bands']) - 1:
                raise ValueError(f'{label} {wall["id"]}: unbounded band {index} is not the last')
            if wall['id'] in derived and top is not None and top <= bottom + MIN_BAND_M:
                raise ValueError(f'{label} {wall["id"]}: derived band {band} is thinner than '
                                 f'{MIN_BAND_M} m')
            if previous is not None and bottom < previous - EPS:
                raise ValueError(f'{label} {wall["id"]}: band {band} overlaps or unsorts')
            previous = math.inf if top is None else top


def classify(before, after):
    if not after:
        return 'opened' if before else 'unchanged'
    if not before:
        return 'closed'
    if len(before) != len(after):
        return 'restructured'
    old, new = before[-1][1], after[-1][1]
    if old is None and new is None:
        return 'unchanged'
    if old is None or new is None:
        return 'lowered' if old is None else 'raised'
    if abs(new - old) <= UNCHANGED_M:
        return 'unchanged'
    return 'raised' if new > old else 'lowered'


def copy_side(source, map_name, side, out_dir, reason):
    """Pass a model through untouched, with a diff that says so."""
    model = load_model(source, map_name, side)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / f'{map_name}_svg_height_{side}.json.gz').write_bytes(
        model_path(source, map_name, side).read_bytes())
    diffs = [dict(id=wall['id'], floor=float(wall['floorElevationMeters']),
                  before=[[b[0], b[1]] for b in wall['bands']],
                  after=[[b[0], b[1]] for b in wall['bands']],
                  stationCount=0, corridorFaces=0, blockedFraction=[],
                  change='unchanged', reason=reason)
             for wall in model['walls']]
    (out_dir / f'{map_name}_{side}_diff.json').write_text(json.dumps(diffs, indent=1) + chr(10))
    return model, diffs, []


def derive_side(source, map_name, side, scene, alignment, out_dir, verbose_ids, limit=None):
    model = load_model(source, map_name, side)
    inv, offset, scale = inverse_affine(alignment[f'nativeTo{side.capitalize()}Svg'])
    forward = np.array(alignment[f'nativeTo{side.capitalize()}Svg'], dtype=np.float64)
    ground = Ground(model['ground'])
    diffs, notes = [], []

    walls = model['walls'] if limit is None else model['walls'][:limit]
    for wall in walls:
        floor = float(wall['floorElevationMeters'])
        before = [[b[0], b[1]] for b in wall['bands']]
        record = dict(id=wall['id'], floor=floor, before=before, after=before,
                      stationCount=0, blockedFraction=[], change='unchanged', reason=None)
        diffs.append(record)

        shape = shapely.make_valid(polygon(wall))
        if shape.is_empty or shape.area <= 1e-9:
            record['reason'] = 'degenerate-footprint'
            continue
        found = stations_for(shape)
        if found is None:
            record['reason'] = 'no-stations'
            continue
        kind, centres, headings = found
        record['stationKind'] = kind
        record['probeDirections'] = len(headings)

        native_centre = (centres - offset) @ inv.T
        probes, z_lows = [], []
        for across in headings:
            native_dir = unit(across @ inv.T)
            p0 = native_centre - CORRIDOR_M * native_dir
            p1 = native_centre + CORRIDOR_M * native_dir
            svg_ends = np.concatenate([p0, p1]) @ forward[:, :2].T + offset
            pair = ground.at_points(svg_ends, floor).reshape(2, -1)
            lowest = np.nanmin(np.where(np.isnan(pair), np.inf, pair), axis=0)
            probes.append((p0, p1))
            z_lows.append(np.where(np.isnan(pair).all(axis=0), floor, lowest))

        z_low = np.min(z_lows, axis=0)
        z_base = float(z_low.min())
        # The grid starts at the lowest station so every probe fits on it, but "the
        # reference ground" for this piece is the typical station: on a ramp the lowest
        # end would otherwise leave a phantom gap under a facade that stands on the slope.
        reference_ground = float(np.median(z_low))
        bins = int(round((float(z_low.max()) + PROBE_REACH_M - z_base) / Z_STEP_M)) + 1
        zs = z_base + np.arange(bins) * Z_STEP_M
        probed = (zs[None, :] >= z_low[:, None] - 1e-9) & (zs[None, :] <= z_low[:, None] + PROBE_REACH_M + 1e-9)
        nearest = np.full((len(centres), bins), np.inf)
        corridor = []
        for (p0, p1) in probes:
            offsets, faces = blocked_heights(scene, p0, p1, z_low, z_base, bins)
            nearest = np.minimum(nearest, offsets)
            corridor.append(faces)
        blocked = np.isfinite(nearest) & probed
        evidence = len(np.unique(np.concatenate(corridor))) if corridor else 0

        station_count = len(centres)
        record['stationCount'] = station_count
        record['referenceGround'] = round(reference_ground, 3)
        record['corridorFaces'] = int(evidence)
        # An empty corridor is silence, not a clear line: map-boundary and other blocking
        # volumes exist only as collision and were never exported as faces. Changing a band
        # on that evidence would be inventing a reading. Keep what review already settled.
        if evidence < MIN_EVIDENCE_FACES:
            record['reason'] = 'no-geometry-evidence'
            continue
        reachable = probed.sum(axis=0)
        fraction = np.where(reachable > 0, blocked.sum(axis=0) / np.maximum(reachable, 1), 0.0)
        solid = (reachable >= PROBED_FRACTION * station_count) & (fraction >= BLOCKED_FRACTION)
        runs = runs_from(solid, z_base)
        runs, set_back, offsets = drop_set_back(runs, nearest, blocked)
        record['runOffsets'] = offsets
        record['setBackRuns'] = [dict(band=[round(low - floor, 5), round(high - floor, 5)],
                                      medianOffsetM=median)
                                 for (_, _, low, high), median in set_back]

        bands, shares = floor_relative_bands(runs, floor, reference_ground, bins, fraction)
        if not bands:
            record['reason'] = 'runs-below-floor' if runs else 'no-blocked-height'
        record['after'] = bands
        record['blockedFraction'] = shares
        record['change'] = classify(before, bands)
        wall['bands'] = bands
        wall['unknownHeight'] = False
        if not bands:
            continue

        if wall['id'] in verbose_ids:
            notes.append(dict(id=wall['id'], map=map_name, side=side, kind=kind,
                              floor=floor, before=before, after=bands,
                              groundLow=round(z_base, 3), stations=station_count,
                              stationRuns=[dict(station=i,
                                                centreSvg=[round(float(centres[i][0]), 2),
                                                           round(float(centres[i][1]), 2)],
                                                groundZ=round(float(z_low[i]), 3),
                                                runs=[[round(z, 2) for z in (a, b)]
                                                      for _, _, a, b in runs_from(blocked[i], z_base)])
                                           for i in range(0, station_count,
                                                          max(1, station_count // 3))][:4]))

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / f'{map_name}_svg_height_{side}.json.gz').write_bytes(
        gzip.compress(json.dumps(model, separators=(',', ':')).encode()))
    (out_dir / f'{map_name}_{side}_diff.json').write_text(json.dumps(diffs, indent=1) + '\n')
    return model, diffs, notes


def lengths_by_class(model, diffs):
    counts, lengths = {}, {}
    for wall, record in zip(model['walls'][:len(diffs)], diffs):
        shape = shapely.make_valid(polygon(wall))
        estimate = shape.length / 2.0
        counts[record['change']] = counts.get(record['change'], 0) + 1
        lengths[record['change']] = lengths.get(record['change'], 0.0) + estimate
        if record['after'] and record['after'][-1][1] is None:
            counts['capped'] = counts.get('capped', 0) + 1
        if record.get('reason') == 'no-geometry-evidence':
            counts['noEvidence'] = counts.get('noEvidence', 0) + 1
        record['lengthEstimate'] = round(estimate, 3)
    return counts, lengths


def ranked_strokes(diffs, change, limit=10):
    grouped = {}
    for record in diffs:
        if record['change'] != change:
            continue
        entry = grouped.setdefault(parent_stroke(record['id']),
                                   dict(length=0.0, pieces=0, before=[], after=[]))
        entry['length'] += record.get('lengthEstimate', 0.0)
        entry['pieces'] += 1
        entry['before'].append(record['before'][-1][1] if record['before'] else None)
        entry['after'].append(record['after'][-1][1] if record['after'] else None)
    return sorted(grouped.items(), key=lambda kv: -kv[1]['length'])[:limit]


def describe(values):
    finite = [v for v in values if v is not None]
    if not finite:
        return 'open'
    tag = '' if len(finite) == len(values) else '+open'
    return f'{min(finite):.1f} to {max(finite):.1f}{tag}'


CLASSES = ['unchanged', 'lowered', 'raised', 'opened', 'closed', 'restructured']


def write_summary(out_dir, report):
    lines = ['# Wall bands re-derived by horizontal ray probing', '',
             f'Each stroke is probed at stations {STATION_STEP_SVG} SVG units apart along its '
             f'centreline (filled shapes: {BOUNDARY_STEP_SVG} units along their rings), with a '
             f'{2 * CORRIDOR_M:.0f} m horizontal segment across the ink at every {Z_STEP_M} m of '
             f'height up to {PROBE_REACH_M:.0f} m above the reference ground. A height counts as '
             f'blocked when {BLOCKED_FRACTION:.0%} of stations are stopped. Runs closer than '
             f'{MERGE_GAP_M} m merge; runs under {MIN_RUN_M} m are dropped. A stroke that '
             f'wanders off any single axis is probed along its rings too.', '',
             f'The "capped" column counts strokes still blocking at the top of the probe, '
             f'{PROBE_REACH_M:.0f} m over the ground; only those are left with an unbounded top. '
             f'"no evidence" counts strokes whose corridor held fewer than {MIN_EVIDENCE_FACES} '
             f'faces standing clear of the ground: nothing was measured there, so the reviewed '
             f'bands were left alone. Blocking volumes that exist only as collision land here.', '',
             'Candidates for review, not a claim about in-game behaviour.', '',
             '| map/side | walls | ' + ' | '.join(CLASSES) + ' | capped | no evidence | lowered len | raised len | opened len |',
             '|---' * (len(CLASSES) + 7) + '|']
    for (map_name, side), (counts, lengths, _) in report.items():
        total = sum(counts.get(name, 0) for name in CLASSES)
        if map_name in SKIP_MAPS:
            lines.append(f'| {map_name}/{side} | {total} | ' + SKIP_MAPS[map_name]
                         + ' |' + ' |' * (len(CLASSES) + 4))
            continue
        row = [f'{map_name}/{side}', str(total)]
        row += [str(counts.get(name, 0)) for name in CLASSES]
        row += [str(counts.get('capped', 0)), str(counts.get('noEvidence', 0))]
        row += [f'{lengths.get(name, 0.0):.0f}' for name in ('lowered', 'raised', 'opened')]
        lines.append('| ' + ' | '.join(row) + ' |')
    lines.append('')

    for (map_name, side), (_, _, diffs) in report.items():
        if map_name in SKIP_MAPS:
            continue
        for change in ('lowered', 'raised'):
            ranked = ranked_strokes(diffs, change)
            if not ranked:
                continue
            lines += [f'## {map_name}/{side}: largest {change} strokes', '',
                      '| parent stroke | pieces | length | before top | after top |',
                      '|---|---|---|---|---|']
            for key, entry in ranked:
                lines.append(f'| {key} | {entry["pieces"]} | {entry["length"]:.0f} | '
                             f'{describe(entry["before"])} | {describe(entry["after"])} |')
            lines.append('')
    (out_dir / 'summary.md').write_text('\n'.join(lines) + '\n')


UNTOUCHED = {'no-geometry-evidence', 'degenerate-footprint', 'no-stations'}


def validate(out_dir, source, map_name, side, diffs):
    original = load_model(source, map_name, side)
    written = json.loads(gzip.decompress((out_dir / f'{map_name}_svg_height_{side}.json.gz').read_bytes()))
    if len(written['walls']) != len(original['walls']):
        raise ValueError(f'{map_name}/{side}: wall count changed')
    for a, b in zip(original['walls'], written['walls']):
        if a['id'] != b['id'] or a['floorElevationMeters'] != b['floorElevationMeters']:
            raise ValueError(f'{map_name}/{side}: wall identity changed at {a["id"]}')
        if a['rings'] != b['rings']:
            raise ValueError(f'{map_name}/{side}: rings changed at {a["id"]}')
    derived = {row['id'] for row in diffs
               if row.get('reason') not in UNTOUCHED and row.get('reason') not in SKIP_MAPS.values()}
    check_loader_rules(written['walls'], derived, f'{map_name}/{side}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument('--maps', nargs='*', default=MAPS)
    parser.add_argument('--sides', nargs='*', default=SIDES)
    parser.add_argument('--limit', type=int, default=None, help='debug: first N walls only')
    parser.add_argument('--trace', nargs='*', default=[], help='wall ids to report stations for')
    parser.add_argument('--out', default=None)
    parser.add_argument('--source', default=None,
                        help='directory of input models; defaults to the bundled assets')
    args = parser.parse_args()

    root = Path(args.root)
    source = Path(args.source) if args.source else root / 'assets' / 'maps'
    out_dir = Path(args.out) if args.out else root / 'work' / 'ray-bands'
    out_dir.mkdir(parents=True, exist_ok=True)
    traced = set(args.trace)

    print(f'source models: {source}', flush=True)
    report, started = {}, time.time()
    for map_name in args.maps:
        if map_name in SKIP_MAPS:
            for side in args.sides:
                model, diffs, _ = copy_side(source, map_name, side, out_dir, SKIP_MAPS[map_name])
                validate(out_dir, source, map_name, side, diffs)
                counts, lengths = lengths_by_class(model, diffs)
                report[(map_name, side)] = (counts, lengths, diffs)
                print(f'[{map_name}/{side}] {len(diffs)} walls copied through, '
                      f'{SKIP_MAPS[map_name]}', flush=True)
            continue
        if not (WORLD / map_name / 'geometry.npz').exists():
            print(f'[{map_name}] skipped: no world geometry', flush=True)
            continue
        clock = time.time()
        scene = Scene(map_name)
        alignment = json.loads((ALIGN / f'{map_name}.json').read_text())
        print(f'[{map_name}] scene {scene.face_count}/{scene.total_faces} faces '
              f'in {time.time() - clock:.1f}s', flush=True)
        for side in args.sides:
            clock = time.time()
            model, diffs, notes = derive_side(source, map_name, side, scene, alignment, out_dir, traced, args.limit)
            if args.limit is None:
                validate(out_dir, source, map_name, side, diffs)
            counts, lengths = lengths_by_class(model, diffs)
            report[(map_name, side)] = (counts, lengths, diffs)
            (out_dir / f'{map_name}_{side}_diff.json').write_text(json.dumps(diffs, indent=1) + '\n')
            print(f'[{map_name}/{side}] {len(diffs)} walls in {time.time() - clock:.1f}s :: '
                  + ', '.join(f'{name} {counts.get(name, 0)} ({lengths.get(name, 0.0):.0f} svg)'
                              for name in CLASSES), flush=True)
            for note in notes:
                print('  trace ' + json.dumps(note), flush=True)
        del scene

    if report:
        write_summary(out_dir, report)
    print(f'total {time.time() - started:.1f}s', flush=True)


if __name__ == '__main__':
    main()
