"""Summarise a PresentMon CSV: frame pacing and GPU time against a refresh budget."""
import csv, sys, statistics

path = sys.argv[1]
budget = float(sys.argv[2]) if len(sys.argv) > 2 else 1000 / 165
rows = list(csv.DictReader(open(path, newline='')))
print('rows', len(rows), 'columns', [c for c in rows[0].keys()][:40] if rows else [])

def col(*names):
    for n in names:
        if rows and n in rows[0]:
            return n
    return None

frame = col('FrameTime', 'MsBetweenPresents', 'msBetweenPresents')
gpu = col('GPUBusy', 'GPUTime', 'msGPUActive', 'MsGPUActive')
cpu = col('CPUBusy', 'msInPresentAPI', 'MsInPresentAPI')
disp = col('DisplayedTime', 'MsBetweenDisplayChange', 'msBetweenDisplayChange')
mode = col('PresentMode')

def series(name):
    out = []
    for r in rows:
        try:
            v = float(r[name])
        except (KeyError, ValueError, TypeError):
            continue
        if v == v:
            out.append(v)
    return out

def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))] if xs else float('nan')

for label, name in (('frame time', frame), ('gpu busy', gpu), ('cpu busy', cpu), ('displayed', disp)):
    if not name:
        print(label, ': column missing'); continue
    xs = series(name)
    if not xs:
        print(label, ': no data'); continue
    over = sum(1 for x in xs if x > budget)
    print(f'{label:10} ({name}): n={len(xs)} p50={pct(xs,.5):.2f} p90={pct(xs,.9):.2f} p99={pct(xs,.99):.2f} max={max(xs):.2f} ms  over {budget:.2f} ms budget: {over} ({100*over/len(xs):.1f}%)')
if mode:
    from collections import Counter
    print('present modes', Counter(r[mode] for r in rows).most_common(4))
