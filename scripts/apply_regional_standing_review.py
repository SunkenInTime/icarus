"""Apply recorded gameplay decisions to frozen source domains, without app assets."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import shutil

import numpy as np
import shapely

from audit_all_map_gameplay_levels import ROOT, read
from compile_reviewed_svg_height_map import polygon
from polygonal_area import polygonal

REVIEW = Path(__file__).parent/'data/gameplay-standing-review-2026-09-08.json'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clean(shape):
    return polygonal(shapely.set_precision(shapely.make_valid(shape), 1e-7))


def exclusions_for(entry):
    grouped = defaultdict(list)
    for row in entry.get('exclusions', []):
        grouped[row['sourceObject']].append(polygon(dict(rings=row['nativeRings'], fillRule=row['fillRule'])))
    return {oid: clean(shapely.union_all(parts)) for oid, parts in grouped.items()}


def reviewed_domains(entry, objects, geometry, collider_rows, triangles, region):
    exclusions = exclusions_for(entry)
    by_face = defaultdict(list)
    for row in entry['samples']:
        by_face[row['sourceFace']].append(row)
    body_ids = {row['id']: i for i, row in enumerate(collider_rows)}
    groups, evidence = defaultdict(list), defaultdict(list)
    physical_evidence = {}
    for face, samples in sorted(by_face.items()):
        first = samples[0]
        oid = first['sourceObject']
        obj = objects[oid]
        assert obj['firstFace'] <= face < obj['firstFace'] + obj['faceCount']
        triangle = geometry['points'][geometry['faces'][face]].astype(float)
        plane = np.linalg.solve(np.c_[triangle[:, :2], np.ones(3)], triangle[:, 2])
        shape = shapely.Polygon(triangle[:, :2])
        for row in samples:
            assert row['sourceObject'] == oid and row['sourcePath'] == obj['path']
            assert shape.buffer(1e-6).covers(shapely.Point(row['nativeXY']))
            assert abs(plane[:2]@row['nativeXY'] + plane[2] - row['renderedElevationMeters']) < 1e-6
        shape = clean(shape.intersection(region).difference(exclusions.get(oid, shapely.Polygon())))
        replaced = []
        for row in samples:
            physical = row['physicalFloor']
            if physical is None:
                continue
            index = body_ids[physical['collision']]
            tri = triangles[str(index)]
            actual = tri[physical['face']]
            coefficient = np.linalg.solve(np.c_[actual[:, :2], np.ones(3)], actual[:, 2])
            assert np.max(abs(coefficient - np.array(physical['plane']))) < 1e-7
            assert abs(coefficient[:2]@row['nativeXY'] + coefficient[2] - physical['floorMeters']) < 1e-6
            assert shapely.Polygon(actual[:, :2]).buffer(1e-6).covers(shapely.Point(row['nativeXY']))
            coplanar = np.max(abs(tri[:, :, 2] - tri[:, :, :2]@coefficient[:2] - coefficient[2]), axis=1) < 1e-6
            local = clean(shape.intersection(shapely.union_all(shapely.polygons(tri[coplanar, :, :2]))))
            if local.is_empty:
                continue
            key = (oid, physical['collision'], *np.round(coefficient, 10))
            groups[key].append(local)
            evidence[key].append(dict(sourceFace=face, reviewedSample=row['id'], collisionFace=physical['face']))
            physical_evidence[physical['collision']] = dict(source=collider_rows[index],
                trianglesSha256=hashlib.sha256(tri.tobytes()).hexdigest())
            replaced.append(local)
        remaining = clean(shape.difference(shapely.union_all(replaced)))
        if not remaining.is_empty:
            key = (oid, '', *np.round(plane, 10))
            groups[key].append(remaining)
            evidence[key].append(dict(sourceFace=face, reviewedSamples=[r['id'] for r in samples]))
    domains = []
    for key, parts in sorted(groups.items()):
        shape = clean(shapely.union_all(parts))
        identifier = hashlib.sha256(json.dumps(key).encode()).hexdigest()[:16]
        row = dict(id=f'reviewed-mesh-{key[0]}-{identifier}', sourceObject=key[0],
            sourcePath=objects[key[0]]['path'], nativePlane=list(key[2:]),
            nativeGeometry=json.loads(shapely.to_geojson(shape)), areaSquareMeters=shape.area,
            eligibilityBasis='Dara gameplay review 2026-09-08',
            heightBasis='matched-player-collision' if key[1] else 'reviewed-source-face',
            reviewedSourceFaces=evidence[key])
        if key[1]:
            row['sourceCollision'] = key[1]
        domains.append(row)
    return domains, physical_evidence


def apply(source_dir, output, review_path=REVIEW):
    if output.exists():
        raise ValueError('Choose a new output folder; preserve the raw physical measurement.')
    inventory_path = source_dir/'source-inventory.json'
    inventory = read(inventory_path)
    source_path = source_dir/'regional-floors.json'
    source = read(source_path)
    assert source['sourceInventorySha256'] == sha(inventory_path)
    assert not source['unresolvedInfluencingCollision']
    name = inventory['map']
    entry = read(review_path)['maps'][name]
    geometry_path = ROOT/f'supplemented-v2/world/{name}/geometry.npz'
    alignment_path = ROOT/f'tactical-alignment-sides-v1/{name}.json'
    assert sha(geometry_path) == entry['sourceGeometrySha256'] == inventory['source']['geometrySha256']
    assert sha(geometry_path.with_suffix('.json')) == entry['sourceMetadataSha256'] == inventory['source']['metadataSha256']
    assert sha(alignment_path) == entry['alignmentSha256'] == inventory['source']['alignmentSha256']
    assert sha(review_path) == inventory['source']['gameplayStandingReviewSha256']
    region = shapely.from_geojson(json.dumps(inventory['sourceRegion']))
    with np.load(geometry_path) as geometry, np.load(source_dir/'source-colliders.npz') as colliders:
        reviewed, physical = reviewed_domains(entry, read(geometry_path.with_suffix('.json'))['objects'],
            geometry, read(source_dir/'source-colliders.json'), colliders, region)
    exclusions = exclusions_for(entry)
    domains, excluded = [], []
    for row in source['domains']:
        if row.get('sourceObject') not in exclusions:
            domains.append(row)
            continue
        shape = shapely.from_geojson(json.dumps(row['nativeGeometry']))
        kept = clean(shape.difference(exclusions[row['sourceObject']]))
        excluded.append(dict(sourceDomain=row['id'], sourceObject=row['sourceObject'],
            removedAreaSquareMeters=shape.area-kept.area, retainedAreaSquareMeters=kept.area))
        if not kept.is_empty:
            domains.append(dict(row, nativeGeometry=json.loads(shapely.to_geojson(kept)), areaSquareMeters=kept.area,
                gameplayExclusionReviewSha256=sha(review_path)))
    domains.extend(reviewed)
    output.mkdir(parents=True)
    for filename in ['source-inventory.json', 'source-colliders.json', 'source-colliders.npz',
                     'collision-accounting.json', 'collision-algorithm.py']:
        shutil.copyfile(source_dir/filename, output/filename)
    for directory in ['algorithm-sources', 'inventory-algorithms']:
        shutil.copytree(source_dir/directory, output/directory)
    shutil.copyfile(source_path, output/'raw-physical-floors.json')
    shutil.copyfile(review_path, output/'gameplay-standing-review.json')
    algorithms = [Path(__file__), Path(__file__).with_name('polygonal_area.py'),
        Path(__file__).with_name('compile_reviewed_svg_height_map.py')]
    archive = output/'review-algorithms'
    archive.mkdir()
    for path in algorithms:
        shutil.copyfile(path, archive/path.name)
    report = dict(map=name, rawPhysicalSourceSha256=sha(source_path), reviewSha256=sha(review_path),
        sourceInventorySha256=sha(inventory_path), sourceCollidersSha256=sha(output/'source-colliders.json'),
        sourceColliderTrianglesSha256=sha(output/'source-colliders.npz'),
        algorithmSha256={p.name: sha(p) for p in algorithms},
        reviewedSamples=len(entry['samples']), reviewedDomains=len(reviewed),
        physicalEvidence=physical, exclusions=entry.get('exclusions', []), excludedPhysicalDomains=excluded,
        reviewedDomainIds=[r['id'] for r in reviewed],
        scope='Exact reviewed source faces, clipped to the declared region. Original physical source decisions remain unchanged in raw-physical-floors.json.')
    report_path = output/'gameplay-review-application.json'
    report_path.write_text(json.dumps(report, indent=2)+'\n')
    final = dict(source, map=name, status='source-domains-with-gameplay-review', domains=domains,
        rawPhysicalSourceSha256=sha(source_path), gameplayReviewApplicationSha256=sha(report_path))
    (output/'regional-floors.json').write_text(json.dumps(final, indent=2)+'\n')
    print(json.dumps(dict(map=name, rawDomains=len(source['domains']), reviewedDomains=len(reviewed),
        finalDomains=len(domains), sourceSha256=sha(output/'regional-floors.json'))), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--review', type=Path, default=REVIEW)
    args = parser.parse_args()
    apply(args.source, args.output, args.review)
