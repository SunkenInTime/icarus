"""Compare a full-scene source measurement with a completed smaller region."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path

import shapely

from polygonal_area import polygonal


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compare(whole, regional):
    whole_path, regional_path = whole/'regional-floors.json', regional/'regional-floors.json'
    earlier, current = [json.loads(p.read_bytes()) for p in [regional_path, whole_path]]
    inventory_path = regional/'source-inventory.json'
    region = shapely.from_geojson(json.dumps(json.loads(inventory_path.read_bytes())['sourceRegion']))
    grouped = []
    for source in [earlier, current]:
        levels = defaultdict(list)
        for domain in source['domains']:
            shape = polygonal(shapely.from_geojson(json.dumps(domain['nativeGeometry'])).intersection(region))
            if shape.is_empty:
                continue
            key = (domain.get('sourceObject'), domain.get('sourceCollision'), tuple(domain['nativePlane']))
            levels[key].append(shape)
        grouped.append({key: shapely.union_all(parts) for key, parts in levels.items()})
    rows = []
    tolerance = 1e-5  # 0.01 mm in native XY, below the SVG contact tolerance.
    for key in sorted(grouped[0].keys() | grouped[1].keys(), key=str):
        before = grouped[0].get(key, shapely.Polygon())
        after = grouped[1].get(key, shapely.Polygon())
        missing = before.difference(after.buffer(tolerance)).area
        extra = after.difference(before.buffer(tolerance)).area
        rows.append(dict(sourceObject=key[0], sourceCollision=key[1], nativePlane=key[2],
            missingAreaSquareMeters=missing, addedAreaSquareMeters=extra,
            status='passed' if missing < 1e-8 and extra < 1e-8 else 'source-difference'))
    report = dict(status='passed' if all(r['status'] == 'passed' for r in rows) else 'source-differences',
        wholeSourceSha256=sha(whole_path), regionalSourceSha256=sha(regional_path),
        regionalInventorySha256=sha(inventory_path), algorithmSha256=sha(Path(__file__)),
        boundaryToleranceMeters=tolerance, areaToleranceSquareMeters=1e-8, checks=len(rows), rows=rows)
    (whole/'regional-source-consistency.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'rows'}))
    for row in rows:
        if row['status'] != 'passed':
            print(json.dumps(row))
    return report['status'] == 'passed'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--whole', type=Path, required=True)
    parser.add_argument('--regional', type=Path, required=True)
    args = parser.parse_args()
    raise SystemExit(0 if compare(args.whole, args.regional) else 1)
