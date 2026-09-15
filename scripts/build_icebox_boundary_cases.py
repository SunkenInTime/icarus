"""Select cone origins from source domains before opening the runtime model."""
import hashlib
import argparse
import json
from pathlib import Path
import numpy as np
import shapely
from audit_all_map_gameplay_levels import ROOT, read


def build(source_dir=Path('work/icebox-acceptance'), output=Path('work/icebox-acceptance/boundaries'),
          regional_fixture=None, explicit_levels=False):
    map_name = read(source_dir/'source-inventory.json').get('map', 'icebox')
    fixture = read(Path('test/fixtures/icebox_vision_acceptance.json')) if map_name == 'icebox' else dict(cases=[])
    regional_path = source_dir/'regional-floors.json'
    regional = read(regional_path)
    alignment = read(ROOT / f'tactical-alignment-sides-v1/{map_name}.json')
    origins = [(r['id'], r['svg'], r['expectedFloorMeters']) for r in fixture['cases']]
    review_path = source_dir/'gameplay-standing-review.json'
    if review_path.exists():
        entry = read(review_path)['maps'][map_name]
        region = shapely.from_geojson(json.dumps(read(source_dir/'source-inventory.json')['sourceRegion']))
        for row in entry['samples']:
            if not region.covers(shapely.Point(row['nativeXY'])):
                continue
            svg = {side: (np.array(alignment[f'nativeTo{side.title()}Svg'])@[*row['nativeXY'], 1]).tolist()
                for side in ['attack', 'defense']}
            height = row['physicalFloor']['floorMeters'] if row['physicalFloor'] else row['renderedElevationMeters']
            origins.append((row['id'], svg, height))
    measured_cases = read(regional_fixture) if regional_fixture else None
    if measured_cases:
        assert measured_cases['sourceSha256'] == hashlib.sha256(regional_path.read_bytes()).hexdigest()
        origins.extend((r['id'], r['svg'], r['expectedFloorMeters']) for r in measured_cases['defaultPlacements'])
    for d in ([] if measured_cases else regional['domains']):
        shape = shapely.from_geojson(json.dumps(d['nativeGeometry'])).buffer(-.000001)
        parts = [p for p in shapely.get_parts(shape) if p.geom_type == 'Polygon' and p.area > 1e-8]
        assert parts, d['id']
        p = max(parts, key=lambda p: p.area).representative_point()
        origins.append((d['id'], {side: (np.array(alignment[f'nativeTo{side.title()}Svg']) @ [p.x, p.y, 1]).tolist()
                                    for side in ['attack', 'defense']}, float(np.array(d['nativePlane']) @ [p.x, p.y, 1])))
    cases = [dict(id=f'{key}-{side}-{i}', map=map_name, side=side, originSvg=svg[side],
                  directionRadians=i * np.pi / 2, automaticStanding=not explicit_levels,
                  sourceStandingLevel=explicit_levels, sourceExpectedFloorMeters=floor)
             for key, svg, floor in origins for side in ['attack', 'defense'] for i in range(4)]
    output.mkdir(exist_ok=True, parents=True)
    (output / 'cases.json').write_text(json.dumps(cases, separators=(',', ':')) + '\n')
    (output / 'source-selection.json').write_text(json.dumps(dict(
        sourceDomainsSha256=hashlib.sha256(regional_path.read_bytes()).hexdigest(),
        gameplayReviewSha256=hashlib.sha256(review_path.read_bytes()).hexdigest() if review_path.exists() else None,
        regionalFixtureSha256=hashlib.sha256(regional_fixture.read_bytes()).hexdigest() if regional_fixture else None,
        algorithmSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        cases=len(cases), origins=len(origins), sourceSampleInsetMeters=.000001,
        selection='explicit-source-level' if explicit_levels else 'automatic'), indent=2))
    print(json.dumps(dict(cases=len(cases), origins=len(origins))))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path('work/icebox-acceptance'))
    parser.add_argument('--output', type=Path, default=Path('work/icebox-acceptance/boundaries'))
    parser.add_argument('--regional-fixture', type=Path)
    parser.add_argument('--explicit-source-levels', action='store_true')
    args = parser.parse_args()
    build(args.source, args.output, args.regional_fixture, args.explicit_source_levels)
