"""Apply the reported Breeze gameplay decisions without changing SVG footprints."""
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

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REVIEW = Path('scripts/data/breeze-gameplay-sightlines-2026-09-13.json')


def read(path):
    raw = path.read_bytes()
    return json.loads(gzip.decompress(raw) if path.suffix == '.gz' else raw)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(output):
    output.mkdir(parents=True, exist_ok=True)
    review = read(REVIEW)
    source_path = Path(review['standingSource'])
    assert sha(source_path) == review['standingSourceSha256']
    source = read(source_path)
    for excluded in review['excludedStandingDomains']:
        original = next(d for d in source['domains'] if d['id'] == excluded['id'])
        assert all(original[k] == v for k, v in excluded.items())
    excluded_ids = {d['id'] for d in review['excludedStandingDomains']}
    source['domains'] = [d for d in source['domains'] if d['id'] not in excluded_ids]
    source['gameplaySightlineReviewSha256'] = sha(REVIEW)
    source_dir = output / 'source'
    source_dir.mkdir(exist_ok=True)
    (source_dir / 'regional-floors.json').write_text(json.dumps(source, indent=2) + '\n')
    inventory_path = source_path.with_name('source-inventory.json')
    (source_dir / 'source-inventory.json').write_bytes(inventory_path.read_bytes())
    alignment_path = ROOT / 'tactical-alignment-sides-v1/breeze.json'
    alignment = read(alignment_path)
    attack, defense = [np.asarray(alignment[f'nativeTo{s}Svg']) for s in ['Attack', 'Defense']]
    linear = defense[:, :2] @ np.linalg.inv(attack[:, :2])
    offset = defense[:, 2] - linear @ attack[:, 2]
    transform = [*linear[0], *linear[1], *offset]
    geometry_path = ROOT / 'supplemented-v2/world/breeze/geometry.npz'
    metadata_path = geometry_path.with_suffix('.json')
    for key, path in [('geometry', geometry_path), ('metadata', metadata_path), ('alignment', alignment_path)]:
        assert sha(path) == review['sourceSha256'][key], (key, 'Source changed; gameplay review required')
    objects = read(metadata_path)['objects']
    geometry = np.load(geometry_path)
    regions = []
    for region in review['wallRegions']:
        obj = objects[region['sourceObject']]
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        heights = geometry['points'][geometry['faces'][ids], 2].max(axis=1)
        top = float(heights.max())
        regions.append(dict(**region, topMeters=top, sourcePath=obj['path'],
                            topSourceFaces=ids[np.abs(heights - top) < 1e-7].tolist()))
    reports = []
    footprint_dir = ROOT / 'tactical-visibility-revision/all-map-svg-footprints-v1'
    attack_ink = read(footprint_dir / 'breeze-attack.json')['walls']
    for side in ['attack', 'defense']:
        asset = Path(f'assets/maps/breeze_svg_height_{side}.json.gz')
        baseline_path = output / f'before-{side}.json.gz'
        if not baseline_path.exists():
            assert sha(asset) == review['baselineSha256'][side]
            baseline_path.write_bytes(asset.read_bytes())
        assert sha(baseline_path) == review['baselineSha256'][side]
        baseline = read(baseline_path)
        model = copy.deepcopy(baseline)
        excluded_supports = set(review['excludedSupportIds'])
        assert excluded_supports <= {s['id'] for s in model['supports']}
        model['supports'] = [s for s in model['supports'] if s['id'] not in excluded_supports]
        side_ink = read(footprint_dir / f'breeze-{side}.json')['walls']
        changes = []
        for index, region in enumerate(regions):
            parent = region['parent']
            clip = shapely.box(*region['clipBox'])
            if side == 'defense':
                original = next(w for w in attack_ink if w['id'] == parent)
                reflected = affine_transform(polygon(original), transform)
                matched = min(side_ink, key=lambda w: polygon(w).hausdorff_distance(reflected))
                assert polygon(matched).hausdorff_distance(reflected) < .6
                parent = matched['id']
                clip = affine_transform(clip, transform)
            before, after, walls = [], [], []
            for wall in model['walls']:
                if wall['id'] != parent and not wall['id'].startswith(parent + '-'):
                    walls.append(wall)
                    continue
                shape = polygon(wall)
                inside = shape.intersection(clip)
                if inside.area < 1e-12:
                    walls.append(wall)
                    continue
                before.append(shape)
                for label, domain in [('outside', shape.difference(clip)), ('facade', inside)]:
                    for part_index, part in enumerate(shapely.get_parts(domain)):
                        if part.geom_type != 'Polygon' or part.area < 1e-12:
                            continue
                        record = dict(wall, id=f'{wall["id"]}-review-{index}-{label}-{part_index}',
                                      rings=rings(part), fillRule='evenodd')
                        if label == 'facade':
                            record.update(floorElevationMeters=0., bands=[[0., region['topMeters']]],
                                          unknownHeight=False)
                        walls.append(record)
                        after.append(part)
            assert before, (side, region)
            difference = shapely.union_all(before).symmetric_difference(shapely.union_all(after)).area
            assert difference < 1e-7
            model['walls'] = walls
            changes.append(dict(parent=parent, region=index, footprintDifference=difference))
        model['sourceGameplaySightlineReviewSha256'] = sha(REVIEW)
        assert model['ground'] == baseline['ground'] and model['receiver'] == baseline['receiver']
        target = output / f'candidate-{side}.json.gz'
        target.write_bytes(gzip.compress(json.dumps(model, separators=(',', ':'), allow_nan=False).encode(), mtime=0))
        reports.append(dict(side=side, candidateSha256=sha(target), wallRegions=changes))
    report = dict(reviewSha256=sha(REVIEW), algorithmSha256=sha(Path(__file__)),
                  sourceSha256={str(p): sha(p) for p in [source_path, inventory_path, alignment_path, geometry_path, metadata_path]},
                  retainedStandingDomains=len(source['domains']), excludedStandingDomains=review['excludedStandingDomains'],
                  regions=regions, sides=reports)
    (output / 'review.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(retainedStandingDomains=len(source['domains']), sides=reports)), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    build(parser.parse_args().output)
