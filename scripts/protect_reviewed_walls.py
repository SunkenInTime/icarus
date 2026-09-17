"""Restore reviewed bands onto a derived candidate, on both sides.

Reviewed attack walls are matched to their defense counterparts by reflecting
the attack footprint through the side alignment and taking the nearest
defense footprint by Hausdorff distance, as the review apply scripts do.
"""
import argparse, gzip, json, re, sys
from pathlib import Path
import numpy as np
from shapely.affinity import affine_transform
sys.path.insert(0, str(Path(__file__).parent))
from compile_reviewed_svg_height_map import polygon

ALIGN = Path('E:/IcarusWorldAudit/2026-09-06/tactical-alignment-sides-v1')
PROT = re.compile(r'review|reported|gameplay|opening|confirmed|owned|retained|prior-height|finite|tunnel|section|user|profile|station|assembly|ownership|ramp|source|crate|header|jamb|sill|tier|door|window|facade|shrine|balcony|platform|rail|marker|symbol|zipline', re.I)
MAPS = ['abyss','ascent','bind','breeze','corrode','fracture','haven','icebox','lotus','pearl','split','summit','sunset']

def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', type=Path, required=True)
    ap.add_argument('--baseline', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--ids', type=Path, required=True)
    ap.add_argument('--extra', type=Path, default=None, help='json {map: {side: [ids]}} to also restore')
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    reviewed = json.loads(a.ids.read_text())
    extra = json.loads(a.extra.read_text()) if a.extra and a.extra.exists() else {}
    total = 0
    for m in MAPS:
        al = json.loads((ALIGN / f'{m}.json').read_text())
        A, D = np.array(al['nativeToAttackSvg']), np.array(al['nativeToDefenseSvg'])
        lin = D[:, :2] @ np.linalg.inv(A[:, :2]); off = D[:, 2] - lin @ A[:, 2]
        refl = [*lin[0], *lin[1], *off]
        base = {s: read(a.baseline / f'{m}_svg_height_{s}.json.gz') for s in ('attack', 'defense')}
        cand = {s: read(a.candidate / f'{m}_svg_height_{s}.json.gz') for s in ('attack', 'defense')}
        keep = {'attack': set(), 'defense': set()}
        ids = set(reviewed.get(m, [])) | set(reviewed.get('?', []))
        for s in keep:
            for w in base[s]['walls']:
                # An empty reviewed band is a recorded 'annotation, not a wall' decision.
                if w['id'] in ids or PROT.search(w['id']) or not w['bands']: keep[s].add(w['id'])
            keep[s] |= set(extra.get(m, {}).get(s, []))
        # reflect protected attack walls onto defense
        dshapes = [polygon(w) for w in base['defense']['walls']]
        for w in base['attack']['walls']:
            if w['id'] not in keep['attack']: continue
            r = affine_transform(polygon(w), refl)
            best = min(range(len(dshapes)), key=lambda i: dshapes[i].hausdorff_distance(r))
            if dshapes[best].hausdorff_distance(r) < 0.05:
                keep['defense'].add(base['defense']['walls'][best]['id'])
        for s in ('attack', 'defense'):
            ob = {w['id']: w for w in base[s]['walls']}; n = 0
            for w in cand[s]['walls']:
                if w['id'] in keep[s] and w['bands'] != ob[w['id']]['bands']:
                    w['bands'] = ob[w['id']]['bands']; w['unknownHeight'] = ob[w['id']]['unknownHeight']; n += 1
            total += n
            write(a.out / f'{m}_svg_height_{s}.json.gz', cand[s])
            print(f'{m}/{s}: protected {len(keep[s])} walls, restored {n}')
    print('total restored', total)

if __name__ == '__main__':
    main()
