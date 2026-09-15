"""Stage source-measured corrections for the September 12 screenshot review."""
import copy
import argparse
import gzip
import hashlib
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

sys.path.insert(0, 'scripts')
from compile_reviewed_svg_height_map import polygon, rings
from review_icebox_gameplay_openings import vertical_intervals, clip_triangle
from verify_icebox_regional_floors import applicable_domain, svg_plane, area_shape
from source_geometry_projection import project_source

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT / 'tactical-visibility-revision'
OUT = Path('work/reported-sightlines-candidate-v1')
BASELINE = OUT
REVIEW = Path('scripts/data/reported-sightlines-2026-09-12.json')


def read(path):
    raw = path.read_bytes()
    return json.loads(gzip.decompress(raw) if path.suffix == '.gz' else raw)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    OUT.mkdir(exist_ok=True)
    review = read(REVIEW)
    for name, decision in review['maps'].items():
        excluded = decision['excludedSupportIds']
        standing_path = Path(decision['standingSource'])
        assert digest(standing_path) == decision['standingSourceSha256']
        footprints = {side: read(REV / f'all-map-svg-footprints-v1/{name}-{side}.json')
                      for side in ['attack', 'defense']}
        alignment_path = ROOT / f'tactical-alignment-sides-v1/{name}.json'
        alignment = read(alignment_path)
        matrices = {side: np.array(alignment[f'nativeTo{side.title()}Svg'])
                    for side in ['attack', 'defense']}
        linear = matrices['defense'][:, :2] @ np.linalg.inv(matrices['attack'][:, :2])
        offset = matrices['defense'][:, 2] - linear @ matrices['attack'][:, 2]
        transform = [*linear[0], *linear[1], *offset]
        metadata_path = ROOT / f'supplemented-v2/world/{name}/geometry.json'
        geometry_path = metadata_path.with_suffix('.npz')
        objects = read(metadata_path)['objects']
        archive = np.load(geometry_path)
        points, faces = archive['points'], archive['faces']
        specs = decision['openingWalls']
        corrections = []
        for spec in specs:
            original = next(w for w in footprints['attack']['walls'] if w['id'] == spec['wall'])
            domain = polygon(original)
            source = np.concatenate([
                points[faces[objects[i]['firstFace']:objects[i]['firstFace'] + objects[i]['faceCount']]]
                for i in spec['objects']]).astype(float)
            face_ids = np.concatenate([np.arange(objects[i]['firstFace'],
                objects[i]['firstFace'] + objects[i]['faceCount']) for i in spec['objects']])
            source[:, :, :2] = source[:, :, :2] @ matrices['attack'][:, :2].T + matrices['attack'][:, 2]
            parts = []
            for section in spec.get('sections', [spec]):
                section_domain = domain.intersection(shapely.box(*section['clipBox'])) if 'clipBox' in section else domain
                assert not section_domain.is_empty
                along_axis = 1 - section['axis']
                start, end = section_domain.bounds[along_axis], section_domain.bounds[along_axis + 2]
                count = int(np.ceil((end - start) / .5))
                for index in range(count):
                    lo, hi = start + (end - start) * index / count, start + (end - start) * (index + 1) / count
                    measured = vertical_intervals(source, section['axis'], section['cross'], [lo, hi])
                    bounds = [(section['axis'], *section['cross']), (along_axis, lo, hi)]
                    selected = np.ones(len(source), dtype=bool)
                    for dimension, low, high in bounds:
                        selected &= (source[:, :, dimension].max(1) >= low) & (source[:, :, dimension].min(1) <= high)
                    local_faces = []
                    for face, triangle in zip(face_ids[selected], source[selected]):
                        clipped = clip_triangle(triangle, bounds)
                        if len(clipped) >= 3 and np.ptp(clipped[:, 2]) > 1e-7:
                            local_faces.append(int(face))
                    bands = measured
                    if spec['mode'] == 'window-frame':
                        # Cosmetic cracks above the doorway do not become extra
                        # gameplay openings. Preserve the distinct sill and header.
                        opening_eye = spec['openingEyeElevationMeters']
                        lower = [b for b in measured if b[0] < opening_eye]
                        upper = [b for b in measured if b[1] >= opening_eye]
                        assert lower and upper
                        sill = max(b[1] for b in lower)
                        header = min(b[0] for b in upper)
                        top = max(b[1] for b in measured)
                        bands = [[0., top]] if sill >= header else [[0., sill], [header, top]]
                    clip_lo = -1000 if index == 0 else lo
                    clip_hi = 1000 if index == count - 1 else hi
                    clip = [clip_lo, -1000, clip_hi, 1000] if along_axis == 0 else [-1000, clip_lo, 1000, clip_hi]
                    if 'clipBox' in section:
                        region = section['clipBox']
                        clip = [max(clip[0], region[0]), max(clip[1], region[1]), min(clip[2], region[2]), min(clip[3], region[3])]
                    parts.append(dict(id=f'user-section-{len(parts)}', clipBox=clip,
                                      measuredBands=measured, sourceFaces=local_faces, bands=bands))
            measured_parts = parts
            if 'gameplayParts' in spec:
                parts = spec['gameplayParts']
            corrections.append(dict(**spec, parts=parts, measuredParts=measured_parts,
                sourceObjects=[dict(index=i, path=objects[i]['path'], firstFace=objects[i]['firstFace'],
                                    faceCount=objects[i]['faceCount']) for i in spec['objects']]))
        source = read(standing_path)
        by_id = {row['id']: row for row in source['domains']}
        excluded_domains = decision['excludedStandingDomains']
        for excluded_domain in excluded_domains:
            actual = by_id[excluded_domain['id']]
            assert all(actual[key] == value for key, value in excluded_domain.items())
        excluded_ids = {row['id'] for row in excluded_domains}
        retained_source = dict(source,
            domains=[row for row in source['domains'] if row['id'] not in excluded_ids],
            sourceSightlineReviewSha256=digest(REVIEW),
            standingSourceBeforeSha256=digest(standing_path),
            excludedStandingDomainIds=sorted(excluded_ids))
        source_output = OUT / name / 'source'
        source_output.mkdir(parents=True, exist_ok=True)
        (source_output / 'regional-floors.json').write_text(json.dumps(retained_source, indent=2) + '\n')
        shutil.copyfile(standing_path.parent / 'source-inventory.json', source_output / 'source-inventory.json')
        collision_inputs = {str(p): digest(p) for p in [standing_path.parent / 'source-colliders.json',
                                                       standing_path.parent / 'source-colliders.npz']}
        report = dict(map=name, reviewSha256=digest(REVIEW), excludedSupports=excluded, corrections=corrections,
                      algorithmSha256=digest(Path(__file__)),
                      measurementAlgorithmSha256=digest(Path(__file__).with_name('review_icebox_gameplay_openings.py')),
                      standingSourceBeforeSha256=digest(standing_path),
                      standingSourceAfterSha256=digest(source_output / 'regional-floors.json'),
                      retainedStandingDomains=len(retained_source['domains']),
                      excludedStandingDomains=excluded_domains, collisionInputsUnchanged=collision_inputs,
                      sourceSha256={str(p): digest(p) for p in [alignment_path, metadata_path, geometry_path]}, sides=[])
        for side in ['attack', 'defense']:
            asset = Path(f'assets/maps/{name}_svg_height_{side}.json.gz')
            baseline_path = BASELINE / f'{name}-{side}-before.json.gz'
            if not baseline_path.exists():
                assert digest(asset) == decision['baselineSha256'][side]
                BASELINE.mkdir(parents=True, exist_ok=True)
                baseline_path.write_bytes(asset.read_bytes())
            assert digest(baseline_path) == decision['baselineSha256'][side]
            baseline = read(baseline_path)
            model = copy.deepcopy(baseline)
            side_excluded = decision.get('excludedSupportIdsBySide', {}).get(side, excluded)
            all_excluded = set(side_excluded) | {
                f'{name}-measured-{domain_id}' for domain_id in excluded_ids}
            removed = [s['id'] for s in model['supports'] if s['id'] in all_excluded]
            assert set(side_excluded).issubset(removed)
            model['supports'] = [s for s in model['supports'] if s['id'] not in all_excluded]
            model['sourceSightlineReviewSha256'] = digest(REVIEW)
            if decision['sightlineFloorSupportIds']:
                model['sightlineFloorSupportIds'] = decision['sightlineFloorSupportIds']
            changes, changed_shapes = [], []
            for correction in corrections:
                original = next(w for w in footprints['attack']['walls'] if w['id'] == correction['wall'])
                attack_domain = polygon(original)
                if side == 'defense':
                    reflected = affine_transform(attack_domain, transform)
                    matches = sorted(footprints[side]['walls'], key=lambda w: polygon(w).hausdorff_distance(reflected))
                    original = matches[0]
                    assert polygon(original).hausdorff_distance(reflected) < .6
                domain = polygon(original)
                changed_shapes.append(domain)
                prefix = original['id']
                previous = [w for w in model['walls'] if w['id'] == prefix or w['id'].startswith(prefix + '-')]
                assert previous
                assert shapely.union_all([polygon(w) for w in previous]).symmetric_difference(domain).area < 1e-7
                model['walls'] = [w for w in model['walls'] if w not in previous]
                replacement = []
                for part in correction['parts']:
                    clip = shapely.box(*part['clipBox'])
                    if side == 'defense':
                        clip = affine_transform(clip, transform)
                    for index, shape in enumerate(shapely.get_parts(domain.intersection(clip))):
                        if shape.geom_type != 'Polygon' or shape.area < 1e-12:
                            continue
                        replacement.append(dict(id=f'{prefix}-{part["id"]}-{index}', rings=rings(shape),
                            fillRule='evenodd', floorElevationMeters=0., bands=part['bands'], unknownHeight=False))
                difference = shapely.union_all([polygon(w) for w in replacement]).symmetric_difference(domain).area
                assert difference < 1e-7, (name, side, prefix, difference)
                model['walls'].extend(replacement)
                changes.append(dict(parent=prefix, oldParts=len(previous), newParts=len(replacement), footprintDifference=difference))
            restored_floors = []
            changed_area = shapely.union_all(changed_shapes)
            receiver = shapely.union_all([polygon(r) for r in model['receiver']])
            old_walls = [polygon(w) for w in baseline['walls']]
            new_walls = [polygon(w) for w in model['walls']]
            # Reopen only source-measured standing area previously clipped by
            # these painted walls. Existing coverage outside the ink stays put.
            for item in retained_source['domains']:
                domain_id = item['id']
                native = shapely.from_geojson(json.dumps(item['nativeGeometry']))
                matrix = matrices[side]
                projected = project_source(native, [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]])
                if not projected.intersects(changed_area):
                    continue
                local = area_shape(projected.intersection(receiver).intersection(changed_area))
                plane = svg_plane(item['nativePlane'], matrix)
                old_domain = applicable_domain(local, plane, baseline['walls'], old_walls)
                new_domain = applicable_domain(local, plane, model['walls'], new_walls)
                domain = area_shape(new_domain.difference(old_domain))
                if domain.area < 1e-7:
                    continue
                support = next((s for s in model['supports'] if s['id'] == f'{name}-measured-{domain_id}'), None)
                if support is None:
                    point = domain.representative_point()
                    elevation = float(plane @ np.array([point.x, point.y, 1.]))
                    label = decision['restoredStandingLabel'] if domain_id == decision.get('restoredStandingDomain') else 'Platform'
                    support = dict(id=f'{name}-measured-{domain_id}', label=label,
                        fillRule='evenodd', floorElevationMeters=0., heightAboveFloorMeters=elevation,
                        surfaceElevationMeters=elevation, surfacePlane=plane.tolist(), automaticStandingAllowed=True)
                    model['supports'].append(support)
                    before = shapely.Polygon()
                else:
                    before = polygon(support)
                result = before.union(domain)
                support['rings'] = [ring for part in shapely.get_parts(result) if part.geom_type == 'Polygon' for ring in rings(part)]
                restored_floors.append(dict(sourceDomain=item['id'], supportId=support['id'], addedAreaSvg=result.difference(before).area))
            assert model['ground'] == baseline['ground']
            target = OUT / f'{name}-{side}.json.gz'
            target.write_bytes(gzip.compress(json.dumps(model, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
            report['sides'].append(dict(side=side, baselineSha256=digest(baseline_path), candidateSha256=digest(target),
                                       removedSupports=removed, walls=changes, restoredFloors=restored_floors))
        (OUT / f'{name}-review.json').write_text(json.dumps(report, indent=2) + '\n')
        print(name, report['sides'], flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--review', type=Path, default=REVIEW)
    parser.add_argument('--output', type=Path, default=OUT)
    parser.add_argument('--baseline-dir', type=Path, default=BASELINE)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    args = parser.parse_args()
    OUT, BASELINE, ROOT, REVIEW = args.output, args.baseline_dir, args.source_root, args.review
    REV = ROOT / 'tactical-visibility-revision'
    main()
