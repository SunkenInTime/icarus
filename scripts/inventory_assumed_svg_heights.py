"""Inventory every bundled infinite or unknown wall, with local source evidence.

An old `reviewed` label does not resolve an assumed height. Every record starts
unresolved and stays tied to the exact original asset until measured evidence
or a specific gameplay decision accounts for its entire painted footprint.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from audit_all_map_gameplay_levels import MAPS, OUT, ROOT, read
from audit_svg_source_height_associations import EXCLUDED
from compile_reviewed_svg_height_map import polygon
from svg_review_source import source_world


DESTINATION = OUT.parent / 'all-map-height-resolution-v6'


def inventory(name, output):
    directory = output / name
    model_path = directory / 'before-attack.json.gz'
    model = read(model_path)
    old_path = OUT.parent / f'all-map-svg-height-reviewed-v1/{name}-attack.json'
    if name == 'split':
        old_path = OUT.parent / 'split-svg-semantic-prototype-v6/split-attack.json'
    old = read(old_path)
    originals = {w['id']: w for w in old['walls']}
    source_path = source_world(name) / 'geometry.json'
    objects = read(source_path)['objects']
    association_path = OUT.parent / f'all-map-svg-source-associations-v1/{name}.json.gz'
    associations = read(association_path)
    by_parent = {w['wallId']: w for w in associations['walls']}
    rays = read(OUT / name / 'raised-sightlines.json')['candidates']
    rows = []
    for wall in model['walls']:
        if not wall['unknownHeight'] and not any(hi is None for _, hi in wall['bands']):
            continue
        wid = wall['id']
        parents = [k for k in by_parent if wid == k or wid.startswith(k + '-')]
        parent = max(parents, key=len) if parents else None
        shape = polygon(wall)
        counts = Counter()
        stations = []
        if parent is not None:
            for sample in by_parent[parent]['stations']:
                if shape.distance(shapely.Point(sample['svg'])) > 1.0:
                    continue
                candidates = []
                for c in sample['candidates']:
                    obj = objects[c['object']]
                    if any(word in obj['path'].lower() for word in EXCLUDED):
                        continue
                    candidates.append(c)
                    if c['verticalFaces']:
                        counts[c['object']] += 1
                stations.append(dict(svg=sample['svg'], candidates=candidates))
        previous = originals.get(wid)
        if previous is None:
            keys = [k for k in originals if wid == k or wid.startswith(k + '-')]
            previous = originals[max(keys, key=len)] if keys else {}
        evidence = previous.get('heightEvidence', {})
        source_candidates = [dict(object=oid, path=objects[oid]['path'],
                                  verticalStations=count,
                                  boundsMeters=objects[oid]['boundsMeters'])
                             for oid, count in counts.most_common()]
        flags = [r for r in rays if r['wallId'] == wid]
        rows.append(dict(map=name, wallId=wid, parentWallId=parent,
            status='unresolved', unknownHeight=wall['unknownHeight'],
            bands=wall['bands'], floorElevationMeters=wall['floorElevationMeters'],
            boundsSvg=list(shape.bounds), paintedAreaSvg=shape.area,
            rings=wall['rings'], fillRule=wall['fillRule'],
            previousEvidence=evidence, sourceCandidates=source_candidates,
            associationStations=stations,
            priorRayFindings=dict(falseBlock=sum(r['differenceSvg'] > 3 for r in flags),
                                 leak=sum(r['differenceSvg'] < -3 for r in flags))))
    report = dict(schemaVersion=1, map=name,
        assetSha256=hashlib.sha256(model_path.read_bytes()).hexdigest(),
        sourceMetadataSha256=hashlib.sha256(source_path.read_bytes()).hexdigest(),
        associationSha256=hashlib.sha256(association_path.read_bytes()).hexdigest(),
        associationGeometrySha256=associations['geometrySha256'],
        records=rows)
    (directory / 'assumed-height-review.json').write_text(json.dumps(report, indent=2))
    print(name, len(rows), 'assumed heights', flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=DESTINATION)
    parser.add_argument('maps', nargs='*', default=MAPS)
    args = parser.parse_args()
    reports = [inventory(name, args.output) for name in args.maps]
    reports = [read(args.output / name / 'assumed-height-review.json') for name in MAPS
               if (args.output / name / 'assumed-height-review.json').exists()]
    summary = [dict(map=r['map'], assumedWalls=len(r['records']),
                    withSourceCandidates=sum(bool(w['sourceCandidates']) for w in r['records']),
                    withPriorRayFindings=sum(any(w['priorRayFindings'].values()) for w in r['records']))
               for r in reports]
    (args.output / 'assumed-height-summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
