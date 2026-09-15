"""Install measured defense translations after checking both authored SVGs."""
import argparse
import hashlib
import json
from pathlib import Path


def install(report, repository):
    rows = json.loads(report.read_bytes())
    catalog_path = repository / 'assets/maps/world/height_catalog.json'
    catalog = json.loads(catalog_path.read_bytes())
    if {row['map'] for row in rows} != set(catalog['maps']) or len(rows) != 13:
        raise ValueError('Expected one side registration for every map')
    fixture = []
    for row in rows:
        name = row['map']
        if not row['translationSufficientWithin0_01Svg'] or row['heldOutCorners']['maxSvg'] > .01:
            raise ValueError(f'{name}: side registration failed held-out corners')
        for side, suffix in [('attack', ''), ('defense', '_defense')]:
            svg = repository / f'assets/maps/{name}_map{suffix}.svg'
            if hashlib.sha256(svg.read_bytes()).hexdigest() != row[f'{side}Sha256']:
                raise ValueError(f'{name}: {side} artwork changed since registration')
        catalog['maps'][name]['defenseOffsetSvg'] = row['defenseDeltaAfterReflectionSvg']
        fixture.append({key: row[key] for key in [
            'map', 'attackSha256', 'defenseSha256', 'attackViewBox',
            'defenseViewBox', 'defenseDeltaAfterReflectionSvg',
            'nativeToAttackSvg', 'nativeToDefenseSvg', 'heldOutCorners']})
    catalog_path.write_text(json.dumps(catalog, indent=2) + '\n')
    fixture_path = repository / 'test/fixtures/height_side_registration.json'
    fixture_path.write_text(json.dumps(fixture, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--repository', type=Path, default=Path('.'))
    args = parser.parse_args()
    install(args.report, args.repository)
