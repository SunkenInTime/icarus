"""Choose observer poses that look at rewritten walls, for the cone gallery.

Reads work/wall-height-audit/candidate/<map>_<side>_changes.json, groups the
changes by parent stroke, and for the longest strokes finds a floor position a
few metres from the wall facing it. Prints one gallery command per map/side.
"""
import argparse
import gzip
import json
import math
from pathlib import Path

import numpy as np
import shapely

from compile_reviewed_svg_height_map import polygon


def load(path):
    return json.loads(gzip.decompress(Path(path).read_bytes()))


def receiver_shape(model):
    return shapely.union_all([polygon(r) for r in model['receiver']])


def pick_poses(map_name, side, candidate_dir, assets_dir, limit):
    changes = json.loads((candidate_dir / f'{map_name}_{side}_changes.json').read_text())['changes']
    model = load(assets_dir / f'{map_name}_svg_height_{side}.json.gz')
    walls = {w['id']: w for w in model['walls']}
    receiver = receiver_shape(model)
    wall_union = shapely.union_all([polygon(w) for w in model['walls']])
    grouped = {}
    for change in changes:
        key = '-'.join(change['id'].split('-')[:3])
        entry = grouped.setdefault(key, dict(length=0.0, ids=[]))
        entry['length'] += change['lengthEstimate']
        entry['ids'].append(change['id'])
    poses = []
    for key, entry in sorted(grouped.items(), key=lambda kv: -kv[1]['length'])[:limit]:
        shape = shapely.union_all([polygon(walls[i]) for i in entry['ids']])
        centre = shape.centroid
        rect = shape.minimum_rotated_rectangle
        coords = np.array(rect.exterior.coords)[:4]
        edges = coords[1:] - coords[:-1]
        longest = edges[np.argmax(np.linalg.norm(edges, axis=1))]
        normal = np.array([-longest[1], longest[0]])
        normal /= max(np.linalg.norm(normal), 1e-9)
        chosen = None
        for distance in (6.0, 9.0, 12.0, 16.0):
            for sign in (1, -1):
                point = np.array([centre.x, centre.y]) + sign * distance * normal
                p = shapely.Point(point)
                if receiver.contains(p) and not wall_union.contains(p):
                    facing = math.degrees(math.atan2(centre.y - point[1], centre.x - point[0]))
                    chosen = (round(point[0], 1), round(point[1], 1), round(facing, 1), key,
                              round(entry['length'], 1))
                    break
            if chosen:
                break
        if chosen:
            poses.append(chosen)
    return poses


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--maps', nargs='*', default=['abyss', 'ascent', 'bind', 'breeze', 'corrode',
                        'fracture', 'haven', 'icebox', 'lotus', 'pearl', 'split', 'summit', 'sunset'])
    parser.add_argument('--sides', nargs='*', default=['attack'])
    parser.add_argument('--limit', type=int, default=6)
    parser.add_argument('--candidate', type=Path, default=Path('work/wall-height-audit/candidate'))
    parser.add_argument('--assets', type=Path, default=Path('assets/maps'))
    args = parser.parse_args()
    manifest = {}
    for map_name in args.maps:
        for side in args.sides:
            poses = pick_poses(map_name, side, args.candidate, args.assets, args.limit)
            manifest[f'{map_name}/{side}'] = [dict(x=p[0], y=p[1], facing=p[2], stroke=p[3], length=p[4])
                                              for p in poses]
            print(f'{map_name} {side} ' + ';'.join(f'{p[0]},{p[1]},{p[2]}' for p in poses))
    (args.candidate / 'review-poses.json').write_text(json.dumps(manifest, indent=1) + '\n')


if __name__ == '__main__':
    main()
