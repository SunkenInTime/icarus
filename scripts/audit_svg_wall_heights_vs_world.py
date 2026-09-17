"""Compare baked SVG wall band tops against the independent 3D world geometry.

For every map side we take each painted wall footprint, find the 3D faces that sit
under it, and ask whether the baked blocking top is supported by real geometry.
Output is a candidate list for human review, not a verdict on in-game behaviour.
"""
import argparse
import gzip
import json
import re
import sys
import time
from pathlib import Path

import numpy as np
import shapely

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compile_reviewed_svg_height_map import polygon

MAPS = ['abyss', 'ascent', 'bind', 'breeze', 'corrode', 'fracture', 'haven',
        'icebox', 'lotus', 'pearl', 'split', 'summit', 'sunset']
SIDES = ['attack', 'defense']

WORLD = Path(r'E:\IcarusWorldAudit\2026-09-06\supplemented-v2\world')
ALIGN = Path(r'E:\IcarusWorldAudit\2026-09-06\tactical-alignment-sides-v1')

DECOR = re.compile(r'foliage|bush|tree|grass|vine|leaf|ivy|plant|moss|fern|overgrowth|flower|petunia|cabbage|weed|shrub|hedge|gravel|pebble|decal|vfx|light', re.IGNORECASE)
SOLID_BLEND_MODES = {0, 1}       # UE EBlendMode: 0 opaque, 1 masked (fences, grates). 2+ translucent.
BUFFER_SVG = 0.25
BUFFER_WIDE_SVG = 1.0            # second reading; a lowering must hold at both widths.
BUFFER_WIDER_SVG = 2.0           # third reading; the real wall face can sit half a metre off the ink.
HORIZONTAL_NZ = 0.7              # |normal z| at or above this reads as floor/ceiling slab.
SLAB_CLEARANCE = 0.3             # horizontal faces this far above the floor are solid slabs, not the floor.
OVERSTATED_DROP = 1.5            # metres the bake must exceed the 3D by before we care.
UNDERSTATED_RISE = 1.5
STANDING_EYE = 1.9               # a standing eye clears anything below this above its floor.
WALL_CHUNK = 128
COLUMN_BIN = 0.1                 # metres per slice when stacking a footprint's geometry.
COLUMN_GAP = 0.5                 # air this deep ends the stack standing on the floor.
COLUMN_REACH = 40.0              # metres above the floor worth stacking.


def load_model(root, map_name, side):
    path = root / 'assets' / 'maps' / f'{map_name}_svg_height_{side}.json.gz'
    return json.loads(gzip.decompress(path.read_bytes()))


def solid_material_mask(geometry_json):
    """Faces we trust as blockers: opaque surfaces only."""
    materials = geometry_json['materials']
    blend = np.array([m.get('blendMode') if m.get('blendMode') is not None else 0
                      for m in materials], dtype=np.int32)
    # 'unresolved' materials carry no blend mode; keeping them can only raise the measured
    # top, which makes an OVERSTATED call harder to reach. That is the safe direction.
    return np.isin(blend, list(SOLID_BLEND_MODES))


def decorative_face_ranges(geometry_json):
    spans = []
    for obj in geometry_json['objects']:
        if DECOR.search(obj['path']):
            spans.append((obj['firstFace'], obj['firstFace'] + obj['faceCount']))
    return spans


def inverse_affine(matrix):
    m = np.array(matrix, dtype=np.float64)
    a, t = m[:, :2], m[:, 2]
    inv = np.linalg.inv(a)
    scale = float(np.sqrt(abs(np.linalg.det(a))))
    return inv, t, scale


def to_native(geom, inv, offset):
    def fn(coords):
        return (coords - offset) @ inv.T
    return shapely.transform(geom, fn)


class Scene:
    """Face tops and normals in native metres, indexed for footprint queries."""

    def __init__(self, map_name):
        directory = WORLD / map_name
        data = np.load(directory / 'geometry.npz')
        meta = json.loads((directory / 'geometry.json').read_text())
        # The supplemented-v2 npz stores points in metres already (verified against each
        # object's boundsMeters), not the native centimetres the export docs mention.
        points = data['points']
        faces = data['faces']

        keep = solid_material_mask(meta)[data['material_indices']]
        for start, stop in decorative_face_ranges(meta):
            keep[start:stop] = False
        kept = np.flatnonzero(keep).astype(np.int64)

        tri = points[faces[kept]]                       # (K, 3, 3)
        self.tri_xy = np.ascontiguousarray(tri[:, :, :2])
        self.top = tri[:, :, 2].max(axis=1)
        self.bottom = tri[:, :, 2].min(axis=1)
        normal = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
        length = np.linalg.norm(normal, axis=1)
        with np.errstate(invalid='ignore', divide='ignore'):
            normal_z = np.where(length > 0, np.abs(normal[:, 2]) / np.maximum(length, 1e-12), 1.0)
        self.solidish = normal_z < HORIZONTAL_NZ
        self.tree = shapely.STRtree(shapely.box(
            self.tri_xy[:, :, 0].min(1), self.tri_xy[:, :, 1].min(1),
            self.tri_xy[:, :, 0].max(1), self.tri_xy[:, :, 1].max(1)))
        self.face_count = len(kept)
        self.total_faces = len(faces)


class Ground:
    """Reference floor triangles in SVG xy with metre z."""

    def __init__(self, ground):
        vertices = np.asarray(ground['vertices'], dtype=np.float64).reshape(-1, 3)
        triangles = np.asarray(ground['triangles'], dtype=np.int64).reshape(-1, 3)
        self.tri = vertices[triangles]
        self.tree = shapely.STRtree(shapely.polygons(self.tri[:, :, :2]))

    def at(self, x, y, prefer):
        hits = self.tree.query(shapely.Point(x, y), predicate='intersects')
        if not len(hits):
            return None
        heights = [float(barycentric_z(*self.tri[index], x, y)) for index in hits]
        # Several floors can stack over one xy. Take the one nearest the wall's own floor.
        return min(heights, key=lambda h: abs(h - prefer))


def column_runs(base, low, high):
    """Solid runs of the geometry stack over this floor, lowest first.

    A footprint is a vertical column through the whole map, so its highest face is
    usually a roof or the sky. What blocks a player standing here is the run of
    geometry that rises from the floor without a gap they could see through; later
    runs are headers and overhangs with an opening beneath them.
    """
    if not len(low):
        return []
    start = base - COLUMN_GAP
    bins = int(COLUMN_REACH / COLUMN_BIN) + 1
    lo = np.clip(np.ceil((low - start) / COLUMN_BIN).astype(np.int64), 0, bins)
    hi = np.clip(np.floor((high - start) / COLUMN_BIN).astype(np.int64) + 1, 0, bins)
    marks = np.zeros(bins + 1, dtype=np.int64)
    np.add.at(marks, lo, 1)
    np.add.at(marks, hi, -1)
    occupied = np.cumsum(marks)[:bins] > 0
    if not occupied.any():
        return []
    gap = int(COLUMN_GAP / COLUMN_BIN)
    if int(np.argmax(occupied)) > 2 * gap:
        return []                                    # nothing stands on this floor
    runs, first, last, empty = [], -1, -1, 0
    for index, filled in enumerate(occupied):
        if filled:
            if first < 0 or empty > gap:
                if first >= 0:
                    runs.append((start + first * COLUMN_BIN, start + (last + 1) * COLUMN_BIN))
                first = index
            last, empty = index, 0
        else:
            empty += 1
    if first >= 0:
        runs.append((start + first * COLUMN_BIN, start + (last + 1) * COLUMN_BIN))
    return [(round(max(lo, base), 3), round(hi, 3)) for lo, hi in runs]


def column_top(base, low, high):
    runs = column_runs(base, low, high)
    return runs[0][1] if runs else None


def barycentric_z(a, b, c, x, y):
    denominator = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
    if abs(denominator) < 1e-12:
        return max(a[2], b[2], c[2])
    w0 = ((b[1] - c[1]) * (x - c[0]) + (c[0] - b[0]) * (y - c[1])) / denominator
    w1 = ((c[1] - a[1]) * (x - c[0]) + (a[0] - c[0]) * (y - c[1])) / denominator
    return w0 * a[2] + w1 * b[2] + (1.0 - w0 - w1) * c[2]


def parent_stroke(wall_id):
    return '-'.join(wall_id.split('-')[:3])


def finite_top(wall):
    tops = [band[1] for band in wall['bands']]
    if not tops or any(top is None or not np.isfinite(top) for top in tops):
        return None
    return max(tops)


def classify(assigned, solid, ground, faces):
    if assigned is None:
        return 'INFINITE_BAND'
    if solid is None:
        return 'NO_GEOMETRY' if not faces else 'NO_STANDING_GEOMETRY'
    over_ground = None if ground is None else assigned - ground
    if assigned - solid > OVERSTATED_DROP and over_ground is not None and over_ground > STANDING_EYE:
        return 'OVERSTATED'
    if solid - assigned > UNDERSTATED_RISE and over_ground is not None and over_ground < STANDING_EYE:
        return 'UNDERSTATED'
    return 'OK'


def audit_side(root, map_name, side, scene, alignment, out_dir):
    model = load_model(root, map_name, side)
    reviewed_path = out_dir / 'reviewed-wall-ids.json'
    reviewed = set(json.loads(reviewed_path.read_text()).get(map_name, [])) if reviewed_path.exists() else set()
    inv, offset, scale = inverse_affine(alignment[f'nativeTo{side.capitalize()}Svg'])
    ground = Ground(model['ground'])

    prepared, rows = [], []
    for wall in model['walls']:
        top = finite_top(wall)
        shape = shapely.make_valid(polygon(wall))
        floor = float(wall['floorElevationMeters'])
        centroid = shape.centroid
        row = dict(id=wall['id'],
                   assignedTop=None if top is None else floor + float(top),
                   floor=floor,
                   ground=None if centroid.is_empty else ground.at(centroid.x, centroid.y, floor),
                   measuredTop=None, measuredTopSolidish=None, measuredColumnTop=None,
                   solidFacesFound=None,
                   faceCount=0, verdict='INFINITE_BAND',
                   centroid=[None, None] if centroid.is_empty else [round(centroid.x, 3), round(centroid.y, 3)],
                   lengthEstimate=round(shape.length / 2.0, 3))
        rows.append(row)
        if top is not None:
            prepared.append((row, to_native(shape.buffer(BUFFER_SVG), inv, offset),
                             to_native(shape.buffer(BUFFER_WIDE_SVG), inv, offset),
                             to_native(shape.buffer(BUFFER_WIDER_SVG), inv, offset)))

    for start in range(0, len(prepared), WALL_CHUNK):
        chunk = prepared[start:start + WALL_CHUNK]
        pairs = scene.tree.query(np.array([wider for _, _, _, wider in chunk], dtype=object))
        for local, (row, shape, wide, wider) in enumerate(chunk):
            candidates = pairs[1][pairs[0] == local]
            hit = wide_hit = wider_hit = candidates
            if len(candidates):
                triangles = shapely.polygons(scene.tri_xy[candidates])
                wider_hit = candidates[shapely.intersects(triangles, wider)]
                wide_hit = candidates[shapely.intersects(triangles, wide)]
                hit = candidates[shapely.intersects(triangles, shape)]
            if not len(hit):
                row['verdict'] = 'NO_GEOMETRY'
                continue
            tops = scene.top[hit]
            solid = scene.solidish[hit]
            row['faceCount'] = int(len(hit))
            row['measuredTop'] = round(float(tops.max()), 3)
            row['solidFacesFound'] = bool(solid.any())
            # With no non-horizontal face the footprint is bare slab; falling back to the
            # slab top keeps us from crying OVERSTATED over a normal we mis-read.
            stack = hit[solid] if solid.any() else hit
            row['measuredTopSolidish'] = round(float(scene.top[stack].max()), 3)
            base = row['ground'] if row['ground'] is not None else row['floor']
            # A slab between two storeys is solid; only the floor itself is not.
            slab = hit[~solid & (scene.bottom[hit] > base + SLAB_CLEARANCE)]
            stack = np.concatenate([stack, slab]) if len(slab) else stack
            runs = column_runs(base, scene.bottom[stack], scene.top[stack])
            reached = runs[0][1] if runs else None
            row['measuredColumnTop'] = None if reached is None else round(float(reached), 3)
            row['measuredRuns'] = [[float(lo), float(hi)] for lo, hi in runs]
            wide_solid = scene.solidish[wide_hit]
            wide_stack = wide_hit[wide_solid] if wide_solid.any() else wide_hit
            wide_slab = wide_hit[~wide_solid & (scene.bottom[wide_hit] > base + SLAB_CLEARANCE)]
            wide_stack = np.concatenate([wide_stack, wide_slab]) if len(wide_slab) else wide_stack
            wide_runs = column_runs(base, scene.bottom[wide_stack], scene.top[wide_stack])
            wide_top = wide_runs[0][1] if wide_runs else None
            row['measuredColumnTopWide'] = None if wide_top is None else round(float(wide_top), 3)
            row['measuredRunsWide'] = [[float(lo), float(hi)] for lo, hi in wide_runs]
            row['reviewed'] = row['id'] in reviewed
            wider_solid = scene.solidish[wider_hit]
            wider_stack = wider_hit[wider_solid] if wider_solid.any() else wider_hit
            wider_slab = wider_hit[~wider_solid & (scene.bottom[wider_hit] > base + SLAB_CLEARANCE)]
            wider_stack = np.concatenate([wider_stack, wider_slab]) if len(wider_slab) else wider_stack
            wider_runs = column_runs(base, scene.bottom[wider_stack], scene.top[wider_stack])
            wider_top = wider_runs[0][1] if wider_runs else None
            row['measuredColumnTopWider'] = None if wider_top is None else round(float(wider_top), 3)
            # A wider reading that climbs much higher means the ink sits beside the real
            # face, or the narrow one cut through a seam; never call that overstated.
            for other in (wide_top, wider_top):
                if other is not None and reached is not None and other - reached > OVERSTATED_DROP:
                    reached = max(reached, other)
            # With no structural face at all in the narrow footprint there is nothing to
            # measure; the ink is off its wall and the verdict must stay open.
            if not solid.any():
                row['verdict'] = 'NO_STRUCTURE'
                continue
            row['verdict'] = classify(row['assignedTop'], reached, row['ground'], row['faceCount'])

    for row in rows:
        if row['ground'] is not None:
            row['ground'] = round(row['ground'], 3)

    (out_dir / f'{map_name}_{side}.json').write_text(json.dumps(rows, indent=1) + '\n')
    return rows


def summarise(rows):
    checked = [r for r in rows if r['verdict'] != 'INFINITE_BAND']
    counts, lengths = {}, {}
    for row in checked:
        counts[row['verdict']] = counts.get(row['verdict'], 0) + 1
        lengths[row['verdict']] = lengths.get(row['verdict'], 0.0) + row['lengthEstimate']
    return checked, counts, lengths


def top_strokes(rows, verdict='OVERSTATED', limit=10):
    grouped = {}
    for row in rows:
        if row['verdict'] != verdict:
            continue
        entry = grouped.setdefault(parent_stroke(row['id']),
                                   dict(length=0.0, pieces=0, assigned=[], measured=[]))
        entry['length'] += row['lengthEstimate']
        entry['pieces'] += 1
        entry['assigned'].append(row['assignedTop'])
        entry['measured'].append(row['measuredColumnTop'])
    return sorted(grouped.items(), key=lambda kv: -kv[1]['length'])[:limit]


def write_summary(out_dir, report, skipped):
    lines = ['# SVG wall band tops vs 3D world geometry', '',
             f'Buffer {BUFFER_SVG} SVG units, solid-face normal |nz| < {HORIZONTAL_NZ}, '
             f'overstated when assignedTop exceeds the 3D by more than {OVERSTATED_DROP} m and sits '
             f'more than {STANDING_EYE} m over the reference ground. The measured top used for '
             f'the verdict is the column top: the run of non-horizontal geometry rising from the '
             f'floor under the footprint without a gap of {COLUMN_GAP} m, which keeps roofs and '
             f'the sky out of the reading.', '',
             'Verdicts: OVERSTATED, the bake blocks a standing eye the 3D cannot support. '
             'UNDERSTATED, the 3D carries a surface well above a band a standing eye clears. '
             'NO_GEOMETRY, nothing at all under the footprint. "nothing on floor", faces are '
             'there but none of them start near the reference ground, so the footprint most '
             'likely sits over an opening or over a floor the ground model does not carry; '
             'read measuredTopSolidish by hand for those. Walls with an unbounded band are '
             'left out of the counts.', '',
             'These are candidates for review, not a claim about what happens in game.', '']
    if skipped:
        lines += [f'Skipped (no world data): {", ".join(skipped)}', '']
    lines += ['| map/side | walls checked | OVERSTATED | over length | UNDERSTATED | under length | NO_GEOMETRY | nothing on floor |',
              '|---|---|---|---|---|---|---|---|']
    for (map_name, side), rows in report.items():
        checked, counts, lengths = summarise(rows)
        lines.append(f'| {map_name}/{side} | {len(checked)} | {counts.get("OVERSTATED", 0)} | '
                     f'{lengths.get("OVERSTATED", 0.0):.0f} | {counts.get("UNDERSTATED", 0)} | '
                     f'{lengths.get("UNDERSTATED", 0.0):.0f} | {counts.get("NO_GEOMETRY", 0)} | '
                     f'{counts.get("NO_STANDING_GEOMETRY", 0)} |')
    lines.append('')

    for (map_name, side), rows in report.items():
        ranked = top_strokes(rows)
        if not ranked:
            continue
        lines += [f'## {map_name}/{side}: largest OVERSTATED strokes', '',
                  '| parent stroke | pieces | length | assignedTop | measured column top |',
                  '|---|---|---|---|---|']
        for key, entry in ranked:
            assigned = f'{min(entry["assigned"]):.1f} to {max(entry["assigned"]):.1f}'
            measured = f'{min(entry["measured"]):.1f} to {max(entry["measured"]):.1f}'
            lines.append(f'| {key} | {entry["pieces"]} | {entry["length"]:.0f} | {assigned} | {measured} |')
        lines.append('')

    (out_dir / 'summary.md').write_text('\n'.join(lines) + '\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument('--maps', nargs='*', default=MAPS)
    parser.add_argument('--out', default=None)
    args = parser.parse_args()

    root = Path(args.root)
    out_dir = Path(args.out) if args.out else root / 'work' / 'wall-height-audit'
    out_dir.mkdir(parents=True, exist_ok=True)

    report, skipped = {}, []
    for map_name in args.maps:
        npz = WORLD / map_name / 'geometry.npz'
        align_path = ALIGN / f'{map_name}.json'
        if not npz.exists() or not align_path.exists():
            skipped.append(map_name)
            print(f'[{map_name}] skipped: missing world geometry or alignment', flush=True)
            continue
        started = time.time()
        scene = Scene(map_name)
        alignment = json.loads(align_path.read_text())
        print(f'[{map_name}] scene ready {scene.face_count}/{scene.total_faces} faces '
              f'in {time.time() - started:.1f}s', flush=True)
        for side in SIDES:
            side_started = time.time()
            rows = audit_side(root, map_name, side, scene, alignment, out_dir)
            checked, counts, _ = summarise(rows)
            report[(map_name, side)] = rows
            print(f'[{map_name}/{side}] {len(checked)} walls checked, '
                  f'{counts.get("OVERSTATED", 0)} overstated, {counts.get("UNDERSTATED", 0)} understated, '
                  f'{counts.get("NO_GEOMETRY", 0)} without geometry '
                  f'({time.time() - side_started:.1f}s)', flush=True)
        del scene

    write_summary(out_dir, report, skipped)


if __name__ == '__main__':
    main()
