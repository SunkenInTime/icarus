"""Two gameplay rules applied on top of derived wall bands.

1. The map's outer edge is never transparent. Every wall piece that touches
   the receiver union's exterior ring blocks at every height, because what
   lies beyond it is not playable space and a sightline that leaves the map
   and re-enters somewhere else means nothing to a player. Interior holes
   (boxes, voids drawn inside the map) keep their derived bands.

2. A wall stands on its floor. A derived lowest band that starts above the
   floor is kept only when the reviewed data already had it lifted (a known
   bridge or overhang) or the derivation saw a real opening beneath: at
   least a standing eye tall (1.9 m over the local ground) with dense
   corridor evidence. Otherwise the band is anchored to the floor, so a low
   eye cannot slip under a wall whose base the render scene did not carry.
"""
import argparse, gzip, json, sys
from pathlib import Path
import shapely
sys.path.insert(0, str(Path(__file__).parent))
from compile_reviewed_svg_height_map import polygon

MAPS = ['abyss','ascent','bind','breeze','corrode','fracture','haven','icebox','lotus','pearl','split','summit','sunset']
EDGE_TOUCH = 0.35
OPENING_M = 1.9
DENSE_FACES = 100

def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--candidate', type=Path, required=True)
    ap.add_argument('--baseline', type=Path, required=True)
    ap.add_argument('--diffs', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    for m in MAPS:
        for s in ('attack', 'defense'):
            cand = read(a.candidate / f'{m}_svg_height_{s}.json.gz')
            base = {w['id']: w for w in read(a.baseline / f'{m}_svg_height_{s}.json.gz')['walls']}
            diff_path = a.diffs / f'{m}_{s}_diff.json'
            rows = {}
            if diff_path.exists():
                d = json.loads(diff_path.read_text()); rows = {r['id']: r for r in (d['walls'] if isinstance(d, dict) else d)}
            receiver = shapely.union_all([polygon(r) for r in cand['receiver']])
            outer = shapely.Polygon(max(shapely.get_parts(receiver), key=lambda p: p.area).exterior).buffer(EDGE_TOUCH)
            sealed = anchored = 0
            for w in cand['walls']:
                shape = polygon(w)
                if m != 'split' and not outer.contains(shape):
                    if not (w['bands'] and w['bands'][0][0] <= 0.05 and w['bands'][-1][1] is None):
                        w['bands'] = [[0.0, None]]; w['unknownHeight'] = False; sealed += 1
                    continue
                if not w['bands'] or w['bands'][0][0] <= 0.05:
                    continue
                head = base[w['id']]
                head_lifted = bool(head['bands']) and head['bands'][0][0] > 0.05
                r = rows.get(w['id'], {})
                ground = r.get('referenceGround')
                if ground is None: ground = w['floorElevationMeters']
                gap = w['floorElevationMeters'] + w['bands'][0][0] - ground
                if head_lifted or (gap >= OPENING_M and (r.get('corridorFaces') or 0) >= DENSE_FACES):
                    continue
                w['bands'][0][0] = 0.0; anchored += 1
            write(a.out / f'{m}_svg_height_{s}.json.gz', cand)
            print(f'{m}/{s}: sealed {sealed} perimeter pieces, anchored {anchored} lifted bases')

if __name__ == '__main__':
    main()
