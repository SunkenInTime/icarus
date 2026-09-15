"""Independently check Nest window preservation and complete destination coverage."""
import argparse
import copy
import json
from pathlib import Path
import numpy as np
import shapely
from compile_reviewed_svg_height_map import polygon
from review_reported_wall_assemblies import read, sha
from source_geometry_projection import project_source
from verify_wall_change_floor_delta import crop_model
from verify_icebox_regional_floors import compare


def verify(review_path, candidate):
    review = read(review_path)
    for record in review['sources'].values():
        assert sha(Path(record['path'])) == record['sha256'], record['path']
    source = read(Path(review['sources']['standing']['path']))
    alignment = read(Path(review['sources']['alignment']['path']))
    domain = next(d for d in source['domains'] if d['id'] == review['destinationDomain'])
    native = shapely.from_geojson(json.dumps(domain['nativeGeometry']))
    results = []
    for side in ['attack', 'defense']:
        assert sha(Path(review['baseline'][side]['path'])) == review['baseline'][side]['sha256']
        before = read(Path(review['baseline'][side]['path']))
        path = candidate / f'candidate-{side}.json.gz'
        after = read(path)
        assert len(after['walls']) == len(before['walls'])
        selected = {w['id'] for w in review['selectedWalls'][side]}
        sill, header = review['expectedOpeningMeters']
        for old, new in zip(before['walls'], after['walls']):
            expected = copy.deepcopy(old)
            if old['id'] in selected:
                expected['bands'] = [p for lo, hi in old['bands'] for p in ([lo, min(hi, sill)], [max(lo, header), hi]) if p[1] > p[0]]
            assert expected == new, old['id']
        assert after['supports'][:-1] == before['supports']
        added = after['supports'][-1]
        assert added['id'] == 'icebox-measured-volume-129-0' and added['surfacePlane'] == [0., 0., 2.]
        assert after['ground'] == before['ground']
        assert after['receiver'] == before['receiver']
        assert after['sightlineFloorSupportIds'] == [
            *before.get('sightlineFloorSupportIds', []), added['id']]
        assert after['sourceIceboxFrontWindowReviewSha256'] == sha(review_path)
        changed = {'walls', 'supports', 'sightlineFloorSupportIds',
                   'sourceIceboxFrontWindowReviewSha256'}
        assert {k: v for k, v in after.items() if k not in changed} == {
            k: v for k, v in before.items() if k not in changed}
        matrix = np.asarray(alignment[f'nativeTo{side.title()}Svg'])
        projected = project_source(native, [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]])
        assert polygon(added).difference(projected.buffer(.000001)).area < .000001
        changed_walls = shapely.union_all([
            polygon(w) for w in after['walls'] if w['id'] in selected])
        # Opening a wall can expose standing area beyond the lower destination.
        # Recheck every complete source domain intersecting either changed area.
        region = projected.union(changed_walls).buffer(.002)
        local, _ = crop_model(after, region)
        rows = compare(source, local, matrix, side)
        active = [r for r in rows if r['withinReceiverAreaSvg'] > 1e-12]
        failures = [r for r in active if r['status'] != 'passed' or r['defaultStatus'] != 'passed']
        results.append(dict(side=side, candidateSha256=sha(path), localDomainChecks=len(active), failures=failures, rows=active))
        print(json.dumps(dict(side=side, localDomainChecks=len(active), failures=failures)), flush=True)
    report = dict(reviewSha256=sha(review_path), algorithmSha256=sha(Path(__file__)), results=results)
    (candidate / 'destination-floor-comparison.json').write_text(json.dumps(report, indent=2) + '\n')
    assert not any(r['failures'] for r in results)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--review', type=Path, default=Path('scripts/data/icebox-nest-front-window-2026-09-14.json'))
    parser.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    verify(args.review, args.candidate)
