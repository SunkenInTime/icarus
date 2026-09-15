"""Check that all raster columns of each explicitly bounded span were visited."""
import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import numpy as np


def run(folder):
    source = folder / 'contact-report.json'
    report = json.loads(source.read_text())
    fixtures = {f['id']: f for f in report['reviewedFixtures']}
    groups = defaultdict(list)
    for row in report['rasterProfiles']:
        groups[fixtures[row['id']]['edge'], row['side'], row['scale']].append(row)
    result = []
    for (edge, side, scale), rows in groups.items():
        axis = rows[0]['alongAxis']
        span = np.array(rows[0]['svgSpan'])
        expected = set(range(int(np.ceil(span[:, axis].min() * scale - .5)),
                             int(np.floor(span[:, axis].max() * scale - .5)) + 1))
        profiles = [p for row in rows for p in row['profiles']]
        observed = {p['column'] for p in profiles}
        bad = [dict(id=row['id'], column=p['column'], coverage=p.get('coverageDeficitPixels'))
               for row in rows for p in row['profiles']
               if not p.get('coverageContactPassed', False) or p['blankPixels'] != 0
               or p['clippedBeyondWallCoveragePixels'] > 0]
        offsets = [p['firstClearInwardSvg'] for row in rows for p in row['geometricProfiles']]
        result.append(dict(edge=edge, side=side, scale=scale, expectedColumns=len(expected),
                           observedColumns=len(observed), missingColumns=sorted(expected-observed),
                           missingInkProfiles=sum(r['missingInkProfiles'] for r in rows),
                           failingProfiles=bad, sampledMeshOffsetSvgRange=[min(offsets), max(offsets)],
                           fullRasterSpanVisited=expected <= observed))
    output = dict(scope=__doc__, contactReportSha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                  limitation='Interior coverage only. Unmodified endpoint transitions and other source blockers remain separately reviewed.',
                  sweeps=result)
    (folder / 'full-span-sweep.json').write_text(json.dumps(output, indent=2))
    for row in result:
        print(row['edge'], row['side'], row['scale'], 'missing', len(row['missingColumns']),
              'failing', len(row['failingProfiles']), 'offset', row['sampledMeshOffsetSvgRange'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    run(parser.parse_args().folder)
