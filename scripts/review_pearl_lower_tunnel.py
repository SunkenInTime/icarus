"""Measure Pearl's lower tunnel across its complete unchanged painted mouth."""
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
from svg_wall_footprint_integrity import remove_collapsed_walls
from verify_icebox_regional_floors import applicable_domain, area_shape, svg_plane

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REVIEW = Path('scripts/data/pearl-lower-tunnel-review-2026-09-13.json')


def read(path):
    raw = Path(path).read_bytes()
    return json.loads(gzip.decompress(raw) if str(path).endswith('.gz') else raw)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def encode(shape):
    return [ring for part in shapely.get_parts(shape) if part.geom_type == 'Polygon'
            for ring in rings(part)]


def build(output):
    review = read(REVIEW)
    output.mkdir(parents=True, exist_ok=False)
    paths = dict(geometry=ROOT/'supplemented-v2/world/pearl/geometry.npz',
                 metadata=ROOT/'supplemented-v2/world/pearl/geometry.json',
                 alignment=ROOT/'tactical-alignment-sides-v1/pearl.json',
                 footprint=ROOT/'tactical-visibility-revision/all-map-svg-footprints-v1/pearl-attack.json',
                 defenseFootprint=ROOT/'tactical-visibility-revision/all-map-svg-footprints-v1/pearl-defense.json')
    assert all(sha(path) == review['sourceSha256'][key] for key, path in paths.items())
    source_path = Path(review['standingSource'])
    assert sha(source_path) == review['standingSourceSha256']
    source = read(source_path)
    objects = read(paths['metadata'])['objects']
    mesh = np.load(paths['geometry'])
    face_ids = np.concatenate([np.arange(objects[i]['firstFace'], objects[i]['firstFace']+objects[i]['faceCount'])
                               for i in review['sourceObjects']])
    triangles = mesh['points'][mesh['faces'][face_ids]].astype(float)
    alignment = read(paths['alignment'])
    matrices = {s: np.asarray(alignment[f'nativeTo{s.title()}Svg']) for s in ['attack', 'defense']}
    attack, defense = matrices.values()
    linear = defense[:, :2] @ np.linalg.inv(attack[:, :2])
    shift = defense[:, 2] - linear @ attack[:, 2]
    reflection = [*linear[0], *linear[1], *shift]
    parent = next(w for w in read(paths['footprint'])['walls'] if w['id'] == review['parent'])
    footprint = polygon(parent)
    reflected_footprint = affine_transform(footprint, reflection)
    defense_parent = min(read(paths['defenseFootprint'])['walls'],
                         key=lambda w: polygon(w).hausdorff_distance(reflected_footprint))
    assert polygon(defense_parent).hausdorff_distance(reflected_footprint) < .001
    side_footprints = {'attack': footprint, 'defense': polygon(defense_parent)}
    # Pearl's authored mouth runs along native X. These assertions prevent a
    # changed alignment from silently reinterpreting the section direction.
    assert abs(attack[1, 1]) < 1e-12 and attack[1, 0] < 0
    start, end = review['svgAlongRange']
    edges = np.linspace(start, end, int(np.ceil((end-start)/.25))+1)
    sections = []
    for lo, hi in zip(edges, edges[1:]):
        native_along = sorted([(v-attack[1, 2])/attack[1, 0] for v in [lo, hi]])
        measured = vertical_intervals(triangles, review['sourceCrossAxis'],
                                      review['sourceCrossRange'], native_along)
        assert measured, (lo, hi, 'Missing tunnel assembly')
        bottom, top = min(b[0] for b in measured), max(b[1] for b in measured)
        # The single functional passage is below the tunnel ceiling. Fill
        # construction seams in the structure above it, and preserve the jamb.
        bands = [[0., top]] if bottom <= review['eyeElevationMeters'] else [[bottom, top]]
        sections.append(dict(svgAlong=[float(lo), float(hi)], nativeAlong=native_along,
                             measuredBands=measured, bands=bands))
    reports = []
    for side, matrix in matrices.items():
        path = Path(f'assets/maps/pearl_svg_height_{side}.json.gz')
        assert sha(path) == review['baselineSha256'][side]
        (output/f'before-{side}.json.gz').write_bytes(path.read_bytes())
        baseline = read(path)
        model = copy.deepcopy(baseline)
        changed = []
        for index, section in enumerate(sections):
            lo, hi = section['svgAlong']
            strip = shapely.box(-1000000, lo, 1000000, hi)
            if side == 'defense':
                strip = affine_transform(strip, reflection)
            # The authored sides differ by 0.0003 SVG units here. Classify each
            # side's complete actual paint; a reflected attack footprint leaves
            # a real positive-area defense strip with its old blocking height.
            clip = side_footprints[side].intersection(strip)
            clip = shapely.set_precision(clip, 1e-8)
            walls = []
            for wall in model['walls']:
                shape = polygon(wall)
                inside = shape.intersection(clip)
                if inside.area == 0:
                    walls.append(wall)
                    continue
                changed.append(inside)
                pieces = []
                for label, region in [('outside', shape.difference(clip)), ('tunnel', inside)]:
                    for part in shapely.get_parts(region):
                        if part.geom_type != 'Polygon' or part.area == 0:
                            continue
                        record = dict(wall, id=f'{wall["id"]}-tunnel-{index}-{label}-{len(walls)}',
                                      rings=rings(part), fillRule='evenodd')
                        if label == 'tunnel':
                            record.update(floorElevationMeters=0., bands=section['bands'], unknownHeight=False)
                        pieces.append(part)
                        walls.append(record)
                assert shape.symmetric_difference(shapely.union_all(pieces)).area < 1e-7
            model['walls'] = walls
        model['walls'], remnants = remove_collapsed_walls(model['walls'])
        changed_area = shapely.union_all(changed)
        receiver = shapely.union_all([polygon(r) for r in model['receiver']])
        old_walls = [polygon(w) for w in baseline['walls']]
        new_walls = [polygon(w) for w in model['walls']]
        restored = []
        for domain in source['domains']:
            native = shapely.from_geojson(json.dumps(domain['nativeGeometry']))
            projected = project_source(native, [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]])
            if not projected.intersects(changed_area):
                continue
            local = area_shape(projected.intersection(receiver).intersection(changed_area))
            plane = svg_plane(domain['nativePlane'], matrix)
            before = applicable_domain(local, plane, baseline['walls'], old_walls)
            after = applicable_domain(local, plane, model['walls'], new_walls)
            added = area_shape(after.difference(before))
            if added.area < 1e-7:
                continue
            sid = f'pearl-measured-{domain["id"]}'
            support = next((s for s in model['supports'] if s['id'] == sid), None)
            if support is None:
                point = added.representative_point()
                z = float(plane @ np.array([point.x, point.y, 1.]))
                support = dict(id=sid, label='Platform', fillRule='evenodd', floorElevationMeters=0.,
                               heightAboveFloorMeters=z, surfaceElevationMeters=z,
                               surfacePlane=plane.tolist(), automaticStandingAllowed=True)
                model['supports'].append(support)
                old = shapely.Polygon()
            else:
                old = polygon(support)
            support['rings'] = encode(old.union(added))
            restored.append(dict(domainId=domain['id'], supportId=sid, addedAreaSvg=float(added.area)))
        assert model['ground'] == baseline['ground'] and model['receiver'] == baseline['receiver']
        target = output/f'candidate-{side}.json.gz'
        target.write_bytes(gzip.compress(json.dumps(model, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
        reports.append(dict(side=side, candidateSha256=sha(target), changedAreaSvg=float(changed_area.area),
                            restoredStanding=restored, removedNumericalRemnants=remnants))
    report = dict(reviewSha256=sha(REVIEW), algorithmSha256=sha(Path(__file__)),
                  sourceObjects=[dict(index=i, **objects[i]) for i in review['sourceObjects']],
                  sourceFaces=face_ids.tolist(), sections=sections, sides=reports)
    (output/'review.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(dict(sections=len(sections), sides=reports)), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    build(parser.parse_args().output)
