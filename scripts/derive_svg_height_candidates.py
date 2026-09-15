"""Rank source-height candidates for review. Does not write application assets.

Every result remains pending review. Coverage is a correspondence heuristic,
not proof of gameplay visibility or a reason to remove a painted wall.
"""
import argparse
from collections import Counter
import gzip
import json
from pathlib import Path
import re

import numpy as np
import shapely

from audit_svg_source_height_associations import REV


def excluded(path):
    text = path.lower()
    return (any(word in text for word in (
        'vista', 'lightleak', 'lighting', 'canopy', 'leaves', 'foliage',
        'decal', 'particle', 'skybox', 'skydome', 'hangingflags',
        'handingflags', 'wireshape', 'wirekit', 'cable', 'flower', 'grass'))
        or bool(re.search(r'(?:tree|plant|bush)_\d', text)))


def terrain(path):
    text = path.lower().split('/')[1]
    return any(x in text for x in ('ground', 'floor', 'stair', 'ramp')) and not any(
        x in text for x in ('wall', 'railing', 'rail', 'cover', 'building', 'tower', 'ledge'))


def overhead(path):
    return any(x in path.lower() for x in ('ceiling', 'roof'))


def derive(name):
    path = REV / f'all-map-svg-source-associations-v1/{name}.json.gz'
    audit = json.loads(gzip.decompress(path.read_bytes()))
    model = json.loads((REV / f'all-map-svg-footprints-v1/{name}-attack.json').read_text())
    walls = {w['id']: w for w in model['walls']}
    decisions = []
    for row in audit['walls']:
        lookup = {o['object']: o for o in row['sourceObjects']}
        vertical_counts, ground_counts = Counter(), Counter()
        all_counts = Counter()
        for sample in row['stations']:
            z = sample['primaryGroundZ']
            if z is None:
                continue
            for candidate in sample['candidates']:
                oid = candidate['object']
                obj = lookup[oid]
                if excluded(obj['path']):
                    continue
                if candidate['nearbyMaximumZ'] >= z - .5:
                    all_counts[oid] += 1
                if candidate['upwardFaces'] and terrain(obj['path']):
                    ground_counts[oid] += 1
                if (candidate['verticalFaces'] and not overhead(obj['path'])
                        and candidate['verticalMaximumZ'] > z + .3
                        and candidate['verticalMinimumZ'] < z + 5
                        and not terrain(obj['path'])):
                    vertical_counts[oid] += 1
        maximum = max(vertical_counts.values(), default=0)
        # A dominant object must follow the drawn wall, not merely touch an end.
        selected = [oid for oid, count in vertical_counts.most_common()
                    if count >= max(1, maximum * .6)]
        if len(row['stations']) > 100:
            # A connected building outline can legitimately traverse many source
            # assemblies. This only proposes the assembly envelope for review.
            selected = [oid for oid, count in vertical_counts.most_common()
                        if count >= 3]
        ground_values = [s['primaryGroundZ'] for s in row['stations']
                         if s['primaryGroundZ'] is not None]
        floor = float(np.median(ground_values)) if ground_values else None
        top = max((lookup[i]['boundsMeters'][1][2] for i in selected), default=None)
        wall = walls[row['wallId']]
        rings = [np.array(r).reshape(-1, 2) for r in wall['rings']]
        shape = shapely.Polygon(rings[0], rings[1:])
        decisions.append(dict(wallId=row['wallId'], reviewStatus='pending',
            suggestedMode='source-height' if selected else 'unresolved',
            floorElevationMeters=floor, maximumSourceZ=top,
            selectedSourceObjects=selected,
            sourceCandidates=[dict(**lookup[i], verticalStations=count)
                              for i, count in vertical_counts.most_common()],
            terrainCandidates=[dict(**lookup[i], upwardStations=count)
                               for i, count in ground_counts.most_common(8)],
            overheadCandidates=[lookup[i] for i, _ in all_counts.most_common()
                                if overhead(lookup[i]['path'])],
            stationCount=len(row['stations']),
            groundRange=[min(ground_values), max(ground_values)] if ground_values else None,
            boundsSvg=list(shape.bounds),
            interiorRings=len(rings)-1,
            supportCandidateRings=[r.reshape(-1).tolist() for r in rings[1:]],
            reason='Ranked by local vertical-face coverage. Inspect shape, stacked props, ground and gameplay role before accepting.'))
    return dict(map=name, sourceAudit=str(path), walls=decisions,
                status='offline-review-candidates', runtimeEnabled=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--maps', nargs='+', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for name in args.maps:
        output = derive(name)
        (args.out / f'{name}.json').write_text(json.dumps(output, indent=2, allow_nan=False)+'\n')
        print(name, len(output['walls']), 'pending review')
