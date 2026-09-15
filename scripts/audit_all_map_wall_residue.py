"""Find collapsed wall remnants and compare vertical profiles on both SVG sides."""
import argparse
from collections import Counter, defaultdict
import gzip
import hashlib
import json
from pathlib import Path
import re

import numpy as np
import shapely
from shapely.affinity import affine_transform

from compile_reviewed_svg_height_map import polygon

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
GRID = 1e-8


def read(path):
    raw = Path(path).read_bytes()
    return json.loads(gzip.decompress(raw) if str(path).endswith('.gz') else raw)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def parent_id(wall):
    match = re.match(r'p\d+-(?:stroke|fill)-\d+', wall['id'])
    return match.group() if match else wall['id']


def bands(wall):
    floor = wall.get('floorElevationMeters', 0.)
    if wall.get('unknownHeight'):
        return [[None, None]]
    return [[None if lo == 0 else floor + lo, None if hi is None else floor + hi]
            for lo, hi in wall['bands']]


def active(wall, eye):
    return any((lo is None or eye >= lo) and (hi is None or eye <= hi) for lo, hi in bands(wall))


def audit(name, spec, output):
    paths = spec['assetPaths']
    assert all(sha(path) == spec['assetSha256'][side] for side, path in paths.items())
    models = {side: read(path) for side, path in paths.items()}
    alignment_path = ROOT / f'tactical-alignment-sides-v1/{name}.json'
    alignment = read(alignment_path)
    attack, defense = [np.asarray(alignment[f'nativeTo{s}Svg']) for s in ['Attack', 'Defense']]
    linear = attack[:, :2] @ np.linalg.inv(defense[:, :2])
    shift = attack[:, 2] - linear @ defense[:, 2]
    transform = [*linear[0], *linear[1], *shift]
    geometry, trees, residue, counts = {}, {}, [], {}
    for side, model in models.items():
        shapes = [polygon(w) for w in model['walls']]
        geometry[side] = shapes
        trees[side] = shapely.STRtree(shapes)
        local = []
        for index, (wall, shape) in enumerate(zip(model['walls'], shapes)):
            # Actual collapse on the declared overlay grid is the criterion;
            # an area threshold alone would discard legitimate narrow corners.
            if shape.area > 1e-7:
                continue
            quantized = shapely.set_precision(shape, GRID)
            if quantized.area != 0:
                continue
            boundary = shape.boundary if shape.geom_type in ['Polygon', 'MultiPolygon'] else shape
            if boundary.is_empty:
                boundary = shape
            samples = [shapely.line_interpolate_point(boundary, t, normalized=True)
                       for t in [.1, .3, .5, .7, .9]] if boundary.length else [shape.representative_point()]
            novel = []
            for point in samples:
                nearby = [int(i) for i in trees[side].query(point.buffer(GRID * 4), predicate='intersects')
                          if i != index and shapes[i].area > 1e-7]
                endpoints = sorted({float(z) for i in [index, *nearby]
                                    for interval in bands(model['walls'][i]) for z in interval if z is not None})
                eyes = [*endpoints, *[(a + b) / 2 for a, b in zip(endpoints, endpoints[1:])]]
                if endpoints:
                    eyes.extend([endpoints[0] - 1, endpoints[-1] + 1])
                for eye in eyes:
                    if active(wall, eye) and not any(active(model['walls'][i], eye) for i in nearby):
                        novel.append(dict(svg=[point.x, point.y], eyeMeters=eye))
                        break
            row = dict(side=side, wallId=wall['id'], parent=parent_id(wall),
                       areaSvg=float(shape.area), spanSvg=float(boundary.length),
                       boundsSvg=list(shape.bounds), bands=bands(wall),
                       novelBlockingSamples=novel, numericalName='numerical' in wall['id'])
            local.append(row)
        residue.extend(local)
        counts[side] = dict(walls=len(shapes), collapsedRemnants=len(local),
                            remnantsWithNovelBlocking=sum(bool(r['novelBlockingSamples']) for r in local))

    # Sample all nondegenerate wall records, not only the flagged remnants.
    # Compare unioned active bands at a point against the opposite side; small
    # artwork registration differences are separated by a 0.001 SVG tolerance.
    reflected = [affine_transform(s, transform) for s in geometry['defense']]
    tree = shapely.STRtree(reflected)
    differences = []
    checked = 0
    for index, (wall, shape) in enumerate(zip(models['attack']['walls'], geometry['attack'])):
        if shape.area <= 1e-7:
            continue
        point = shape.representative_point()
        nearby = [int(i) for i in tree.query(point.buffer(.001), predicate='intersects')]
        if not nearby:
            differences.append(dict(parent=parent_id(wall), attackWallId=wall['id'],
                                    svg=[point.x, point.y], kind='missing-mirrored-ink'))
            continue
        own = [int(i) for i in trees['attack'].query(point, predicate='intersects')]
        endpoints = sorted({float(z) for w in [*[models['attack']['walls'][i] for i in own],
                                               *[models['defense']['walls'][i] for i in nearby]]
                            for interval in bands(w) for z in interval if z is not None})
        eyes = [(a + b) / 2 for a, b in zip(endpoints, endpoints[1:]) if b - a > .04]
        checked += 1
        for eye in eyes:
            left = any(active(models['attack']['walls'][i], eye) for i in own)
            right = any(active(models['defense']['walls'][i], eye) for i in nearby)
            if left != right:
                differences.append(dict(parent=parent_id(wall), attackWallId=wall['id'],
                                        defenseWallIds=[models['defense']['walls'][i]['id'] for i in nearby],
                                        svg=[point.x, point.y], eyeMeters=eye,
                                        attackBlocks=left, defenseBlocks=right, kind='vertical-profile-disagreement'))
                break
    grouped = defaultdict(list)
    for row in differences:
        grouped[(row['parent'], row['kind'])].append(row)
    groups = [dict(parent=parent, kind=kind, sampleCount=len(rows), examples=rows[:5])
              for (parent, kind), rows in sorted(grouped.items())]
    report = dict(map=name, status='audited', assetSha256=spec['assetSha256'],
                  alignmentSha256=sha(alignment_path), algorithmSha256=sha(Path(__file__)),
                  overlayGridSvg=GRID, mirrorCoordinateToleranceSvg=.001,
                  mirrorHeightGapThresholdMeters=.04, counts=counts,
                  residue=residue, mirrorSamplesChecked=checked, mirrorDifferences=differences,
                  mirrorGroups=groups,
                  limitations=['Mirror profile comparison samples one interior point per nondegenerate attack wall record.',
                               'Profile differences identify review cases, not gameplay errors.',
                               'A numerical remnant collapses on the declared overlay grid; no standing eligibility is inferred.'])
    output.mkdir(parents=True, exist_ok=True)
    (output / f'{name}.json').write_text(json.dumps(report, indent=2) + '\n')
    summary = dict(map=name, counts=counts, mirrorSamplesChecked=checked,
                   mirrorDifferenceSamples=len(differences), mirrorGroups=len(groups))
    print(json.dumps(summary), flush=True)
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=Path('work/systematic-map-review/inputs.json'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--maps', nargs='*')
    args = parser.parse_args()
    manifest = read(args.manifest)
    names = args.maps or sorted(manifest['maps'])
    summaries = [audit(name, manifest['maps'][name], args.output) for name in names]
    (args.output / 'summary.json').write_text(json.dumps(dict(manifestSha256=sha(args.manifest), maps=summaries), indent=2) + '\n')
