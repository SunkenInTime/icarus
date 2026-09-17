"""Lower overstated SVG wall bands to what the 3D scene carries above the floor.

Input is work/wall-height-audit/<map>_<side>.json from
audit_svg_wall_heights_vs_world.py. A wall is rewritten only when the audit
called it OVERSTATED, it carries no recorded review, and the measured column
starts on the reference floor. Pieces of one painted stroke that touch each
other are one physical wall: the whole touching group must be overstated
with tops that agree, or none of it is changed. Lowering a single fragment
inside a solid run would cut a see-through notch into the wall. Its bands become the measured solid runs: the
first run is anchored to the floor so nothing beneath it opens up, and later
runs keep headers and overhangs above an opening. A footprint with nothing
solid above the floor becomes connected ground and stops blocking.

Writes candidate assets and a change log; --install copies them over
assets/maps and refreshes the footprint certificate.
"""
import argparse
import re
import gzip
import json
import shutil
import subprocess
import sys
from pathlib import Path

import shapely

from compile_reviewed_svg_height_map import polygon

MAPS = ['abyss', 'ascent', 'bind', 'breeze', 'corrode', 'fracture', 'haven',
        'icebox', 'lotus', 'pearl', 'split', 'summit', 'sunset']
SIDES = ['attack', 'defense']
PROTECTED = re.compile(r'review|reported|gameplay|opening|confirmed', re.IGNORECASE)
MIN_RUN = 0.15          # metres; thinner solid runs are numerical fragments.
FLOOR_TOLERANCE = 0.25  # metres; a first run must start this close to the floor.
GROUP_TOP_SPREAD = 1.0  # metres; measured tops within one touching group must agree this well.
TOUCH_SVG = 0.05        # SVG units; pieces closer than this are one wall.


def read_gz(path):
    return json.loads(gzip.decompress(Path(path).read_bytes()))


def write_gz(path, data):
    Path(path).write_bytes(gzip.compress(json.dumps(data).encode(), mtime=0))


def measured_bands(row, floor):
    ground = row['ground'] if row['ground'] is not None else floor
    runs = [(lo, hi) for lo, hi in row.get('measuredRuns', []) if hi - lo >= MIN_RUN]
    if not runs:
        return []
    if runs[0][0] > ground + FLOOR_TOLERANCE:
        return None                       # the stack does not stand on this floor
    bands = []
    for index, (lo, hi) in enumerate(runs):
        bottom = 0.0 if index == 0 else max(0.0, lo - floor)
        top = hi - floor
        if top <= bottom:
            continue
        bands.append([round(bottom, 4), round(top, 4)])
    return bands


def touching_groups(walls, rows):
    """Ids whose whole touching group, within one painted stroke, is overstated."""
    by_stroke = {}
    for index, wall in enumerate(walls):
        by_stroke.setdefault('-'.join(wall['id'].split('-')[:3]), []).append(index)
    eligible = set()
    for members in by_stroke.values():
        shapes = [polygon(walls[i]).buffer(TOUCH_SVG) for i in members]
        tree = shapely.STRtree(shapes)
        parent = list(range(len(members)))

        def find(a):
            while parent[a] != a:
                parent[a] = parent[parent[a]]
                a = parent[a]
            return a

        for a, shape in enumerate(shapes):
            for b in tree.query(shape, predicate='intersects'):
                if b != a:
                    parent[find(a)] = find(int(b))
        groups = {}
        for local, index in enumerate(members):
            groups.setdefault(find(local), []).append(index)
        for group in groups.values():
            group_rows = [rows.get(walls[i]['id']) for i in group]
            if any(r is None or r['verdict'] != 'OVERSTATED' or r.get('reviewed')
                   or PROTECTED.search(walls[i]['id']) for r, i in zip(group_rows, group)):
                continue
            tops = [r['measuredColumnTop'] for r in group_rows if r['measuredColumnTop'] is not None]
            if len(tops) != len(group_rows) or max(tops) - min(tops) > GROUP_TOP_SPREAD:
                continue
            eligible.update(walls[i]['id'] for i in group)
    return eligible


def rewrite(map_name, side, audit_dir, out_dir, assets_dir):
    rows = {r['id']: r for r in json.loads((audit_dir / f'{map_name}_{side}.json').read_text())}
    model = read_gz(assets_dir / f'{map_name}_svg_height_{side}.json.gz')
    changes, skipped = [], []
    eligible = touching_groups(model['walls'], rows)
    for wall in model['walls']:
        row = rows.get(wall['id'])
        if row is None or row['verdict'] != 'OVERSTATED':
            continue
        if row.get('reviewed') or PROTECTED.search(wall['id']):
            skipped.append(dict(id=wall['id'], reason='recorded-review'))
            continue
        if wall['id'] not in eligible:
            skipped.append(dict(id=wall['id'], reason='touching-pieces-disagree'))
            continue
        floor = float(wall['floorElevationMeters'])
        bands = measured_bands(row, floor)
        if bands is None:
            skipped.append(dict(id=wall['id'], reason='column-off-floor'))
            continue
        changes.append(dict(id=wall['id'], centroid=row['centroid'],
                            lengthEstimate=row['lengthEstimate'],
                            ground=row['ground'], floor=floor,
                            before=wall['bands'], after=bands,
                            assignedTop=row['assignedTop'],
                            measuredRuns=row.get('measuredRuns', [])))
        wall['bands'] = bands
        wall['unknownHeight'] = False
    model['measuredWallColumns'] = dict(
        source='scripts/audit_svg_wall_heights_vs_world.py',
        rewritten=len(changes), skipped=len(skipped))
    write_gz(out_dir / f'{map_name}_svg_height_{side}.json.gz', model)
    (out_dir / f'{map_name}_{side}_changes.json').write_text(
        json.dumps(dict(map=map_name, side=side, changes=changes, skipped=skipped), indent=1) + '\n')
    return changes, skipped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--maps', nargs='*', default=MAPS)
    parser.add_argument('--audit-dir', type=Path, default=Path('work/wall-height-audit'))
    parser.add_argument('--out', type=Path, default=Path('work/wall-height-audit/candidate'))
    parser.add_argument('--assets', type=Path, default=Path('assets/maps'))
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    summary = []
    for map_name in args.maps:
        for side in SIDES:
            changes, skipped = rewrite(map_name, side, args.audit_dir, args.out, args.assets)
            opened = sum(1 for c in changes if not c['after'])
            summary.append(dict(map=map_name, side=side, rewritten=len(changes),
                                nowGround=opened, skipped=len(skipped),
                                rewrittenLength=round(sum(c['lengthEstimate'] for c in changes), 1)))
            print(f'{map_name}/{side}: rewrote {len(changes)} walls ({opened} to ground), '
                  f'skipped {len(skipped)}', flush=True)
    (args.out / 'summary.json').write_text(json.dumps(summary, indent=1) + '\n')
    if args.install:
        for map_name in args.maps:
            for side in SIDES:
                name = f'{map_name}_svg_height_{side}.json.gz'
                shutil.copyfile(args.out / name, args.assets / name)
        subprocess.run([sys.executable, 'scripts/svg_wall_footprint_integrity.py'], check=True)
        subprocess.run([sys.executable, 'scripts/standing_source_integrity.py'], check=True)


if __name__ == '__main__':
    main()
