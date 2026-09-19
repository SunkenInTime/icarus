"""Open reviewed walls Dara ruled see-through, using the scene's own measurement.

See scripts/data/reviewed-openings-2026-09-19.json. Each entry names an
attack-space box; walls at least half inside it (mirrored to defense
through the alignment) take the bands the fresh ray derivation measured
(work/ray-bands-current). Protected names kept these solid; the ruling
lifts that protection for the named spot only.
"""
import argparse
import gzip
import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import shapely

from compile_reviewed_svg_height_map import polygon

REVIEW = Path('scripts/data/reviewed-openings-2026-09-19.json')
ALIGN = Path('E:/IcarusWorldAudit/2026-09-06/tactical-alignment-sides-v1')


def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))


def mirror(box, side, alignment):
    shape = shapely.box(*box)
    if side == 'attack':
        return shape
    a = np.array(alignment['nativeToAttackSvg']); d = np.array(alignment['nativeToDefenseSvg'])
    inv = np.linalg.inv(a[:, :2])
    return shapely.Polygon([d[:, :2] @ (inv @ (np.array(p) - a[:, 2])) + d[:, 2] for p in shape.exterior.coords])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets', type=Path, default=Path('assets/maps'))
    ap.add_argument('--derived', type=Path, default=Path('work/ray-bands-current'))
    ap.add_argument('--out', type=Path, default=Path('work/reviewed-openings/candidate'))
    ap.add_argument('--install', action='store_true')
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    review = json.loads(REVIEW.read_text())
    by_map = {}
    for entry in review['openings']:
        by_map.setdefault(entry['map'], []).append(entry)
    log = []
    for m, entries in by_map.items():
        alignment = json.loads((ALIGN / f'{m}.json').read_text())
        for s in ('attack', 'defense'):
            name = f'{m}_svg_height_{s}.json.gz'
            model = read(a.assets / name)
            rows = {r['id']: r for r in json.loads((a.derived / f'{m}_{s}_diff.json').read_text())}
            changed = 0
            for entry in entries:
                region = mirror(entry['attackBox'], s, alignment)
                receiver = shapely.union_all([polygon(r) for r in model['receiver']])
                ring = shapely.Polygon(max(shapely.get_parts(receiver), key=lambda q: q.area).exterior)
                for w in model['walls']:
                    shape = polygon(w)
                    if shape.area <= 0 or shape.intersection(region).area < 0.5 * shape.area:
                        continue
                    # The map edge beside a mouth stays sealed.
                    if shape.difference(ring).area >= 0.25 * shape.area:
                        continue
                    r = rows.get(w['id'])
                    if r is None or r.get('reason') or not r.get('after') or r['after'] == w['bands']:
                        continue
                    log.append(dict(map=m, side=s, opening=entry['name'], wall=w['id'], before=w['bands'], after=r['after']))
                    w['bands'] = [list(b) for b in r['after']]
                    changed += 1
            write(a.out / name, model)
            print(f'{m}/{s}: opened {changed} reviewed walls', flush=True)
    (a.out / 'changes.json').write_text(json.dumps(log, indent=1))
    if a.install:
        for m in by_map:
            for s in ('attack', 'defense'):
                n = f'{m}_svg_height_{s}.json.gz'; shutil.copyfile(a.out / n, a.assets / n)
        subprocess.run([sys.executable, 'scripts/svg_wall_footprint_integrity.py'], check=True)
        subprocess.run([sys.executable, 'scripts/standing_source_integrity.py'], check=True)


if __name__ == '__main__':
    main()
