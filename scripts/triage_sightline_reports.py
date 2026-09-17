"""Turn sightline reports from the app into something a rule can be read off.

Reads every *.json produced by the in-app "Copy sightline report" action
(a folder, individual files, or a file containing one pasted report per
line / JSON array), then prints:

* one line per report: map, side, where, the standing level chosen, and the
  wall the centre ray stopped on with its band;
* the walls hit across all reports grouped by parent stroke, with how many
  reports touch them and their band tops, so a recurring class shows up as
  one row rather than nine screenshots;
* a gallery pose string per map/side, ready for tool/svg_height_cone_gallery_test.dart.

Writes <out>/triage.md and <out>/poses.json.
"""
import argparse
import json
import math
from collections import defaultdict
from pathlib import Path


def load_reports(paths):
    reports = []
    for raw in paths:
        p = Path(raw)
        files = sorted(p.glob('*.json')) if p.is_dir() else [p]
        for f in files:
            text = f.read_text(encoding='utf-8').strip()
            if not text:
                continue
            try:
                data = json.loads(text)
            except json.JSONDecodeError:
                data = [json.loads(line) for line in text.splitlines() if line.strip()]
            items = data if isinstance(data, list) else [data]
            for item in items:
                if isinstance(item, dict) and item.get('version') == 1:
                    item['_file'] = str(f)
                    reports.append(item)
    return reports


def stroke_of(wall_id):
    parts = wall_id.split('-')
    return '-'.join(parts[:3]) if len(parts) >= 3 else wall_id


def centre_hit(report):
    hits = report.get('hits') or []
    if not hits:
        return None
    facing = report.get('facingRadians', 0.0)
    return min(hits, key=lambda h: abs(math.atan2(math.sin(h['angleRadians'] - facing),
                                                  math.cos(h['angleRadians'] - facing))))


def band_text(hit):
    if hit is None or hit.get('wallId') is None:
        return 'clear'
    floor = hit.get('floorMeters') or 0.0
    bands = hit.get('bands') or []
    if not bands:
        return f"{hit['wallId']} (non-blocking)"
    spans = ', '.join(f"{floor + b[0]:.1f}-{'inf' if b[1] is None else f'{floor + b[1]:.1f}'}" for b in bands)
    return f"{hit['wallId']} @{hit['distanceSvg']:.1f} [{spans}] m"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('paths', nargs='+')
    ap.add_argument('--out', type=Path, default=Path('work/sightline-triage'))
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    reports = load_reports(a.paths)
    lines = [f'# Sightline reports ({len(reports)})', '']
    by_stroke = defaultdict(lambda: dict(reports=set(), walls=defaultdict(set)))
    poses = defaultdict(list)
    for i, r in enumerate(reports):
        st = r.get('standing') or {}
        c = centre_hit(r)
        lines.append(
            f"{i:2d}. {r['map']}/{r['side']} at ({r['svgOrigin'][0]:.1f},{r['svgOrigin'][1]:.1f}) "
            f"facing {math.degrees(r.get('facingRadians', 0)):.0f}deg  "
            f"eye {st.get('eyeMeters', float('nan')):.2f} m on {st.get('supportId') or 'ground'} "
            f"(ground {st.get('groundMeters', float('nan')):.2f})  centre -> {band_text(c)}"
            + (f"  note: {r['note']}" if r.get('note') else ''))
        poses[f"{r['map']}/{r['side']}"].append(
            f"{r['svgOrigin'][0]:.1f},{r['svgOrigin'][1]:.1f},{math.degrees(r.get('facingRadians', 0)):.1f}")
        for h in r.get('hits') or []:
            if not h.get('wallId'):
                continue
            key = (r['map'], r['side'], stroke_of(h['wallId']))
            by_stroke[key]['reports'].add(i)
            floor = h.get('floorMeters') or 0.0
            tops = tuple(round(floor + (b[1] if b[1] is not None else 999), 1) for b in (h.get('bands') or []))
            by_stroke[key]['walls'][h['wallId']].add(tops)
    lines += ['', '## Strokes hit, most reports first', '',
              '| map/side | stroke | reports | pieces hit | band tops (m) |', '|---|---|---|---|---|']
    for (m, s, stroke), entry in sorted(by_stroke.items(), key=lambda kv: -len(kv[1]['reports'])):
        tops = sorted({t for tops in entry['walls'].values() for t in tops for t in t})
        lines.append(f"| {m}/{s} | {stroke} | {len(entry['reports'])} | {len(entry['walls'])} | "
                     f"{', '.join(str(t) for t in tops[:8])} |")
    lines += ['', '## Gallery poses', '']
    for key, ps in poses.items():
        m, s = key.split('/')
        lines.append(f'ICARUS_GALLERY_MAP={m} ICARUS_GALLERY_SIDE={s} ICARUS_GALLERY_POSES="{";".join(ps)}"')
    (a.out / 'triage.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    (a.out / 'poses.json').write_text(json.dumps(poses, indent=1))
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
