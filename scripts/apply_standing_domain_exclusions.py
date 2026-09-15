"""Apply explicit gameplay exclusions while preserving the collision inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

import numpy as np
import shapely

from build_all_map_gameplay_supports import plane_region
from polygonal_area import polygonal


def read(path):
    return json.loads(path.read_bytes())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def exclude_domains(source, colliders, triangles, review):
    decisions = review['decisions']
    approved = []
    for decision in decisions:
        assert decision['status'] == 'approved'
        if decision['scope'] == 'specified-standing-domain':
            reviewed = decision['domain']
            faces = {tuple(face) for face in reviewed['sourceFaces']}
            assert faces
            for index, face in faces:
                tri = triangles[str(index)][face]
                normal = np.cross(tri[1]-tri[0], tri[2]-tri[0])
                assert abs(normal[2]) > 1e-12
                plane = np.array([-normal[0], -normal[1], normal@tri[0]]) / normal[2]
                # Measurement groups source plane coefficients at four decimal
                # places. Validate those coefficients, not accumulated XY error.
                assert np.array_equal(np.round(plane, 4), reviewed['nativePlane'])
            footprint = polygonal(shapely.from_geojson(json.dumps(reviewed['nativeGeometry'])))
            assert not footprint.is_empty
            approved.append((decision, None, faces, footprint))
            continue
        assert decision['scope'] in ['specified-collision-faces', 'at-or-above-collision-face-within-footprint']
        indices = [i for i, row in enumerate(colliders) if row['id'] == decision['sourceCollision']]
        assert len(indices) == 1
        index = indices[0]
        faces = set(decision['sourceFaces'])
        tri = triangles[str(index)][sorted(faces)]
        plane = np.asarray(decision['nativePlane'])
        assert np.max(abs(tri[:, :, 2] - tri[:, :, :2]@plane[:2] - plane[2])) < 1e-6
        footprint = polygonal(shapely.union_all(shapely.polygons(tri[:, :, :2])))
        assert not footprint.is_empty
        approved.append((decision, index, faces, footprint))
    kept, removed = [], []
    for original in source['domains']:
        domain = original
        for decision, index, faces, footprint in approved:
            if decision['scope'] == 'specified-standing-domain':
                reviewed = decision['domain']
                if any(domain.get(key) != reviewed.get(key)
                       for key in ['sourceObject', 'sourceCollision', 'sourcePath']):
                    continue
                references = {tuple(face) for face in domain.get('sourceFaces', [])}
                # A smaller measurement can retain only some faces of the
                # reviewed domain. Its ID alone is not a source association.
                if not references or not references.issubset(faces):
                    continue
                assert np.max(abs(np.asarray(domain['nativePlane'])-reviewed['nativePlane'])) < 1e-10
                shape = polygonal(shapely.from_geojson(json.dumps(domain['nativeGeometry'])))
                excluded = polygonal(shape.intersection(footprint))
                if excluded.is_empty:
                    continue
                # Whole and regional measurements use this same native grid.
                # Avoid manufacturing a standing sliver from sub-grid rounding.
                remaining = polygonal(shapely.difference(shape, footprint, grid_size=1e-7))
                record = dict(decision=decision['id'], domain=domain,
                    excludedGeometry=json.loads(shapely.to_geojson(excluded)))
                removed.append(record)
                if remaining.is_empty:
                    domain = None
                    break
                domain = dict(domain, nativeGeometry=json.loads(shapely.to_geojson(remaining)),
                    areaSquareMeters=remaining.area)
                record['retainedDomain'] = domain
                continue
            if decision['scope'] == 'at-or-above-collision-face-within-footprint':
                shape = polygonal(shapely.from_geojson(json.dumps(domain['nativeGeometry'])))
                # A source plane is rounded to 0.1 mm; admit half that step at
                # the actual source boundary, rather than imposing a map-wide cap.
                excluded = polygonal(plane_region(shape.intersection(footprint),
                    np.asarray(domain['nativePlane'])-decision['nativePlane'], -.00005, 1e6))
                if excluded.area <= 1e-8:
                    continue
                remaining = polygonal(shape.difference(excluded))
                record = dict(decision=decision['id'], domain=domain,
                    excludedGeometry=json.loads(shapely.to_geojson(excluded)))
                if remaining.is_empty:
                    removed.append(record)
                    domain = None
                    break
                domain = dict(domain, nativeGeometry=json.loads(shapely.to_geojson(remaining)),
                    areaSquareMeters=remaining.area)
                record['retainedDomain'] = domain
                removed.append(record)
                continue
            references = domain.get('sourceFaces', []) if domain.get('sourceCollision') == decision['sourceCollision'] else []
            if references and all(i == index and face in faces for i, face in references):
                assert np.max(abs(np.asarray(domain['nativePlane'])-decision['nativePlane'])) <= .00005
                removed.append(dict(decision=decision['id'], domain=domain))
                domain = None
                break
        if domain is not None:
            kept.append(domain)
    return kept, removed


def apply(source_dir, output, review_path):
    if output.exists():
        raise ValueError('Choose a new output folder to preserve prior evidence.')
    source_path = source_dir/'regional-floors.json'
    source = read(source_path)
    inventory = read(source_dir/'source-inventory.json')
    review = read(review_path)
    assert inventory['map'] == review['map']
    assert sha(source_dir/'source-colliders.json') == review['sourceCollidersSha256']
    assert sha(source_dir/'source-colliders.npz') == review['sourceColliderTrianglesSha256']
    colliders = read(source_dir/'source-colliders.json')
    with np.load(source_dir/'source-colliders.npz') as triangles:
        domains, removed = exclude_domains(source, colliders, triangles, review)
    assert removed, 'No reviewed source faces occur in this region.'
    if review.get('sourceSha256') == sha(source_path):
        assert len(domains) == review['retainedDomainCountIfApproved']
        assert len(removed) == len(review['decisions'])
        assert all('retainedDomain' not in record for record in removed)
    output.mkdir(parents=True)
    for name in ['source-inventory.json', 'source-colliders.json', 'source-colliders.npz',
                 'collision-accounting.json', 'collision-algorithm.py']:
        shutil.copyfile(source_dir/name, output/name)
    # Maps without an earlier standing correction start from measured floors.
    # Preserve prior review evidence when it exists, without inventing a review.
    for name in ['raw-physical-floors.json', 'gameplay-standing-review.json',
                 'gameplay-review-application.json']:
        if (source_dir/name).exists():
            shutil.copyfile(source_dir/name, output/name)
    for name in ['algorithm-sources', 'inventory-algorithms']:
        shutil.copytree(source_dir/name, output/name)
    if (source_dir/'review-algorithms').exists():
        shutil.copytree(source_dir/'review-algorithms', output/'review-algorithms')
    shutil.copyfile(source_path, output/'before-source-exclusions.json')
    shutil.copyfile(review_path, output/'playable-space-review.json')
    shutil.copyfile(Path(__file__), output/Path(__file__).name)
    dependencies = ['build_all_map_gameplay_supports.py', 'polygonal_area.py']
    (output/'exclusion-algorithms').mkdir()
    for name in dependencies:
        shutil.copyfile(Path(__file__).with_name(name), output/'exclusion-algorithms'/name)
    report = dict(map=inventory['map'], inputSourceSha256=sha(source_path), reviewSha256=sha(review_path),
        algorithmSha256=sha(Path(__file__)), excludedDomains=removed,
        algorithmDependenciesSha256={name: sha(output/'exclusion-algorithms'/name) for name in dependencies},
        collisionInputsUnchanged={name: sha(output/name) for name in ['source-colliders.json', 'source-colliders.npz']})
    report_path = output/'source-exclusions-application.json'
    report_path.write_text(json.dumps(report, indent=2)+'\n')
    result = dict(source, domains=domains, sourceExclusionsApplicationSha256=sha(report_path))
    (output/'regional-floors.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(dict(map=inventory['map'], removedDomains=sum('retainedDomain' not in r for r in removed),
        clippedDomains=sum('retainedDomain' in r for r in removed), retainedDomains=len(domains),
        sourceSha256=sha(output/'regional-floors.json'))), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--review', type=Path, required=True)
    args = parser.parse_args()
    apply(args.source, args.output, args.review)
