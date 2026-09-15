"""Report source-domain coverage and refuse complete acceptance with unknowns."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    data = path.read_bytes()
    return json.loads(gzip.decompress(data) if path.suffix == '.gz' else data)


def accounting(required, records):
    ids = [r['sourceObject'] for r in records]
    missing = sorted(set(required) - set(ids))
    unexpected = sorted(set(ids) - set(required))
    duplicates = sorted({i for i in ids if ids.count(i) > 1})
    unresolved = [r['sourceObject'] for r in records if r.get('status') == 'unresolved']
    invalid = [r['sourceObject'] for r in records
        if r.get('status') not in ['represented', 'excluded', 'unresolved']
        or r.get('status') == 'excluded' and not r.get('reason')]
    return dict(complete=not (missing or unexpected or duplicates or unresolved or invalid),
        missing=missing, unexpected=unexpected, duplicates=duplicates,
        unresolved=unresolved, invalid=invalid)


def coverage(fixture, data, side, matrix):
    import numpy as np
    import shapely
    from shapely.affinity import affine_transform
    from compile_reviewed_svg_height_map import polygon
    from build_all_map_gameplay_supports import plane_region
    tolerance = fixture['heightToleranceMeters']
    vertices = np.asarray(data['ground']['vertices']).reshape(-1, 3)
    triangles = vertices[np.asarray(data['ground']['triangles']).reshape(-1, 3)]
    ground_shapes = shapely.polygons(triangles[:, :, :2])
    ground_tree = shapely.STRtree(ground_shapes)
    receiver = shapely.union_all([polygon(r) for r in data['receiver']])
    results = []
    for domain in fixture['domains']:
        native = shapely.from_geojson(json.dumps(domain['nativeGeometry']))
        expected = affine_transform(native, [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]])
        required = expected.intersection(receiver)
        height = domain['expectedFloorMeters']
        matched = []
        # Ground is ordered. A shadowed triangle cannot establish a level.
        remaining = required
        for index in sorted(ground_tree.query(required, predicate='intersects')):
            local = remaining.intersection(ground_shapes[index])
            if local.is_empty:
                continue
            t = triangles[index]
            plane = np.linalg.solve(np.c_[t[:, :2], np.ones(3)], t[:, 2])
            matched.append(plane_region(local, plane - [0, 0, height], -tolerance, tolerance))
            remaining = remaining.difference(ground_shapes[index])
        for support in data['supports']:
            if not support.get('automaticStandingAllowed'):
                continue
            local = polygon(support).intersection(required)
            if local.is_empty:
                continue
            plane = np.array(support.get('surfacePlane') or [0, 0, support['surfaceElevationMeters']])
            matched.append(plane_region(local, plane - [0, 0, height], -tolerance, tolerance))
        matched = shapely.union_all(matched)
        absent = required.difference(matched)
        eye = height + 1.75
        active = shapely.union_all([polygon(w) for w in data['walls'] if
            w.get('unknownHeight') or any(lo <= eye - w['floorElevationMeters'] <= hi
                or lo == 0 and eye < w['floorElevationMeters'] for lo, hi in w['bands'])])
        conflict = required.intersection(active)
        results.append(dict(id=domain['id'], side=side,
            expectedAreaSvg=expected.area, withinReceiverAreaSvg=required.area,
            outsideReceiverAreaSvg=expected.difference(receiver).area,
            missingHeightAreaSvg=absent.area, activeWallConflictAreaSvg=conflict.area,
            heightCoveragePercent=100 * required.intersection(matched).area / required.area,
            status='passed' if absent.area < 1e-6 and conflict.area < 1e-6 else 'unresolved-domain-difference'))
    return results


def verify(root, output, fixture_path):
    import numpy as np
    inventory = read(output / 'source-inventory.json')
    fixture = read(fixture_path)
    assert inventory['sourceFixtureSha256'] == digest(fixture_path)
    alignment_path = root / 'tactical-alignment-sides-v1/icebox.json'
    assert fixture['source']['alignmentSha256'] == digest(alignment_path)
    align = read(alignment_path)
    regional_source_path = output / 'regional-floors.json'
    regional_source = read(regional_source_path)
    assert regional_source['sourceInventorySha256'] == digest(output / 'source-inventory.json')
    regional_comparison = read(output / 'regional-floor-comparison.json')
    assert regional_comparison['sourceSha256'] == digest(regional_source_path)
    dispositions = copy.deepcopy(inventory['inventory'])
    measured = {r['sourceObject']: r for r in regional_source['sourceRows'] if 'sourceObject' in r}
    for record in dispositions:
        if record['status'] != 'unresolved':
            continue
        source_row = measured.get(record['sourceObject'])
        if source_row and source_row['status'] == 'no-clear-standing-domain':
            record.update(status='excluded', reason='Resolved player collider has no clear eligible standing domain in this region.', measurement=source_row)
        elif source_row and source_row['status'] == 'standing-domains-measured':
            checks = [r for r in regional_comparison['rows'] if r.get('sourceObject') == record['sourceObject']]
            if checks and all(r['status'] == 'passed' for r in checks):
                record.update(status='represented', measurement=source_row)
    source_accounting = accounting(inventory['requiredSourceObjects'], dispositions)
    source_accounting['unresolvedInfluencingCollision'] = regional_source['unresolvedInfluencingCollision']
    source_accounting['complete'] &= not regional_source['unresolvedInfluencingCollision']
    expected_bodies = {r['collision'] for r in inventory['collisionBodies']}
    measured_bodies = [r for r in regional_source['sourceRows'] if 'sourceCollision' in r]
    actual_bodies = [r['sourceCollision'] for r in measured_bodies]
    body_complete = (set(actual_bodies) == expected_bodies and len(actual_bodies) == len(expected_bodies)
        and all(r['status'] in ['standing-domains-measured', 'no-clear-standing-domain'] for r in measured_bodies))
    source_accounting['collisionBodies'] = dict(complete=body_complete, required=len(expected_bodies),
        measured=len(actual_bodies), missing=sorted(expected_bodies - set(actual_bodies)))
    source_accounting['complete'] &= body_complete
    (output / 'source-dispositions.json').write_text(json.dumps(dispositions, indent=2) + '\n')
    # An omitted disposition cannot remove the source obligation.
    missing_record = copy.deepcopy(dispositions)
    removed = missing_record.pop()
    missing_check = accounting(inventory['requiredSourceObjects'], missing_record)
    assert removed['sourceObject'] in missing_check['missing'] and not missing_check['complete']
    # A complete list with unresolved entries still cannot be certified.
    unresolved_control = copy.deepcopy(dispositions)
    unresolved_control[0]['status'] = 'unresolved'
    unresolved_check = accounting(inventory['requiredSourceObjects'], unresolved_control)
    assert unresolved_control[0]['sourceObject'] in unresolved_check['unresolved'] and not unresolved_check['complete']
    domains, runtime, asset_hashes = [], [], {}
    for side in ['attack', 'defense']:
        asset = Path(f'assets/maps/icebox_svg_height_{side}.json.gz')
        asset_hashes[side] = digest(asset)
        domains.extend(coverage(fixture, read(asset), side,
            np.array(align[f'nativeTo{side.title()}Svg'])))
        check = read(output / f'runtime-{side}.json')
        assert check['assetSha256'] == asset_hashes[side]
        assert check['sourceFixtureSha256'] == digest(fixture_path)
        runtime.append(dict(side=side, status=check['status'], cases=check['cases'], failures=len(check['failures'])))
    app = read(output / 'app/verification.json')
    assert app['status'] == 'passed'
    assert app['sourceFixtureSha256'] == digest(fixture_path)
    assert all(app['assetHashes'][f'assets/maps/icebox_svg_height_{s}.json.gz'] == h for s, h in asset_hashes.items())
    regional_fixture_path = Path('test/fixtures/icebox_regional_standing.json')
    regional_fixture = read(regional_fixture_path)
    assert regional_fixture['sourceSha256'] == digest(regional_source_path)
    assert app['regionalFixtureSha256'] == digest(regional_fixture_path)
    regional_runtime = []
    for side in ['attack', 'defense']:
        assert regional_comparison['assetSha256'][side] == asset_hashes[side]
        check = read(output / f'regional-runtime-{side}.json')
        assert check['assetSha256'] == asset_hashes[side]
        assert check['sourceFixtureSha256'] == digest(regional_fixture_path)
        regional_runtime.append(dict(side=side, status=check['status'], cases=check['cases'],
            applicable=sum(r['status'] == 'passed' for r in check['rows']),
            outsideSvgFloor=sum(r['status'] == 'outside-svg-floor' for r in check['rows']),
            insideActiveWall=sum(r['status'] == 'inside-active-svg-wall' for r in check['rows'])))
    walls = read(output / 'regional-wall-comparison.json')
    assert all(d['assetSha256'] == asset_hashes[d['side']] for d in walls['delivery'])
    ground_verification = read(output / 'ramp-ground/verification.json')
    assert ground_verification['status'] == 'passed'
    assert ground_verification['sourceSha256'] == digest(regional_source_path)
    assert all(r['assetSha256'] == asset_hashes[r['side']] for r in ground_verification['rows'])
    boundary_export = read(output / 'boundaries/export-summary.json')
    boundary_selection = read(output / 'boundaries/source-selection.json')
    assert boundary_selection['sourceDomainsSha256'] == digest(regional_source_path)
    assert boundary_export['conesSha256'] == digest(output / 'boundaries/cones.jsonl')
    assert boundary_export['casesSha256'] == digest(output / 'boundaries/cases.json')
    assert all(boundary_export['assetSha256'][f'assets/maps/icebox_svg_height_{s}.json.gz'] == h for s, h in asset_hashes.items())
    boundary = read(output / 'boundaries/boundary-audit.json')
    assert boundary['cones'] == boundary_export['emitted']
    assert boundary['conesSha256'] == boundary_export['conesSha256']
    assert boundary_export['nativeSha256'] == digest(Path('build/windows/x64/runner/Profile/icarus_height.dll'))
    skipped_accounted = all(r['reason'] == 'source-eye-inside-active-svg-wall' and r['wallIds']
                            for r in boundary_export['skippedCases'])
    checks_passed = (all(r['status'] == 'passed' for r in domains + runtime + regional_runtime)
        and app['status'] == regional_comparison['status'] == walls['status'] == 'passed'
        and boundary['flaggedCones'] == 0 and skipped_accounted)
    complete = source_accounting['complete'] and checks_passed
    result = dict(status='passed' if complete else 'incomplete', sourceAccounting=source_accounting,
        scope='Icebox attack SVG [270,140,345,225], both artwork sides, standing player, measured source domains and declared sampled paths and sightlines.',
        assetSha256=asset_hashes, sourceFixtureSha256=digest(fixture_path),
        domainCoverage=domains, runtime=runtime,
        regionalFloorDomainChecks=regional_comparison['domainChecks'], regionalRuntime=regional_runtime,
        regionalWallChecks=len(walls['rows']), rampPaths=len(regional_fixture['rampPaths']),
        rampJoins=len(regional_fixture['rampJoins']), boundary=boundary,
        rampGroundVerification=ground_verification,
        boundaryExcludedOrigins=boundary_export['skippedCases'],
        app=dict(status=app['status'], checks=len(app['records']), scope=app['surface']),
        verifierNegativeControls=dict(missingSourceRecord='detected', unresolvedSourceRecords='prevent-completion'),
        limitations=['Wall heights retain reviewed source stations and gameplay associations; they are not a continuous proof at every facade point.',
                     'Default selection is exercised at the reported poses and ordinary ramp joins; whole-domain coverage establishes availability of each level.',
                     'No new live-game observation, crouching, dynamic state, other-region, or other-map acceptance is claimed.'])
    (output / 'acceptance.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(status=result['status'], unresolvedSourceRecords=len(source_accounting['unresolved']),
        domains=domains, runtime=runtime, appChecks=len(app['records']), negativeControls=result['verifierNegativeControls']), indent=2))
    return 0 if complete else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path('E:/IcarusWorldAudit/2026-09-06'))
    parser.add_argument('--output', type=Path, default=Path('work/icebox-acceptance'))
    parser.add_argument('--fixture', type=Path, default=Path('test/fixtures/icebox_vision_acceptance.json'))
    args = parser.parse_args()
    raise SystemExit(verify(args.source_root, args.output, args.fixture))
