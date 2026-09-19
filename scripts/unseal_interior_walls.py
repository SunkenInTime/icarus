"""Give back the measured bands of walls the perimeter seal wrongly made infinite.

The first seal treated any wall whose ink was not wholly inside the map's
outer ring as the map edge. A long stroke that only touches the edge at one
end (the rail around Haven's Garden platform) was sealed along its whole
length, so an eye on the platform could not see over a 2 m rail. The seal
now asks for OUTSIDE_FRACTION of the ink to lie outside the ring; this pass
applies the same test to the bundled assets and restores the bands such a
wall carried before the seal, or before the ray derivation when the
derivation had emptied it, with the base anchored to the floor as the seal's
second rule would have done.
"""
import argparse
import gzip
import json
import shutil
import subprocess
import sys
from pathlib import Path

import shapely

from compile_reviewed_svg_height_map import polygon
from seal_perimeter_and_bases import MAPS, OUTSIDE_FRACTION


def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets', type=Path, default=Path('assets/maps'))
    ap.add_argument('--pre-seal', type=Path, default=Path('work/pre-seal'))
    ap.add_argument('--pre-derivation', type=Path, default=Path('work/head-assets'))
    ap.add_argument('--out', type=Path, default=Path('work/unseal/candidate'))
    ap.add_argument('--install', action='store_true')
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    log = []
    for m in MAPS:
        for s in ('attack', 'defense'):
            name = f'{m}_svg_height_{s}.json.gz'
            model = read(a.assets / name)
            pre = {w['id']: w for w in read(a.pre_seal / name)['walls']}
            head_path = a.pre_derivation / name
            head = {w['id']: w for w in read(head_path)['walls']} if head_path.exists() else {}
            receiver = shapely.union_all([polygon(r) for r in model['receiver']])
            ring = shapely.Polygon(max(shapely.get_parts(receiver), key=lambda q: q.area).exterior)
            restored = 0
            for w in model['walls']:
                if not (len(w['bands']) == 1 and w['bands'][0][0] <= 0.05 and w['bands'][0][1] is None):
                    continue
                before = pre.get(w['id'])
                if before is None or before['bands'] == w['bands']:
                    continue
                shape = polygon(w)
                if shape.area <= 0 or shape.difference(ring).area / shape.area >= OUTSIDE_FRACTION:
                    continue
                source = before['bands'] or (head.get(w['id']) or {}).get('bands') or []
                bands = [list(b) for b in source]
                lifted = bool((head.get(w['id']) or {}).get('bands')) and head[w['id']]['bands'][0][0] > 0.05
                if bands and bands[0][0] > 0.05 and not lifted:
                    bands[0][0] = 0.0
                log.append(dict(map=m, side=s, wall=w['id'], after=bands,
                                fromPreSeal=bool(before['bands'])))
                w['bands'] = bands
                restored += 1
            write(a.out / name, model)
            print(f'{m}/{s}: unsealed {restored} interior walls', flush=True)
    (a.out / 'changes.json').write_text(json.dumps(log, indent=1))
    if a.install:
        for m in MAPS:
            for s in ('attack', 'defense'):
                n = f'{m}_svg_height_{s}.json.gz'; shutil.copyfile(a.out / n, a.assets / n)
        subprocess.run([sys.executable, 'scripts/svg_wall_footprint_integrity.py'], check=True)
        subprocess.run([sys.executable, 'scripts/standing_source_integrity.py'], check=True)


if __name__ == '__main__':
    main()
