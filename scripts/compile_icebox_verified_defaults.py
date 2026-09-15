"""Correct the ordinary A floor and remove its obsolete render-derived boost.

The complete source collision inventory provides the required standing domains.
The warehouse art mesh explicitly does not block Pawn; the independent 4.50 m
player volume supplies its actual standing floor through existing physical tops.
"""
import argparse
import gzip
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from audit_all_map_gameplay_levels import ROOT, read
from compile_icebox_ramp_ground import replace_ground, sha
from gameplay_source_floors import SourceFloors
from verify_icebox_regional_floors import compare, svg_plane

OUT = Path('work/icebox-expanded/verified-defaults-v1')
SOURCE = Path('work/icebox-acceptance/regional-floors.json')
OBSOLETE = 'icebox-a-warehouse-boost-top'


def build(install=False):
    OUT.mkdir(parents=True, exist_ok=True)
    source = read(SOURCE)
    assert not source['unresolvedInfluencingCollision']
    floor = next(d for d in source['domains'] if d['id'] == 'volume-129-0')
    boost = next(d for d in source['domains'] if d['id'] == 'volume-347-0')
    assert floor['sourceCollision'] == '/Port_BVPawn/BP_BlockingVolume220/Cube#0'
    assert floor['nativePlane'] == [0., 0., 2.]
    assert boost['sourceCollision'] == '/Port_BVPawn/BP_BlockingVolume76/Cube#0'
    assert boost['nativePlane'] == [0., 0., 4.5]
    art = SourceFloors('icebox')
    assert art.objects[3729]['path'] == 'Port_Art_A/Shell_2_WarehouseBoostA02DU/StaticMeshComponent0.239'
    evidence = art.object(3729)
    assert evidence['classification'] == 'excluded-explicit-pawn-nonblocking'
    decisions_path = ROOT/'tactical-visibility-revision/icebox-user-review-v4/icebox-decisions.json'
    previous = next(s for s in read(decisions_path)['supports'] if s['id'] == OBSOLETE)
    assert previous['sourceObjects'] == [3729]
    alignment = read(ROOT/'tactical-alignment-sides-v1/icebox.json')
    records = []
    for side in ['attack', 'defense']:
        asset = Path(f'assets/maps/icebox_svg_height_{side}.json.gz')
        before = OUT/f'before-{side}.json.gz'
        if not before.exists():
            before.write_bytes(asset.read_bytes())
        model = read(before)
        old = [s for s in model['supports'] if s['id'] == OBSOLETE]
        assert len(old) == 1 and old[0]['surfaceElevationMeters'] == previous['surfaceElevationMeters']
        matrix = np.array(alignment[f'nativeTo{side.title()}Svg'])
        domain = affine_transform(shapely.from_geojson(json.dumps(floor['nativeGeometry'])),
            [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]])
        ground, count = replace_ground(model['ground'], [(domain, svg_plane(floor['nativePlane'], matrix))])
        candidate = dict(model, ground=ground, supports=[s for s in model['supports'] if s['id'] != OBSOLETE])
        checks = compare(source, candidate, matrix, side)
        assert all(r['status'] == 'passed' and r['defaultStatus'] == 'passed' for r in checks), [
            {k:r[k] for k in ['id', 'status', 'defaultStatus', 'defaultMissingAreaSvg']}
            for r in checks if r['status'] != 'passed' or r['defaultStatus'] != 'passed']
        path = OUT/f'candidate-{side}.json.gz'
        path.write_bytes(gzip.compress(json.dumps(candidate, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
        if install:
            assert sha(asset) in [sha(before), sha(path)], 'Asset changed since this correction was prepared'
            asset.write_bytes(path.read_bytes())
        records.append(dict(side=side, beforeSha256=sha(before), candidateSha256=sha(path),
            replacedGroundTriangles=count, sourceDomainChecks=len(checks), removedSupport=OBSOLETE))
    report = dict(sourceSha256=sha(SOURCE), originalSupportEvidenceSha256=sha(decisions_path),
        sourceObject=3729, sourceCollisionEvidence=evidence, correctedGroundDomain=floor['id'],
        retainedPhysicalBoostDomain=boost['id'], records=records, installed=install)
    (OUT/'source-review.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(dict(installed=install, records=records)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install', action='store_true')
    build(parser.parse_args().install)
