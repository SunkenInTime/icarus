"""Keep a piece's lowered or opened band only when its touching neighbours agree.

Pieces of one painted stroke that touch each other are one physical wall. A
piece whose new top drops well below its neighbours' cuts a see-through notch
into a wall that is otherwise solid, which no player would recognise. Such a
piece keeps its baseline bands. Pieces whose top rose or gained upper bands
are left as derived.
"""
import argparse, gzip, json, sys
from pathlib import Path
import shapely
sys.path.insert(0, str(Path(__file__).parent))
from compile_reviewed_svg_height_map import polygon

MAPS = ['abyss','ascent','bind','breeze','corrode','fracture','haven','icebox','lotus','pearl','split','summit','sunset']
TOUCH = 0.05
AGREE_M = 1.0

def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))
def top(w):
    if not w['bands']: return 0.0
    return max((w['floorElevationMeters'] + (b[1] if b[1] is not None else 1e9)) for b in w['bands'])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', type=Path, required=True)
    ap.add_argument('--baseline', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    total = 0
    for m in MAPS:
        for s in ('attack', 'defense'):
            cand = read(a.candidate / f'{m}_svg_height_{s}.json.gz'); base = read(a.baseline / f'{m}_svg_height_{s}.json.gz')
            ob = {w['id']: w for w in base['walls']}
            walls = cand['walls']
            by_stroke = {}
            for i, w in enumerate(walls): by_stroke.setdefault('-'.join(w['id'].split('-')[:3]), []).append(i)
            restored = 0
            for members in by_stroke.values():
                if len(members) < 2: continue
                shapes = [polygon(walls[i]).buffer(TOUCH) for i in members]
                tree = shapely.STRtree(shapes)
                neigh = {i: set() for i in members}
                for k, shp in enumerate(shapes):
                    for j in tree.query(shp, predicate='intersects'):
                        if j != k: neigh[members[k]].add(members[int(j)])
                for i in members:
                    w = walls[i]; o = ob[w['id']]
                    if w['bands'] == o['bands'] or not neigh[i]: continue
                    nt, ot = top(w), top(o)
                    if nt >= ot - 0.3: continue            # not lowered
                    tops = [top(walls[j]) for j in neigh[i]]
                    if all(abs(t - nt) <= AGREE_M or t < nt for t in tops): continue
                    w['bands'] = o['bands']; w['unknownHeight'] = o['unknownHeight']; restored += 1
            total += restored
            write(a.out / f'{m}_svg_height_{s}.json.gz', cand)
            print(f'{m}/{s}: restored {restored} lowered pieces whose neighbours stayed high')
    print('total', total)

if __name__ == '__main__':
    main()
