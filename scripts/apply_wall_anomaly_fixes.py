"""Apply the two wall-height classes the anomaly detector can settle on its own.

* borrowed-height: an isolated stroke piece whose band top is far above what
  the 3D column on its own ink contains, while its touching neighbours agree
  with the 3D. Its top is lowered to the larger of its own column top and its
  agreeing neighbours' tops, never below a standing eye, so a rail beside a
  building stops blocking from the building's height.
* see-under: a lowest band lifted off the floor where the 3D is solid beneath
  it. The band is anchored to the floor.

Input: work/anomalies/<map>_<side>.json from detect_wall_anomalies.py.
Writes candidates to --out; --install copies them into assets/maps and
refreshes both certificates.
"""
import argparse, gzip, json, re, shutil, subprocess, sys
from pathlib import Path

MAPS = ['abyss','ascent','bind','breeze','corrode','fracture','haven','icebox','lotus','pearl','split','summit','sunset']
MIN_DROP_M = 2.0
MIN_SOLID = 0.8
MIN_FACES_UNDER = 40      # a pipe or beam has air beneath it; a wall base has a face.
MIN_BAND_THICKNESS_M = 1.5
MIN_TOP_OVER_GROUND = 1.9
PROTECTED = re.compile(r'review|reported|gameplay|opening|confirmed|owned|retained|prior-height|finite|tunnel|section|user|profile|station|assembly|ownership|ramp|source|crate|header|jamb|sill|tier|door|window|facade|shrine|balcony|platform|rail|marker|symbol|zipline', re.I)
REVIEWED = Path('work/reviewed-wall-ids.json')
HOLDOUTS = Path('scripts/data/wall-anomaly-holdouts.json')  # hits awaiting Dara's verdict

def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--anomalies', type=Path, default=Path('work/anomalies'))
    ap.add_argument('--assets', type=Path, default=Path('assets/maps'))
    ap.add_argument('--out', type=Path, default=Path('work/anomalies/candidate'))
    ap.add_argument('--install', action='store_true')
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    reviewed = json.loads(REVIEWED.read_text()) if REVIEWED.exists() else {}
    holdouts = json.loads(HOLDOUTS.read_text()) if HOLDOUTS.exists() else {}
    log = []
    for m in MAPS:
        keep = set(reviewed.get(m, [])) | set(reviewed.get('?', []))
        for s in ('attack', 'defense'):
            held = set((holdouts.get(m) or {}).get(s, []))
            model = read(a.assets / f'{m}_svg_height_{s}.json.gz')
            path = a.anomalies / f'{m}_{s}.json'
            rows = json.loads(path.read_text()) if path.exists() else []
            walls = {w['id']: w for w in model['walls']}
            lowered = anchored = 0
            for r in rows:
                e = r.get('evidence', {})
                if r['detector'] == 'borrowed-height':
                    if e.get('dropM', 0) < MIN_DROP_M: continue
                    ground = e.get('groundM')
                    column = e.get('measuredColumnTopM')
                    neighbours = e.get('neighbourAssignedTopM') or []
                    if column is None or ground is None: continue
                    target = max([column] + neighbours)
                    target = max(target, ground + MIN_TOP_OVER_GROUND)
                    for wid in (r.get('pieces') or [r['wallId']]):
                        w = walls.get(wid)
                        if w is None or not w['bands'] or wid in keep or wid in held or PROTECTED.search(wid): continue
                        floor = w['floorElevationMeters']
                        top_rel = target - floor
                        bands = [[b[0], b[1]] for b in w['bands'] if b[0] < top_rel]
                        if not bands: continue
                        if bands[-1][1] is None or bands[-1][1] > top_rel:
                            bands[-1][1] = round(top_rel, 4)
                        if bands != w['bands']:
                            log.append(dict(map=m, side=s, wall=wid, before=w['bands'], after=bands, cls='borrowed'))
                            w['bands'] = bands; lowered += 1
                elif r['detector'] == 'see-under':
                    if e.get('solidFractionUnderBase', 0) < MIN_SOLID or e.get('facesUnderBase', 0) < MIN_FACES_UNDER: continue
                    for wid in (r.get('pieces') or [r['wallId']]):
                        w = walls.get(wid)
                        if w is None or not w['bands'] or w['bands'][0][0] <= 0.05 or wid in keep or wid in held or PROTECTED.search(wid): continue
                        first = w['bands'][0]
                        if first[1] is not None and first[1] - first[0] < MIN_BAND_THICKNESS_M: continue
                        before = [list(b) for b in w['bands']]
                        w['bands'][0][0] = 0.0
                        log.append(dict(map=m, side=s, wall=wid, before=before, after=w['bands'], cls='see-under'))
                        anchored += 1
            write(a.out / f'{m}_svg_height_{s}.json.gz', model)
            print(f'{m}/{s}: lowered {lowered} borrowed tops, anchored {anchored} lifted bases')
    (a.out / 'changes.json').write_text(json.dumps(log, indent=1))
    if a.install:
        for m in MAPS:
            for s in ('attack', 'defense'):
                n = f'{m}_svg_height_{s}.json.gz'; shutil.copyfile(a.out / n, a.assets / n)
        subprocess.run([sys.executable, 'scripts/svg_wall_footprint_integrity.py'], check=True)
        subprocess.run([sys.executable, 'scripts/standing_source_integrity.py'], check=True)

if __name__ == '__main__':
    main()
