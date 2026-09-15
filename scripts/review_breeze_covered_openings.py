"""Measure the reported Breeze window assemblies and preserve their SVG ink."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from compile_reviewed_svg_height_map import polygon, rings
from review_icebox_gameplay_openings import vertical_intervals
from source_geometry_projection import project_source
from verify_icebox_regional_floors import applicable_domain, area_shape, svg_plane

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REVIEW = Path('scripts/data/breeze-covered-openings-2026-09-13.json')


def read(path):
    raw = path.read_bytes()
    return json.loads(gzip.decompress(raw) if path.suffix == '.gz' else raw)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def encode(shape):
    return [ring for part in shapely.get_parts(shape)
            if part.geom_type == 'Polygon' for ring in rings(part)]


def build(output):
    output.mkdir(parents=True, exist_ok=True)
    review = read(REVIEW)
    source_path = Path(review['standingSource'])
    assert sha(source_path) == review['standingSourceSha256']
    source = read(source_path)
    excluded_ids = {d['id'] for d in review['excludedStandingDomains']}
    for excluded in review['excludedStandingDomains']:
        original = next(d for d in source['domains'] if d['id'] == excluded['id'])
        assert all(original[k] == v for k, v in excluded.items())
    source['domains'] = [d for d in source['domains'] if d['id'] not in excluded_ids]
    source['coveredOpeningReviewSha256'] = sha(REVIEW)
    source_dir = output / 'source'
    source_dir.mkdir(exist_ok=True)
    (source_dir / 'regional-floors.json').write_text(json.dumps(source, indent=2) + '\n')
    (source_dir / 'source-inventory.json').write_bytes(source_path.with_name('source-inventory.json').read_bytes())
    paths = dict(alignment=ROOT / 'tactical-alignment-sides-v1/breeze.json',
                 geometry=ROOT / 'supplemented-v2/world/breeze/geometry.npz',
                 metadata=ROOT / 'supplemented-v2/world/breeze/geometry.json')
    for key, path in paths.items():
        assert sha(path) == review['sourceSha256'][key], (key, 'Source changed; review required')
    alignment = read(paths['alignment'])
    matrices = {s: np.asarray(alignment[f'nativeTo{s.title()}Svg']) for s in ['attack', 'defense']}
    attack, defense = matrices.values()
    linear = defense[:, :2] @ np.linalg.inv(attack[:, :2])
    offset = defense[:, 2] - linear @ attack[:, 2]
    reflection = [*linear[0], *linear[1], *offset]
    objects = read(paths['metadata'])['objects']
    geometry = np.load(paths['geometry'])
    footprints = {s: read(ROOT / f'tactical-visibility-revision/all-map-svg-footprints-v1/breeze-{s}.json')['walls']
                  for s in matrices}
    corrections = []
    for window in review['windows']:
        ids = np.concatenate([np.arange(objects[i]['firstFace'], objects[i]['firstFace'] + objects[i]['faceCount'])
                              for i in window['sourceObjects']])
        triangles = geometry['points'][geometry['faces'][ids]].astype(float)
        triangles[:, :, :2] = triangles[:, :, :2] @ attack[:, :2].T + attack[:, 2]
        x0, y0, x1, y1 = window['clipBox']
        edges = np.linspace(x0, x1, int(np.ceil((x1 - x0) / .25)) + 1)
        sections = []
        for lo, hi in zip(edges, edges[1:]):
            measured = vertical_intervals(triangles, 1, window['cross'], [lo, hi])
            assert measured, (window['name'], lo, hi)
            eye = window['eyeElevationMeters']
            # Keep the usable opening between its sill and header. Construction
            # seams above the header do not become additional openings.
            lower = [b for b in measured if b[0] < eye]
            upper = [b for b in measured if b[1] >= eye]
            assert lower and upper, (window['name'], lo, measured)
            sill, header, top = max(b[1] for b in lower), min(b[0] for b in upper), max(b[1] for b in measured)
            bands = [[0., top]] if sill >= header else [[0., sill], [header, top]]
            sections.append(dict(clipBox=[float(lo), y0, float(hi), y1], bands=bands, measuredBands=measured))
        corrections.append(dict(**window, sourcePaths=[objects[i]['path'] for i in window['sourceObjects']],
                                sourceFaces=ids.tolist(), sections=sections))
    for cover in review['lowCover']:
        obj = objects[cover['sourceObject']]
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        top = float(geometry['points'][geometry['faces'][ids], 2].max())
        corrections.append(dict(**cover, parents=[cover['parent']], sourcePaths=[obj['path']],
                                sourceFaces=ids.tolist(), sections=[dict(clipBox=cover['clipBox'], bands=[[0., top]])]))
    reports = []
    for side in matrices:
        baseline_path = output / f'before-{side}.json.gz'
        if not baseline_path.exists():
            asset = Path(f'assets/maps/breeze_svg_height_{side}.json.gz')
            assert sha(asset) == review['baselineSha256'][side]
            baseline_path.write_bytes(asset.read_bytes())
        assert sha(baseline_path) == review['baselineSha256'][side]
        baseline = read(baseline_path)
        model = copy.deepcopy(baseline)
        excluded_supports = set(review['excludedSupportIds']) | {
            f'breeze-measured-{domain_id}' for domain_id in excluded_ids}
        removed = [s['id'] for s in model['supports'] if s['id'] in excluded_supports]
        assert set(review['excludedSupportIds']).issubset(removed)
        model['supports'] = [s for s in model['supports'] if s['id'] not in removed]
        changed = []
        for ci, correction in enumerate(corrections):
            for parent in correction['parents']:
                original = next(w for w in footprints['attack'] if w['id'] == parent)
                if side == 'defense':
                    reflected = affine_transform(polygon(original), reflection)
                    matched = min(footprints[side], key=lambda w: polygon(w).hausdorff_distance(reflected))
                    assert polygon(matched).hausdorff_distance(reflected) < .6
                    parent = matched['id']
                for si, section in enumerate(correction['sections']):
                    clip = shapely.box(*section['clipBox'])
                    if side == 'defense':
                        clip = affine_transform(clip, reflection)
                    # Side reflection can leave a clip boundary one floating
                    # point step short of an existing numerical wall sliver.
                    # Use the source-overlay grid, not a visible geometry gap.
                    clip = shapely.set_precision(clip, 1e-8)
                    walls = []
                    for wall in model['walls']:
                        if wall['id'] != parent and not wall['id'].startswith(parent + '-'):
                            walls.append(wall)
                            continue
                        shape = polygon(wall)
                        inside = shape.intersection(clip)
                        # Even a sub-picounit sliver can retain a runtime wall
                        # edge. Reclassify every positive-area intersection.
                        if inside.area == 0:
                            walls.append(wall)
                            continue
                        changed.append(inside)
                        pieces = []
                        for label, domain in [('outside', shape.difference(clip)), ('opening', inside)]:
                            for pi, part in enumerate(shapely.get_parts(domain)):
                                if part.geom_type != 'Polygon' or part.area == 0:
                                    continue
                                record = dict(wall, id=f'{parent}-covered-{ci}-{si}-{label}-{len(walls)}', rings=rings(part), fillRule='evenodd')
                                if label == 'opening':
                                    record.update(floorElevationMeters=0., bands=section['bands'], unknownHeight=False)
                                walls.append(record)
                                pieces.append(part)
                        assert shape.symmetric_difference(shapely.union_all(pieces)).area < 1e-7
                    model['walls'] = walls
        assert changed
        changed_area = shapely.union_all(changed)
        receiver = shapely.union_all([polygon(r) for r in model['receiver']])
        old_walls = [polygon(w) for w in baseline['walls']]
        new_walls = [polygon(w) for w in model['walls']]
        restored = []
        matrix = matrices[side]
        for item in source['domains']:
            native = shapely.from_geojson(json.dumps(item['nativeGeometry']))
            projected = project_source(native, [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]])
            if not projected.intersects(changed_area):
                continue
            local = area_shape(projected.intersection(receiver).intersection(changed_area))
            plane = svg_plane(item['nativePlane'], matrix)
            before = applicable_domain(local, plane, baseline['walls'], old_walls)
            after = applicable_domain(local, plane, model['walls'], new_walls)
            added = area_shape(after.difference(before))
            if added.area < 1e-7:
                continue
            sid = f'breeze-measured-{item["id"]}'
            support = next((s for s in model['supports'] if s['id'] == sid), None)
            if support is None:
                point = added.representative_point()
                z = float(plane @ np.array([point.x, point.y, 1.]))
                support = dict(id=sid, label='Platform', fillRule='evenodd', floorElevationMeters=0.,
                               heightAboveFloorMeters=z, surfaceElevationMeters=z, surfacePlane=plane.tolist(),
                               automaticStandingAllowed=True)
                model['supports'].append(support)
                old = shapely.Polygon()
            else:
                old = polygon(support)
            support['rings'] = encode(old.union(added))
            restored.append(dict(sourceDomain=item['id'], supportId=sid, addedAreaSvg=float(added.area)))
        model['sourceCoveredOpeningReviewSha256'] = sha(REVIEW)
        assert model['ground'] == baseline['ground'] and model['receiver'] == baseline['receiver']
        target = output / f'candidate-{side}.json.gz'
        target.write_bytes(gzip.compress(json.dumps(model, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
        reports.append(dict(side=side, candidateSha256=sha(target), removedSupports=removed,
                            changedAreaSvg=float(changed_area.area), restoredStanding=restored))
    report = dict(reviewSha256=sha(REVIEW), algorithmSha256=sha(Path(__file__)),
                  measurementAlgorithmSha256=sha(Path(__file__).with_name('review_icebox_gameplay_openings.py')),
                  retainedStandingDomains=len(source['domains']), corrections=corrections, sides=reports)
    (output / 'review.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(retainedStandingDomains=len(source['domains']), sides=reports)), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    build(parser.parse_args().output)
