"""Let the scene decide what stands above a reviewed opening.

A reviewed tunnel or overhead record fixes where an opening ends: its
lowest band starts at the ceiling or header. Above that, the review filled
everything up to the old assumed height as one blanket, so Pearl's B Hall
tunnel walls read solid from the 6.2 m ceiling to 11.7 m where the scene has
a slab edge and then nothing until 11 m. An eye on the upper level could not
look over the tunnel into the yard beside it.

For every tunnel-review piece (id tagged '-tunnel-') whose lowest band
starts at least MIN_BASE_M above its floor the reviewed bands are intersected with the fresh ray derivation's runs
(work/ray-bands-current): the scene may cut open air out of a reviewed
band, never add structure to it, and only when at least MIN_REMOVED_M of
band goes. A piece the derivation could not read is left alone.

Writes candidates under --out and, with --install, copies them over
assets/maps and refreshes both certificates.
"""
import argparse
import gzip
import json
import shutil
import subprocess
import sys
from pathlib import Path

MAPS = ['abyss', 'ascent', 'bind', 'breeze', 'corrode', 'fracture', 'haven',
        'icebox', 'lotus', 'pearl', 'split', 'summit', 'sunset']
MIN_BASE_M = 3.0
TAG = '-tunnel-'   # products of the tunnel reviews; other reviewed openings keep their structure


def read(p): return json.loads(gzip.decompress(Path(p).read_bytes()))
def write(p, d): Path(p).write_bytes(gzip.compress(json.dumps(d).encode(), mtime=0))


MIN_REMOVED_M = 1.0


def intersect(bands, runs):
    """The reviewed bands with everything the derivation reads as open cut out."""
    out = []
    for lo, hi in bands:
        for rlo, rhi in runs:
            a = max(lo, rlo)
            b = hi if hi is None else (hi if rhi is None else min(hi, rhi))
            if rhi is not None and hi is not None:
                b = min(hi, rhi)
            elif rhi is not None:
                b = rhi
            if b is None or b > a:
                out.append([a, b])
    return out


def removed(bands, kept):
    total = sum((b[1] if b[1] is not None else 60) - b[0] for b in bands)
    left = sum((b[1] if b[1] is not None else 60) - b[0] for b in kept)
    return total - left


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets', type=Path, default=Path('assets/maps'))
    ap.add_argument('--derived', type=Path, default=Path('work/ray-bands-current'))
    ap.add_argument('--out', type=Path, default=Path('work/above-openings/candidate'))
    ap.add_argument('--install', action='store_true')
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    log = []
    for m in MAPS:
        for s in ('attack', 'defense'):
            name = f'{m}_svg_height_{s}.json.gz'
            model = read(a.assets / name)
            diff_path = a.derived / f'{m}_{s}_diff.json'
            rows = {r['id']: r for r in json.loads(diff_path.read_text())} if diff_path.exists() else {}
            changed = 0
            for w in model['walls']:
                if TAG not in w['id'] or not w['bands'] or w['bands'][0][0] < MIN_BASE_M:
                    continue
                r = rows.get(w['id'])
                if r is None or r.get('reason') or not r.get('after'):
                    continue
                bands = intersect(w['bands'], r['after'])
                if not bands or bands == w['bands'] or removed(w['bands'], bands) < MIN_REMOVED_M:
                    continue
                log.append(dict(map=m, side=s, wall=w['id'], before=w['bands'], after=bands))
                w['bands'] = bands
                changed += 1
            write(a.out / name, model)
            print(f'{m}/{s}: re-measured above {changed} openings', flush=True)
    (a.out / 'changes.json').write_text(json.dumps(log, indent=1))
    if a.install:
        for m in MAPS:
            for s in ('attack', 'defense'):
                n = f'{m}_svg_height_{s}.json.gz'; shutil.copyfile(a.out / n, a.assets / n)
        subprocess.run([sys.executable, 'scripts/svg_wall_footprint_integrity.py'], check=True)
        subprocess.run([sys.executable, 'scripts/standing_source_integrity.py'], check=True)


if __name__ == '__main__':
    main()
