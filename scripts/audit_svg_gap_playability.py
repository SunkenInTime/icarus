"""Look for playable target positions behind candidate source-only wall gaps."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path

import numpy as np
import shapely

from audit_all_map_gameplay_levels import ROOT, MAPS, read
from audit_assumed_svg_sightlines import blocks
from build_all_map_gameplay_supports import support_elevation
from compile_reviewed_svg_height_map import polygon
from resolve_local_svg_wall_profiles import OUTPUT, sha
from svg_source_navigation import SourceNavigation


def inspect(name):
    directory = OUTPUT / name
    source_file = directory / 'assumed-height-source-rays.json.gz'
    rays = read(source_file)
    model = read(directory / 'candidate-attack.json.gz')
    receiver = shapely.union_all([polygon(r) for r in model['receiver']])
    shapes = [polygon(w) for w in model['walls']]
    tree = shapely.STRtree(shapes)
    supports = [s for s in model['supports'] if s.get('automaticStandingAllowed')]
    support_shapes = [polygon(s) for s in supports]
    support_tree = shapely.STRtree(support_shapes)
    matrix = np.asarray(read(ROOT / f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    nav = SourceNavigation(name)
    results = []
    for index, row in enumerate(rays['findings']):
        if row['differenceSvg'] <= 0:
            continue
        direction = np.array([math.cos(row['directionRadians']), math.sin(row['directionRadians'])])
        floor = row['eyeElevationMeters'] - model['defaultCameraHeightMeters']
        witnesses = []
        for distance in np.linspace(row['svgHit']+.1, row['sourceHit']-.1, 33):
            point = np.asarray(row['originSvg']) + distance * direction
            p = shapely.Point(point)
            if not receiver.covers(p):
                continue
            if any(blocks(model['walls'][i], row['eyeElevationMeters']) for i in tree.query(p, predicate='intersects')):
                continue
            native = (point - matrix[:, 2]) @ inverse.T
            targets = [dict(kind='source-navigation', face=i, floorMeters=z) for i, z in nav.heights(native)
                       if abs(z-floor) <= .5]
            for i in support_tree.query(p, predicate='intersects'):
                z = support_elevation(supports[i], point)
                if abs(z-floor) <= .5:
                    targets.append(dict(kind='reviewed-support', supportId=supports[i]['id'], floorMeters=z))
            if targets:
                witnesses.append(dict(svg=point.tolist(), native=native.tolist(), distanceSvg=float(distance), targets=targets))
        results.append(dict(findingIndex=index, wallId=row['wallId'], hitWallId=row['hitWallId'],
            stationSvg=row['stationSvg'], eyeElevationMeters=row['eyeElevationMeters'],
            status='playable-target-needs-opening-review' if witnesses else 'no-playable-target-witness',
            targetWitnesses=witnesses))
    report = dict(schemaVersion=1, map=name, counts=dict(Counter(r['status'] for r in results)),
        algorithmSha256=sha(Path(__file__)), sourceRaysSha256=sha(source_file),
        candidateSha256=sha(directory / 'candidate-attack.json.gz'), records=results,
        limitations=['A missing navigation witness does not reject a gameplay-confirmed boost or prove an inaccessible gap.',
                     'A playable target is a review lead; an image and local source extent still establish a named opening.'])
    (directory / 'source-gap-playability.json').write_text(json.dumps(report, separators=(',', ':')))
    print(name, report['counts'], flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=MAPS)
    for name in parser.parse_args().maps:
        inspect(name)
