"""Reject missing and mis-heighted floors in isolated local candidate copies."""
import argparse
import copy
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from audit_all_map_gameplay_levels import ROOT, read
from compile_icebox_ramp_ground import sha
from compile_reviewed_svg_height_map import polygon
from source_geometry_projection import project_source
from verify_icebox_regional_floors import compare


def matching_ground_triangles(vertices, triangles, xy, height, tolerance=.02):
    """Choose the local level even when a ramp's distant corners differ in Z."""
    points = vertices[triangles]
    u, v = points[:, 1]-points[:, 0], points[:, 2]-points[:, 0]
    determinant = u[:, 0]*v[:, 1]-u[:, 1]*v[:, 0]
    valid = np.flatnonzero(determinant != 0)
    a = (u[valid, 2]*v[valid, 1]-u[valid, 1]*v[valid, 2])/determinant[valid]
    b = (u[valid, 0]*v[valid, 2]-u[valid, 2]*v[valid, 0])/determinant[valid]
    offset = np.asarray(xy)-points[valid, 0, :2]
    local_height = points[valid, 0, 2]+a*offset[:, 0]+b*offset[:, 1]
    return {int(i) for i in valid[np.abs(local_height-height) <= tolerance]}


def verify(source_dir, candidate_dir, fixture_path):
    source_path = source_dir / 'regional-floors.json'
    source, fixture = read(source_path), read(fixture_path)
    assert fixture['sourceSha256'] == sha(source_path)
    pose = fixture['cases'][0]
    x, y = pose['nativeXY']
    region = shapely.box(x - .05, y - .05, x + .05, y + .05)
    local_source = dict(source, domains=[])
    for domain in source['domains']:
        geometry = shapely.from_geojson(json.dumps(domain['nativeGeometry'])).intersection(region)
        if geometry.area > 1e-10:
            local_source['domains'].append(dict(domain, nativeGeometry=json.loads(shapely.to_geojson(geometry))))
    assert pose['sourceDomain'] in {d['id'] for d in local_source['domains']}
    output = candidate_dir / 'fault-controls'
    output.mkdir(exist_ok=True)
    expected_path = output / 'expected-source.json'
    expected_path.write_text(json.dumps(local_source, separators=(',', ':')) + '\n')
    alignment = read(ROOT / f"tactical-alignment-sides-v1/{fixture['map']}.json")
    records = []
    for side in ['attack', 'defense']:
        candidate_path = candidate_dir / f'candidate-{side}.json.gz'
        model = read(candidate_path)
        matrix = np.asarray(alignment[f'nativeTo{side.title()}Svg'])
        svg_region = project_source(region, [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]])
        vertices = np.asarray(model['ground']['vertices']).reshape(-1, 3)
        triangles = np.asarray(model['ground']['triangles']).reshape(-1, 3)
        geometry = shapely.polygons(vertices[triangles][:, :, :2])
        retained = np.flatnonzero(shapely.intersects(geometry, svg_region.buffer(.001)))
        certified = set(model['ground']['standingTriangles'])
        model['ground']['triangles'] = triangles[retained].flatten().tolist()
        model['ground']['standingTriangles'] = [i for i, old in enumerate(retained) if int(old) in certified]
        model['supports'] = [s for s in model['supports'] if polygon(s).intersects(svg_region)]
        baseline = compare(local_source, model, matrix, side)
        assert all(r['status'] == r['defaultStatus'] == 'passed' for r in baseline), baseline
        target = pose['expectedFloorMeters']
        support_ids = {s['id'] for s in model['supports'] if abs(float(np.asarray(
            s.get('surfacePlane') or [0, 0, s['surfaceElevationMeters']]) @
            [*pose['svg'][side], 1]) - target) <= .02}
        local_triangles = np.asarray(model['ground']['triangles']).reshape(-1, 3)
        ground_ids = matching_ground_triangles(vertices, local_triangles, pose['svg'][side], target)
        assert support_ids or ground_ids
        for fault in ['removed-required-floor', 'incorrect-local-height']:
            changed = copy.deepcopy(model)
            if fault == 'removed-required-floor':
                changed['supports'] = [s for s in changed['supports'] if s['id'] not in support_ids]
                kept = [i for i in range(len(local_triangles)) if i not in ground_ids]
                changed['ground']['triangles'] = local_triangles[kept].flatten().tolist()
                physical = set(changed['ground']['standingTriangles'])
                changed['ground']['standingTriangles'] = [i for i, old in enumerate(kept) if old in physical]
            else:
                for support in changed['supports']:
                    if support['id'] in support_ids:
                        support['surfaceElevationMeters'] += .25
                        if support.get('surfacePlane'):
                            support['surfacePlane'][2] += .25
                for index in {int(v) for i in ground_ids for v in local_triangles[i]}:
                    changed['ground']['vertices'][index * 3 + 2] += .25
            fault_path = output / f'{side}-{fault}.json.gz'
            fault_path.write_bytes(gzip.compress(json.dumps(changed, separators=(',', ':')).encode(), mtime=0))
            rows = compare(local_source, changed, matrix, side)
            failures = [r for r in rows if r['status'] != 'passed' or r['defaultStatus'] != 'passed']
            assert failures, (side, fault)
            records.append(dict(side=side, fault=fault, status='detected', candidateSha256=sha(candidate_path),
                faultSha256=sha(fault_path), changedSupports=sorted(support_ids), changedGroundTriangles=sorted(ground_ids),
                failures=failures))
    report = dict(status='passed', sourceSha256=sha(source_path), fixtureSha256=sha(fixture_path),
        expectedSourceSha256=sha(expected_path), algorithmSha256=sha(Path(__file__)),
        verifierSha256=sha(Path('scripts/verify_icebox_regional_floors.py')), pose=pose['id'],
        scope='Local 10 cm square around a frozen source pose, retaining every intersecting candidate triangle in original lookup order and every intersecting support. Expectations remain identical for baseline and fault copies.', records=records)
    (output / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(status=report['status'], checks=len(records), pose=pose['id'])))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--candidate-dir', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    args = parser.parse_args()
    verify(args.source, args.candidate_dir, args.fixture)
