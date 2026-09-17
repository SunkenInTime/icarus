"""Reject a derived band whose top rose above anything inside the ink footprint.

The ray probe reads a corridor around the stroke, so a taller structure that
stands beside a low wall can still raise the low wall's band. The narrow
footprint reading from audit_svg_wall_heights_vs_world.py (0.25 SVG buffer)
only sees geometry on the ink itself. When a derived top exceeds that reading
by more than 1.5 m and also exceeds the baseline top, the raise is treated as
contamination and the baseline bands are kept.
"""
import argparse, gzip, json
from pathlib import Path

MAPS = ['abyss','ascent','bind','breeze','corrode','fracture','haven','icebox','lotus','pearl','split','summit','sunset']
def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))
def top(w):
    if not w['bands']: return 0.0
    return max(w['floorElevationMeters'] + (b[1] if b[1] is not None else 1e9) for b in w['bands'])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', type=Path, required=True)
    ap.add_argument('--baseline', type=Path, required=True)
    ap.add_argument('--audit', type=Path, required=True, help='narrow-footprint audit rows dir')
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    total = 0
    for m in MAPS:
        for s in ('attack', 'defense'):
            cand = read(a.candidate / f'{m}_svg_height_{s}.json.gz'); base = read(a.baseline / f'{m}_svg_height_{s}.json.gz')
            ob = {w['id']: w for w in base['walls']}
            rows = {r['id']: r for r in json.loads((a.audit / f'{m}_{s}.json').read_text())} if (a.audit / f'{m}_{s}.json').exists() else {}
            n = 0
            for w in cand['walls']:
                o = ob[w['id']]
                if w['bands'] == o['bands']: continue
                nt, ot = top(w), top(o)
                if nt <= ot + 0.3: continue
                narrow = rows.get(w['id'], {}).get('measuredColumnTop')
                if narrow is None or narrow >= nt - 1.5: continue
                w['bands'] = o['bands']; w['unknownHeight'] = o['unknownHeight']; n += 1
            total += n
            write(a.out / f'{m}_svg_height_{s}.json.gz', cand)
            print(f'{m}/{s}: capped {n} unsupported raises')
    print('total', total)

if __name__ == '__main__':
    main()
