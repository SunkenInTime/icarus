"""Apply the measured upper-crate wall correction to independently composed data.

The exact affected wall records are pinned. Unrelated wall changes and changes
to ground/support selection survive composition without being silently reset.
"""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from compile_reviewed_svg_height_map import polygon


def read(path):
    path = Path(path)
    raw = path.read_bytes()
    return json.loads(gzip.decompress(raw) if path.suffix == '.gz' else raw)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def rings(shape):
    return [np.asarray(r.coords).reshape(-1).tolist()
            for r in [shape.exterior, *shape.interiors]]


def compile_review(review_path, inputs, output):
    review = read(review_path)
    assert review['map'] == 'lotus'
    for path, expected in review['sources'].items():
        assert sha(path) == expected, ('Changed source', path)
    geometry_path = next(Path(p) for p in review['sources'] if p.endswith('geometry.npz'))
    metadata = read(geometry_path.with_suffix('.json'))['objects']
    geometry = np.load(geometry_path)
    selected = []
    for oid in review['sourceObjects']:
        obj = metadata[oid]
        selected.extend(range(obj['firstFace'], obj['firstFace'] + obj['faceCount']))
    top = float(geometry['points'][geometry['faces'][selected]][:, :, 2].max())
    assert abs(top - review['sourceTopMeters']) < 1e-8
    for entry in [review['standingSource'], review['standingAlignment']]:
        assert sha(entry['path']) == entry['sha256'], ('Standing source changed', entry['path'])
    standing_source = read(review['standingSource']['path'])
    standing_alignment = read(review['standingAlignment']['path'])
    output.mkdir(parents=True, exist_ok=True)
    reports = []
    for side, path in inputs.items():
        before = read(path)
        candidate = copy.deepcopy(before)
        spec = review['sides'][side]
        clip = shapely.set_precision(polygon(spec), 1e-8)
        expected = {w['id']: w for w in spec['expectedAffectedWalls']}
        actual = {w['id']: w for w in before['walls'] if w['id'] in expected}
        assert actual == expected, (side, 'Affected wall state changed; re-review composition')
        affected, changed, walls = [], [], []
        for wall in before['walls']:
            domain = polygon(wall)
            belongs = wall['id'] == spec['parent'] or wall['id'].startswith(spec['parent'] + '-')
            inside = domain.intersection(clip) if belongs else shapely.GeometryCollection()
            if inside.area <= 1e-12:
                walls.append(wall)
                continue
            assert wall['id'] in expected, (side, 'Unaccounted affected cell', wall['id'])
            affected.append(wall['id'])
            changed.append(inside)
            for label, pieces in [('retained', domain.difference(inside)), ('upper-crate', inside)]:
                for shape in shapely.get_parts(pieces):
                    if shape.geom_type != 'Polygon' or shape.area <= 1e-12:
                        continue
                    record = dict(wall, id=f'{wall["id"]}-{label}-{len(walls)}',
                                  rings=rings(shape), fillRule='evenodd')
                    if label == 'upper-crate':
                        assert not wall['unknownHeight'] and len(wall['bands']) == 1
                        lower = wall['bands'][0][0]
                        relative_top = top - wall['floorElevationMeters']
                        assert relative_top > lower
                        # The correction changes only the cap. Preserve the
                        # original base datum and lower interval endpoint.
                        record.update(bands=[[lower, relative_top]], unknownHeight=False)
                    walls.append(record)
        assert set(affected) == set(expected), (side, 'Missing affected wall')
        assert clip.difference(shapely.union_all(changed)).area < 1e-7
        from svg_wall_footprint_integrity import remove_collapsed_walls
        walls, collapsed = remove_collapsed_walls(walls)
        old_shape = shapely.union_all([polygon(w) for w in before['walls']])
        new_shape = shapely.union_all([polygon(w) for w in walls])
        difference = old_shape.symmetric_difference(new_shape).area
        assert difference < 1e-7
        candidate['walls'] = walls
        from restore_exposed_standing_floors import restore_exposed_floors
        restored = restore_exposed_floors(review['map'], before, candidate, standing_source, standing_alignment[f'nativeTo{side.title()}Svg'])
        candidate['sourceLotusLowCrateReviewSha256'] = sha(review_path)
        for key in set(before) - {'walls', 'supports', 'sourceLotusLowCrateReviewSha256'}:
            assert candidate[key] == before[key], (side, 'Unrelated model field changed', key)
        target = output / f'candidate-{side}.json.gz'
        target.write_bytes(gzip.compress((json.dumps(candidate, separators=(',', ':')) + '\n').encode(), mtime=0))
        reports.append(dict(side=side, inputPath=str(path), inputSha256=sha(path),
                            outputPath=str(target), outputSha256=sha(target),
                            affectedWalls=affected, collapsedWalls=collapsed, restoredStandingDomains=restored,
                            footprintDifferenceAreaSvg=difference))
    result = dict(status='compiled', reviewPath=str(review_path), reviewSha256=sha(review_path),
                  algorithmSha256=sha(__file__), sourceTopMeters=top, sourceFaces=selected, sides=reports)
    (output / 'lotus-low-crate-build.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(status='compiled', sides=len(reports), sourceTopMeters=top)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--review', type=Path, default=Path('scripts/data/lotus-low-crate-review-2026-09-14.json'))
    parser.add_argument('--attack', type=Path, default=Path('assets/maps/lotus_svg_height_attack.json.gz'))
    parser.add_argument('--defense', type=Path, default=Path('assets/maps/lotus_svg_height_defense.json.gz'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    compile_review(args.review, {'attack': args.attack, 'defense': args.defense}, args.output)
