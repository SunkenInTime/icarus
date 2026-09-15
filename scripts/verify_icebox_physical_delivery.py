"""Bind source accounting, measured floors, app selection and native contacts."""
import argparse
from collections import Counter
import copy
import json
from pathlib import Path
import numpy as np
import shapely
from shapely.affinity import affine_transform

from compile_icebox_ramp_ground import sha
from audit_all_map_gameplay_levels import ROOT, read
from verify_icebox_acceptance import accounting


def collider_inventory(source_dir, inventory):
    """Physical instance transforms cannot move an unmeasured floor into scope."""
    collider_path = source_dir/'source-colliders.json'
    region = shapely.from_geojson(json.dumps(inventory['sourceRegion'])).buffer(.42)
    required = {row['sourceObject']: row for row in inventory['inventory']}
    actual = {row['sourceObject'] for row in read(collider_path)
        if 'sourceObject' in row and region.intersects(shapely.box(*row['bounds'][0][:2], *row['bounds'][1][:2]))}
    assert actual <= required.keys(), sorted(actual-required.keys())
    map_name = inventory.get('map', 'icebox')
    review_sha = inventory['source'].get('playableSpaceReviewSha256')
    review_path = Path(f'scripts/data/{map_name}-playable-space-review.json')
    if review_sha:
        assert sha(review_path) == review_sha
    decisions = {row['sourceObject']: row for row in read(review_path)['decisions']} if review_sha else {}
    excluded = []
    for oid in sorted(actual):
        row = required[oid]
        if row['status'] == 'excluded':
            assert oid in decisions, (oid, 'A decoded influencing collider needs its explicit inventory exclusion.')
            decision = decisions[oid]
            assert decision['status'] == 'excluded' and decision['sourcePath'] == row['path']
            assert decision['reason'] == row['reason']
            excluded.append(oid)
        else:
            assert row['status'] == 'unresolved'
    return dict(status='passed', physicalMeshInstances=len(actual), reviewedExclusions=excluded,
        colliderSha256=sha(collider_path), gameplayReviewSha256=review_sha, missing=[])


def source_exclusion_records(source_dir, source):
    """Replay the approved face exclusion against the frozen preceding source."""
    if not source.get('sourceExclusionsApplicationSha256'):
        return []
    from apply_standing_domain_exclusions import exclude_domains
    application_path = source_dir/'source-exclusions-application.json'
    application = read(application_path)
    assert sha(application_path) == source['sourceExclusionsApplicationSha256']
    before_path = source_dir/'before-source-exclusions.json'
    review_path = source_dir/'playable-space-review.json'
    assert sha(before_path) == application['inputSourceSha256']
    assert sha(review_path) == application['reviewSha256']
    assert sha(source_dir/'apply_standing_domain_exclusions.py') == application['algorithmSha256']
    for name, expected in application.get('algorithmDependenciesSha256', {}).items():
        assert sha(source_dir/'exclusion-algorithms'/name) == expected
        assert sha(Path('scripts')/name) == expected
    review = read(review_path)
    before = read(before_path)
    assert {k: v for k, v in source.items() if k not in ['domains', 'sourceExclusionsApplicationSha256']} == {
        k: v for k, v in before.items() if k != 'domains'}
    for name, key in [('source-colliders.json', 'sourceCollidersSha256'),
                      ('source-colliders.npz', 'sourceColliderTrianglesSha256')]:
        assert sha(source_dir/name) == review[key] == application['collisionInputsUnchanged'][name]
    with np.load(source_dir/'source-colliders.npz') as triangles:
        domains, removed = exclude_domains(before, read(source_dir/'source-colliders.json'), triangles, review)
    assert domains == source['domains'] and removed == application['excludedDomains']
    return [r['domain'] for r in removed if 'retainedDomain' not in r]


def source_accounting(inventory, source, comparison, approved_exclusions=()):
    dispositions = copy.deepcopy(inventory['inventory'])
    mesh_rows = [r for r in source['sourceRows'] if 'sourceObject' in r]
    measured = {r['sourceObject']: r for r in mesh_rows}
    required_meshes = {r['sourceObject'] for r in inventory['inventory'] if r['status'] == 'unresolved'}
    measurements_complete = len(measured) == len(mesh_rows) and set(measured) == required_meshes
    domain_checks = {(r['id'], r['side']): r for r in comparison['rows']}
    reviewed = bool(source.get('gameplayReviewApplicationSha256') or source.get('sourceExclusionsApplicationSha256'))

    def representation(domains, measurement, excluded_count=0):
        if not domains:
            if measurement and measurement['status'] == 'standing-domains-measured' and (
                    not excluded_count or excluded_count != measurement.get('domains')):
                return 'unresolved', 'Measured standing domains are missing from the source output.'
            return 'excluded', ('Recorded gameplay review excludes the measured standing domains.'
                if measurement and measurement['status'] == 'standing-domains-measured' else
                'No eligible standing domain in the declared region.')
        required = {(d['id'], side) for d in domains for side in ['attack', 'defense']}
        if not required <= domain_checks.keys():
            return 'unresolved', 'Required source domains have no runtime comparison.'
        checks = [domain_checks[key] for key in required]
        if not all(r['status'] == r['defaultStatus'] == 'passed' for r in checks):
            return 'unresolved', 'A source level or default comparison failed.'
        if any(r['applicableAreaSvg'] > 0 for r in checks):
            return 'represented', 'Measured or reviewed local standing domains are represented.'
        return 'excluded', 'Standing domains lie outside applicable SVG floor and eye clearance.'

    for record in dispositions:
        item = measured.get(record['sourceObject'])
        domains = [d for d in source['domains'] if d.get('sourceObject') == record['sourceObject']]
        resolved = item and item['status'] in ['no-clear-standing-domain', 'standing-domains-measured']
        record['physicalCollisionDecision'] = dict(status='resolved' if resolved else record['status'],
            inventoryStatus=record['status'], reason=record['reason'], measurement=item)
        if record['status'] == 'unresolved' and (not item or item['status'] not in
                ['no-clear-standing-domain', 'standing-domains-measured']):
            continue
        excluded_count = sum(d.get('sourceObject') == record['sourceObject'] for d in approved_exclusions)
        status, reason = representation(domains, item, excluded_count)
        if record['status'] == 'excluded' and domains and (not reviewed or
                any(not d.get('eligibilityBasis') for d in domains)):
            status, reason = 'unresolved', 'A collision-excluded object needs an explicit local gameplay review.'
        if record['status'] != 'excluded' or domains:
            record.update(status=status, reason=reason)
        record['gameplayStandingDecision'] = dict(status=status, reason=reason, sourceDomains=[d['id'] for d in domains],
            gameplayReviewApplicationSha256=source.get('gameplayReviewApplicationSha256'),
            sourceExclusionsApplicationSha256=source.get('sourceExclusionsApplicationSha256'))
        if item:
            record['measurement'] = item
    result = accounting(inventory['requiredSourceObjects'], dispositions)
    result['complete'] &= measurements_complete
    result['complete'] &= len(domain_checks) == len(comparison['rows'])
    result['meshMeasurements'] = dict(required=len(required_meshes), measured=len(mesh_rows), complete=measurements_complete)
    expected_bodies = {r['collision'] for r in inventory['collisionBodies']}
    bodies = [r for r in source['sourceRows'] if 'sourceCollision' in r]
    actual_bodies = [r['sourceCollision'] for r in bodies]
    result['collisionBodies'] = dict(required=len(expected_bodies), measured=len(actual_bodies),
        missing=sorted(expected_bodies-set(actual_bodies)), unexpected=sorted(set(actual_bodies)-expected_bodies))
    result['complete'] &= (set(actual_bodies) == expected_bodies and len(actual_bodies) == len(expected_bodies)
        and all(r['status'] in ['standing-domains-measured', 'no-clear-standing-domain'] for r in bodies))
    body_decisions = []
    for body in bodies:
        domains = [d for d in source['domains'] if d.get('sourceCollision') == body['sourceCollision']]
        excluded_count = sum(d.get('sourceCollision') == body['sourceCollision'] for d in approved_exclusions)
        status, reason = representation(domains, body, excluded_count)
        body_decisions.append(dict(sourceCollision=body['sourceCollision'], physicalMeasurement=body,
            standingStatus=status, standingReason=reason, sourceDomains=[d['id'] for d in domains]))
    result['collisionBodyDecisions'] = body_decisions
    result['complete'] &= all(r['standingStatus'] != 'unresolved' for r in body_decisions)
    result['unresolvedInfluencingCollision'] = source['unresolvedInfluencingCollision']
    result['complete'] &= not result['unresolvedInfluencingCollision']
    result['dispositions'] = dict(Counter(r['status'] for r in dispositions))
    return result, dispositions


def verify(source_dir, candidate_dir, fixture_path, boundaries, walls_path, whole_scene=None,
        regional_source=None, app_fixture=None):
    inventory_path = source_dir/'source-inventory.json'
    source_path = source_dir/'regional-floors.json'
    inventory, source, fixture = map(read, [inventory_path, source_path, fixture_path])
    map_name = inventory.get('map', 'icebox')
    assert fixture.get('map', 'icebox') == map_name
    assert source['sourceInventorySha256'] == sha(inventory_path)
    assert fixture['sourceSha256'] == sha(source_path)
    consistency_sha = None
    if regional_source is not None:
        consistency_path = source_dir/'regional-source-consistency.json'
        consistency = read(consistency_path)
        assert consistency['status'] == 'passed'
        assert consistency['wholeSourceSha256'] == sha(source_path)
        assert consistency['regionalSourceSha256'] == sha(regional_source/'regional-floors.json')
        assert consistency['regionalInventorySha256'] == sha(regional_source/'source-inventory.json')
        assert consistency['algorithmSha256'] == sha(Path('scripts/compare_icebox_source_regions.py'))
        assert consistency['checks'] == len(consistency['rows']) > 0
        assert all(r['status'] == 'passed' for r in consistency['rows'])
        consistency_sha = sha(consistency_path)
    for name, expected in source.get('measurementInputsSha256', {}).items():
        path = source_dir/'algorithm-sources'/name if name.endswith('.py') else source_dir/name
        assert sha(path) == expected, path
    collider_coverage = collider_inventory(source_dir, inventory)
    collision_accounting = read(source_dir/'collision-accounting.json')
    assert not collision_accounting['unresolved']
    capsule_verification_sha = None
    if collision_accounting.get('outsideRegionCollision') or collision_accounting.get('redundantCollision'):
        capsule_path = source_dir/'capsule-exclusion-verification.json'
        capsule_verification = read(capsule_path)
        assert capsule_verification['status'] == 'passed'
        assert capsule_verification['algorithmSha256'] == sha(Path('scripts/verify_regional_capsule_exclusions.py'))
        for name in ['source-inventory.json', 'collision-accounting.json', 'source-colliders.json', 'source-colliders.npz']:
            assert capsule_verification['inputsSha256'][name] == sha(source_dir/name)
        capsule_verification_sha = sha(capsule_path)
    influence_sha = None
    if not collision_accounting.get('allSceneColliders'):
        assert whole_scene is not None, 'A regional audit requires the whole-scene influence proof.'
        influence_path = source_dir/'whole-scene-influence-verification.json'
        influence = read(influence_path)
        assert influence['status'] == 'passed'
        for key, path in {
            'wholeSceneCollidersSha256': whole_scene/'source-colliders.json',
            'wholeSceneMeshesSha256': whole_scene/'source-colliders.npz',
            'regionalCollidersSha256': source_dir/'source-colliders.json',
            'regionalMeshesSha256': source_dir/'source-colliders.npz',
            'wholeSceneAccountingSha256': whole_scene/'collision-accounting.json',
            'sourceInventorySha256': inventory_path,
        }.items():
            assert influence[key] == sha(path), key
        influence_sha = sha(influence_path)
    comparison = read(candidate_dir/'regional-floor-comparison.json')
    assert comparison['sourceSha256'] == sha(source_path) and comparison['status'] == 'passed'
    expected_domains = {(d['id'], side) for d in source['domains'] for side in ['attack', 'defense']}
    assert expected_domains == {(r['id'], r['side']) for r in comparison['rows']}
    assert len(expected_domains) == len(comparison['rows'])
    assert all(r['status'] == r['defaultStatus'] == 'passed' for r in comparison['rows'])
    source_result, dispositions = source_accounting(inventory, source, comparison, source_exclusion_records(source_dir, source))
    assert source_result['complete'], source_result
    removed = dispositions[:-1]
    assert not accounting(inventory['requiredSourceObjects'], removed)['complete']
    unresolved = copy.deepcopy(dispositions)
    unresolved[0]['status'] = 'unresolved'
    assert not accounting(inventory['requiredSourceObjects'], unresolved)['complete']
    review_path = candidate_dir/'source-review.json'
    review = read(review_path)
    assert review['sourceSha256'] == sha(source_path)
    preservation = read(candidate_dir/'preservation-verification.json')
    assert preservation['passed'] and preservation['sourceReviewSha256'] == sha(review_path)
    app_path = candidate_dir/'app/verification.json'
    app = read(app_path)
    assert app['status'] == 'passed' and app['regionalFixtureSha256'] == sha(fixture_path)
    assert app.get('map', 'icebox') == map_name
    if app_fixture:
        assert app['sourceFixtureSha256'] == sha(app_fixture)
        assert read(app_fixture)['sourceSha256'] == sha(source_path)
    floor_faults = None
    if app_fixture:
        fault_dir = candidate_dir/'fault-controls'
        fault_path = fault_dir/'verification.json'
        floor_faults = read(fault_path)
        assert floor_faults['status'] == 'passed'
        assert floor_faults['sourceSha256'] == sha(source_path)
        assert floor_faults['fixtureSha256'] == sha(app_fixture)
        assert floor_faults['expectedSourceSha256'] == sha(fault_dir/'expected-source.json')
        assert floor_faults['algorithmSha256'] == sha(Path('scripts/verify_physical_floor_fault_controls.py'))
        assert floor_faults['verifierSha256'] == sha(Path('scripts/verify_icebox_regional_floors.py'))
        assert {(r['side'], r['fault']) for r in floor_faults['records']} == {
            (side, fault) for side in ['attack', 'defense']
            for fault in ['removed-required-floor', 'incorrect-local-height']}
        assert len(floor_faults['records']) == 4
        for record in floor_faults['records']:
            assert record['status'] == 'detected' and record['failures']
            assert record['candidateSha256'] == sha(candidate_dir/f"candidate-{record['side']}.json.gz")
            assert record['faultSha256'] == sha(fault_dir/f"{record['side']}-{record['fault']}.json.gz")
    for path, expected in app['implementationHashes'].items():
        assert sha(Path(path)) == expected, path
    walls = read(walls_path)
    assert walls['status'] == 'passed'
    alignment_path = ROOT/f'tactical-alignment-sides-v1/{map_name}.json'
    assert inventory['source']['alignmentSha256'] == sha(alignment_path)
    matrix = np.asarray(read(alignment_path)['nativeToAttackSvg'])
    required_region = affine_transform(shapely.from_geojson(json.dumps(inventory['sourceRegion'])),
        [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]])
    wall_region = shapely.from_geojson(json.dumps(walls['regionSvg']))
    assert required_region.difference(wall_region.buffer(1e-8)).area < 1e-8
    selection = read(boundaries/'source-selection.json')
    exported = read(boundaries/'export-summary.json')
    contact = read(boundaries/'boundary-audit.json')
    assert selection['sourceDomainsSha256'] == sha(source_path)
    assert selection['regionalFixtureSha256'] == sha(fixture_path)
    assert exported['casesSha256'] == sha(boundaries/'cases.json')
    assert exported['conesSha256'] == contact['conesSha256'] == sha(boundaries/'cones.jsonl')
    assert exported['emitted'] == contact['cones'] and contact['flaggedCones'] == 0
    if 'assetSha256' in contact:
        assert contact['assetSha256'] == exported['assetSha256']
    if 'reuseVerificationSha256' in contact:
        reuse_path = boundaries/'contact-reuse-verification.json'
        reuse = read(reuse_path)
        assert contact['reuseVerificationSha256'] == sha(reuse_path)
        assert reuse['status'] == 'passed'
        assert reuse['currentExportSha256'] == sha(boundaries/'export-summary.json')
        assert reuse['conesSha256'] == exported['conesSha256']
        assert {r['side'] for r in reuse['records']} == {'attack', 'defense'}
        for record in reuse['records']:
            assert record['candidateSha256'] == sha(candidate_dir/f"candidate-{record['side']}.json.gz")
            assert record['wallRecordsUnchanged'] and record['receiverRecordsUnchanged']
    assert exported['nativeSha256'] == sha(Path('build/windows/x64/runner/Profile/icarus_height.dll'))
    assert all(r['reason'] in ['source-eye-inside-active-svg-wall', 'outside-svg-floor-or-ground-domain']
        and (r['reason'] != 'source-eye-inside-active-svg-wall' or r['wallIds']) for r in exported['skippedCases'])
    runtime = []
    asset_hashes = {}
    for side in ['attack', 'defense']:
        asset_name = f'assets/maps/{map_name}_svg_height_{side}.json.gz'
        actual = sha(Path(asset_name))
        asset_hashes[side] = actual
        assert actual == sha(candidate_dir/f'candidate-{side}.json.gz') == comparison['assetSha256'][side]
        assert actual == app['assetHashes'][asset_name] == exported['assetSha256'][asset_name]
        assert actual == next(r['candidateSha256'] for r in preservation['records'] if r['side'] == side)
        assert actual == next(r['assetSha256'] for r in walls['delivery'] if r['side'] == side)
        assert actual == sha(Path('build/windows/x64/runner/Profile/data/flutter_assets')/asset_name)
        for kind in ['runtime', 'saved-levels']:
            check = read(candidate_dir/f'regional-{kind}-{side}.json')
            assert check['status'] == 'passed'
            assert check['assetSha256'] == actual and check['sourceFixtureSha256'] == sha(fixture_path)
            runtime.append(dict(side=side, kind=kind, counts=dict(Counter(r['status'] for r in check['rows']))))
    result = dict(status='passed', map=map_name, sourceAccounting=source_result, sourceRegionNative=inventory['sourceRegion'],
        assetSha256=asset_hashes, sourceSha256=sha(source_path), fixtureSha256=sha(fixture_path),
        groundSourceReviewSha256=sha(review_path), preservationSha256=sha(candidate_dir/'preservation-verification.json'),
        colliderInfluenceProofSha256=influence_sha,
        capsuleExclusionVerificationSha256=capsule_verification_sha,
        colliderInventory=collider_coverage,
        wholeDomainChecks=len(comparison['rows']), runtime=runtime,
        app=dict(checks=len(app['records']), verificationSha256=sha(app_path), surface=app['surface']),
        wallAssociations=dict(checks=len(walls['rows']), verificationSha256=sha(walls_path)),
        regionalSourceConsistencySha256=consistency_sha,
        nativeContacts={k: v for k, v in contact.items() if k != 'cases'},
        excludedNativeOrigins=exported['skippedCases'],
        negativeControls=dict(missingSourceRecord='detected', unresolvedSourceRecord='detected'),
        floorFaultControlsSha256=sha(candidate_dir/'fault-controls/verification.json') if floor_faults else None,
        tolerances=dict(heightMeters=comparison['heightToleranceMeters'], boundarySvg=comparison['boundaryToleranceSvg'],
            sourceLevelEquivalenceMeters=review['matchingHeightToleranceMeters']),
        limitations=[*source['limitations'],
            'Wall height associations retain the recorded local source stations and gameplay decisions; no continuous facade proof is claimed.',
            'Standing eyes use the documented selected-surface plus 1.75 m approximation, without additional rounded capsule lift or native camera adjustments.',
            'Production provider, placed-agent widgets and painter run under Flutter test with Windows bundle assets. Native contacts use the compiled desktop library.',
            'No new live-game observation, crouching or dynamic-map-state certification.'])
    (candidate_dir/'source-dispositions.json').write_text(json.dumps(dispositions, indent=2)+'\n')
    (candidate_dir/'acceptance.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('excludedNativeOrigins', 'sourceRegionNative')}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--candidate-dir', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--boundaries', type=Path, required=True)
    parser.add_argument('--walls', type=Path, required=True)
    parser.add_argument('--whole-scene', type=Path)
    parser.add_argument('--regional-source', type=Path,
        help='Bind the overlap comparison with an independently measured smaller region.')
    parser.add_argument('--app-fixture', type=Path,
        help='Verify the separately frozen app placement expectations against the same source.')
    args = parser.parse_args()
    verify(args.source, args.candidate_dir, args.fixture, args.boundaries, args.walls,
        args.whole_scene, args.regional_source, args.app_fixture)
