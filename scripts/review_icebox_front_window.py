"""Apply the measured Nest front aperture and its exact lower destination floor.

Writes candidates only. Existing wall IDs, footprints, upper bands, ground,
and supports remain intact; the new floor is clipped by receiver/applicability.
"""
import argparse
import copy
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from compile_reviewed_svg_height_map import polygon, rings
from review_reported_wall_assemblies import read, sha
from review_icebox_gameplay_openings import vertical_intervals
from source_geometry_projection import project_source
from verify_icebox_regional_floors import applicable_domain, area_shape, svg_plane

REVIEW = Path('scripts/data/icebox-nest-front-window-2026-09-14.json')


def build(review_path, output, input_dir=None):
    review = read(review_path)
    paths = {k: Path(v['path']) for k, v in review['sources'].items()}
    for key, path in paths.items():
        assert sha(path) == review['sources'][key]['sha256'], key
    objects = read(paths['metadata'])['objects']
    geometry = np.load(paths['geometry'])
    ids = np.concatenate([np.arange(objects[i]['firstFace'], objects[i]['firstFace'] + objects[i]['faceCount']) for i in review['sourceObjects']])
    triangles = geometry['points'][geometry['faces'][ids]].astype(float)
    measure = lambda s: vertical_intervals(triangles, s['axis'], s['cross'], s['along'])
    measured = [measure(s) for s in review['sections']]
    eye = review['openingEyeMeters']
    sill = max(hi for section in measured for lo, hi in section if lo < eye)
    header = min(lo for section in measured for lo, hi in section if hi > eye)
    assert np.allclose([sill, header], review['expectedOpeningMeters'], atol=1e-7, rtol=0)
    jambs = [measure(s) for s in review['jambSections']]
    assert all(any(lo < eye < hi for lo, hi in bands) for bands in jambs)
    floor = objects[review['sourceFloorObject']]
    assert abs(floor['boundsMeters'][1][2] + 1.75 - eye) < .00001
    alignment = read(paths['alignment'])
    domain = next(d for d in read(paths['standing'])['domains'] if d['id'] == review['destinationDomain'])
    assert domain['nativePlane'] == [0., 0., 2.]
    native = shapely.from_geojson(json.dumps(domain['nativeGeometry']))
    results = []
    output.mkdir(parents=True, exist_ok=True)
    for side in ['attack', 'defense']:
        baseline = Path(review['baseline'][side]['path'])
        assert sha(baseline) == review['baseline'][side]['sha256']
        source = input_dir / f'candidate-{side}.json.gz' if input_dir else baseline
        before = read(source)
        model = copy.deepcopy(before)
        selected = {w['id']: w for w in review['selectedWalls'][side]}
        seen = set()
        for wall in model['walls']:
            if wall['id'] not in selected:
                continue
            assert wall['rings'] == selected[wall['id']]['rings']
            assert wall['floorElevationMeters'] == 0 and not wall['unknownHeight']
            wall['bands'] = [part for lo, hi in wall['bands']
                             for part in ([lo, min(hi, sill)], [max(lo, header), hi])
                             if part[1] > part[0]]
            seen.add(wall['id'])
        assert seen == set(selected)
        matrix = np.asarray(alignment[f'nativeTo{side.title()}Svg'])
        projected = area_shape(project_source(native, [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]]))
        receiver = shapely.union_all([polygon(r) for r in model['receiver']])
        clipped = area_shape(projected.intersection(receiver))
        plane = svg_plane(domain['nativePlane'], matrix)
        shapes = [polygon(w) for w in model['walls']]
        wall_ids = shapely.STRtree(shapes).query(clipped, predicate='intersects')
        eligible = area_shape(applicable_domain(clipped, plane, [model['walls'][i] for i in wall_ids], [shapes[i] for i in wall_ids]))
        sid = f'icebox-measured-{domain["id"]}'
        assert not any(s['id'] == sid for s in model['supports'])
        support = dict(id=sid, label='Platform', fillRule='evenodd', floorElevationMeters=0.,
                       heightAboveFloorMeters=2., surfaceElevationMeters=2., surfacePlane=plane.tolist(),
                       automaticStandingAllowed=True,
                       rings=[ring for part in shapely.get_parts(eligible) if part.geom_type == 'Polygon' for ring in rings(part)])
        model['supports'].append(support)
        model['sightlineFloorSupportIds'] = [*model.get('sightlineFloorSupportIds', []), sid]
        model['sourceIceboxFrontWindowReviewSha256'] = sha(review_path)
        # Reconstruct the baseline to prove exact preservation outside this review.
        check = copy.deepcopy(model)
        check['walls'] = copy.deepcopy(before['walls'])
        check['supports'].pop()
        if 'sightlineFloorSupportIds' in before:
            check['sightlineFloorSupportIds'] = before['sightlineFloorSupportIds']
        else:
            del check['sightlineFloorSupportIds']
        del check['sourceIceboxFrontWindowReviewSha256']
        assert check == before
        for old, new in zip(before['walls'], model['walls']):
            assert {k: v for k, v in old.items() if k != 'bands'} == {k: v for k, v in new.items() if k != 'bands'}
            if old['id'] not in selected:
                assert old == new
        target = output / f'candidate-{side}.json.gz'
        target.write_bytes(gzip.compress(json.dumps(model, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
        results.append(dict(side=side, inputPath=str(source), inputSha256=sha(source), outputSha256=sha(target),
                            destinationSupportId=sid, projectedArea=projected.area, receiverArea=clipped.area,
                            applicableArea=eligible.area, selectedWallIds=sorted(selected)))
    report = dict(reviewSha256=sha(review_path), compilerSha256=sha(Path(__file__)),
                  sourceFaces=ids.tolist(), measuredSections=measured, jambSections=jambs,
                  openingMeters=[sill, header], destinationSourceDomain=domain, results=results)
    (output / 'front-window-review.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(results))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--review', type=Path, default=REVIEW)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--input-dir', type=Path, help='Compose onto candidate-{side} files; selected walls must match pinned footprints.')
    args = parser.parse_args()
    build(args.review, args.output, args.input_dir)
