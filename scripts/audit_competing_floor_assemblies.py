"""Inventory overlapping source floor heights without assigning terrain roles."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from probe_source_floor_regressions import load_support


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clip_above(shapes, planes, threshold, low, high):
    partial = np.flatnonzero((low < threshold) & (high >= threshold))
    if not len(partial):
        return shapes
    length = np.linalg.norm(planes[partial, :2], axis=1)
    # A numerically constant plane can straddle a threshold only at roundoff.
    # Keep that boundary within1e-10m rather than construct an unstable plane.
    partial = partial[length > 1e-14]
    if not len(partial):
        return shapes
    normal = planes[partial, :2]
    length = np.linalg.norm(normal, axis=1)
    unit = normal / length[:, None]
    boundary = -(planes[partial, 2] - threshold)[:, None] * unit / length[:, None]
    tangent = np.column_stack((-unit[:, 1], unit[:, 0])) * 1e5
    shift = unit * 1e5
    polygons = shapely.polygons(np.stack((boundary - tangent, boundary + tangent, boundary + tangent + shift, boundary - tangent + shift), axis=1))
    shapes[partial] = shapely.intersection(shapes[partial], polygons)
    return shapes


def native_mesh(root, object_path, cache):
    parts = object_path.strip('/').split('/')
    level, actor = parts[:2]
    path = root / f'native-material-audit/resolved-component-export/properties/ShooterGame/Content/Maps/{level.split("_")[0]}/{level}.json'
    if not path.exists():
        return {'status': 'native-level-not-exported'}
    if str(path) not in cache:
        cache[str(path)] = (json.loads(path.read_text()), sha(path))
    data, digest = cache[str(path)]
    actor_names = {actor} | {r['Name'] for r in data if r.get('ActorLabel') == actor}
    component_name = parts[-1].split('.')[0]
    candidates = [r for r in data if r.get('Type') in ('StaticMeshComponent', 'InstancedStaticMeshComponent', 'HierarchicalInstancedStaticMeshComponent') and any(f"PersistentLevel.{a}'" in str(r.get('Outer')) for a in actor_names) and (r.get('Name') == component_name or component_name == 'Instances')]
    refs = {r.get('Properties', {}).get('StaticMesh', {}).get('ObjectPath') for r in candidates}
    refs.discard(None)
    if len(refs) != 1:
        return {'status': 'native-component-unresolved', 'path': str(path), 'sha256': digest, 'candidateCount': len(candidates)}
    return {'status': 'exact-native-component-mesh', 'mesh': next(iter(refs)), 'path': str(path), 'sha256': digest, 'componentNames': [r['Name'] for r in candidates], 'actorNames': sorted(actor_names)}


def audit(root, name, out):
    revision = root / 'tactical-visibility-revision'
    support_meta_path = revision / f'source-floor-support-all-walkable-v1/{name}.floor-support.json'
    support_meta = json.loads(support_meta_path.read_text())
    support = load_support(revision, name, True)
    source_count = int(np.count_nonzero(support.source_ids >= 0))
    # Conservative affine height bounds over each buffered shape AABB remove
    # coplanar pairs before expensive polygon intersections.
    bounds = shapely.bounds(support.polygons)
    heights_a = support.planes[:, :2] * bounds[:, :2]
    heights_b = support.planes[:, :2] * bounds[:, 2:]
    shape_zmin = np.minimum(heights_a, heights_b).sum(axis=1) + support.planes[:, 2]
    shape_zmax = np.maximum(heights_a, heights_b).sum(axis=1) + support.planes[:, 2]
    pairs, minima, maxima, overlap_shapes, areas = [], [], [], [], []
    # Query sources against both other sources and nav. Retain both directions
    # where slopes cross. Heights are evaluated over the actual overlap.
    for start in range(0, source_count, 4000):
        a, b = support.tree.query(support.polygons[start:min(start + 4000, source_count)])
        a += start
        keep = (a != b) & (shape_zmax[a] - shape_zmin[b] >= .05 - 1e-10) & (shape_zmin[a] - shape_zmax[b] <= .35 + 1e-10)
        a, b = a[keep], b[keep]
        intersections = shapely.intersection(support.polygons[a], support.polygons[b])
        area = shapely.area(intersections)
        good = area > 1e-6
        a, b, intersections, area = a[good], b[good], intersections[good], area[good]
        xy, owners = shapely.get_coordinates(intersections, return_index=True)
        planes = support.planes[a] - support.planes[b]
        gap = np.sum(xy * planes[owners, :2], axis=1) + planes[owners, 2]
        low, high = np.full(len(a), np.inf), np.full(len(a), -np.inf)
        np.minimum.at(low, owners, gap)
        np.maximum.at(high, owners, gap)
        good = (high >= .05) & (low <= .35)
        a, b, low, high, intersections, planes = a[good], b[good], low[good], high[good], intersections[good], planes[good]
        intersections = clip_above(intersections, planes, .05, low, high)
        intersections = clip_above(intersections, -planes, -.35, -high, -low)
        area = shapely.area(intersections)
        good = area > 1e-6
        pairs.extend(zip(a[good].tolist(), b[good].tolist()))
        minima.extend(np.maximum(low[good], .05).tolist())
        maxima.extend(np.minimum(high[good], .35).tolist())
        overlap_shapes.extend(intersections[good])
        areas.extend(area[good].tolist())
    pairs = np.asarray(pairs, dtype=np.int32).reshape(-1, 2)
    minima, maxima, areas = np.asarray(minima), np.asarray(maxima), np.asarray(areas)
    print(name, 'source faces', source_count, 'competing pairs', len(pairs), flush=True)
    np.savez_compressed(out / f'{name}.pairs.npz', supportIndices=pairs, minimumGapMeters=minima, maximumGapMeters=maxima, overlapAreaUpperBoundMeters2=areas)
    world = next(row for row in json.loads((root / 'completeness/combined-manifest-release-inputs-v2.json').read_text()) if row['map'] == name)
    metadata = json.loads((Path(world['combinedWorldFolder']) / 'geometry.json').read_text())
    correspondence = np.load(revision / f'full-height-input-v1/{name}/source-correspondence.npz')['sourceFaces']
    object_starts = np.asarray([row['firstFace'] for row in metadata['objects']])
    source_object_ids = np.searchsorted(object_starts, correspondence[support.source_ids[:source_count]], side='right') - 1
    groups = collections.defaultdict(list)
    for index, upper in enumerate(pairs[:, 0]):
        groups[int(source_object_ids[upper])].append(index)
    nav_ids = support.detailed_navigation_indices
    nav_tree = shapely.STRtree(support.polygons[nav_ids])
    native_cache = {}
    records = []
    for object_index, pair_indices in groups.items():
        object_data = metadata['objects'][object_index]
        object_path = object_data['path']
        object_support = np.flatnonzero(source_object_ids == object_index)
        samples = np.concatenate([support.points[object_support], support.points[object_support].mean(axis=1)[:, None]], axis=1).reshape(-1, 3)
        sample_ids, nav_local = nav_tree.query(shapely.points(samples[:, :2]), predicate='intersects')
        expected = np.sum(samples[sample_ids, :2] * support.planes[nav_ids[nav_local], :2], axis=1) + support.planes[nav_ids[nav_local], 2]
        residual = samples[sample_ids, 2] - expected
        matches = np.abs(residual) <= .1
        matched_samples = samples[sample_ids[matches]]
        matched_nav_z = expected[matches]
        # Every candidate remains unclassified. Rising nav span ranks review;
        # it cannot turn a walkable crate or rock into structural terrain.
        progression = float(np.ptp(matched_nav_z)) if len(matched_nav_z) else 0.
        indices = np.asarray(pair_indices)
        upper_ids = np.unique(pairs[indices, 0])
        footprint = shapely.union_all([overlap_shapes[i] for i in indices], grid_size=1e-8)
        if footprint.area < 1e-5:
            continue
        lower_groups = collections.Counter(int(source_object_ids[b]) if b < source_count else -1 for b in pairs[indices, 1])
        lower_groups = [{'sourceObjectIndex': index if index >= 0 else None, 'object': metadata['objects'][index]['path'] if index >= 0 else 'Navigation support', 'sourceFirstFace': metadata['objects'][index]['firstFace'] if index >= 0 else None, 'pairs': count} for index, count in lower_groups.most_common()]
        exemplar_order = indices[np.argsort(-areas[indices])[:5]]
        exemplars = []
        for i in exemplar_order:
            a, b = pairs[i]
            xy = np.array(overlap_shapes[i].representative_point().coords[0])
            exemplars.append({'upperSupportIndex': int(a), 'lowerSupportIndex': int(b), 'upperFullPackFace': int(support.source_ids[a]), 'lowerFullPackFace': int(support.source_ids[b]) if support.source_ids[b] >= 0 else None, 'lowerObject': support.objects[b], 'nativeXY': xy.tolist(), 'upperHeightMeters': float(xy @ support.planes[a, :2] + support.planes[a, 2]), 'lowerHeightMeters': float(xy @ support.planes[b, :2] + support.planes[b, 2]), 'overlapAreaMeters2': float(areas[i]), 'gapRangeMeters': [float(minima[i]), float(maxima[i])]})
        nav_examples = []
        if len(matched_samples):
            sorted_ids = np.argsort(matched_nav_z)
            for index in np.unique(sorted_ids[np.linspace(0, len(sorted_ids) - 1, min(7, len(sorted_ids))).astype(int)]):
                nav_examples.append({'nativeSourceXYZ': matched_samples[index].tolist(), 'detailedNavHeightMeters': float(matched_nav_z[index])})
        source_ids = support.source_ids[object_support]
        record = {'objectPath': object_path, 'sourceObjectIndex': object_index, 'role': 'unclassified-review-candidate', 'sourceObject': object_data, 'native': native_mesh(root, object_path, native_cache), 'admittedSupportIndices': object_support.tolist(), 'admittedFullPackFaceIds': source_ids.tolist(), 'admittedOriginalSourceFaceIds': correspondence[source_ids].tolist(), 'competingSupportIndices': upper_ids.tolist(), 'pairIndices': pair_indices, 'sourceSupportHeightRangeMeters': [float(support.points[object_support, :, 2].min()), float(support.points[object_support, :, 2].max())], 'detailedNavMatchedSamples': int(matches.sum()), 'detailedNavMatchedHeightSpanMeters': progression, 'detailedNavProgressionExamples': nav_examples, 'overlapFootprintNativeGeojson': shapely.to_geojson(footprint), 'overlapFootprintAreaUpperBoundMeters2': float(footprint.area), 'gapMaximumMeters': float(maxima[indices].max()), 'gapMinimumMeters': float(minima[indices].min()), 'stepBandPairCount': int(np.sum((maxima[indices] >= .05) & (minima[indices] <= .35))), 'entireOverlapAtLeast5cmPairCount': int(np.sum(minima[indices] >= .05)), 'lowerAssemblies': lower_groups, 'examples': exemplars}
        record['reviewPriority'] = 'rising-nav-overlap' if progression >= .25 and footprint.area >= .1 else 'low-or-local-overlap'
        records.append(record)
    records.sort(key=lambda row: (row['reviewPriority'] == 'rising-nav-overlap', row['detailedNavMatchedHeightSpanMeters'], row['overlapFootprintAreaUpperBoundMeters2']), reverse=True)
    report = {'schemaVersion': 1, 'map': name, 'productionMutation': False, 'sourceGeometrySha256': metadata['geometrySha256'], 'fullHeightSourcePackSha256': support_meta['fullHeightSourcePackSha256'], 'supportSha256': support_meta['dataSha256'], 'supportMetadataSha256': sha(support_meta_path), 'sourceSupportTriangles': source_count, 'pairFile': f'{name}.pairs.npz', 'pairSha256': sha(out / f'{name}.pairs.npz'), 'pairCount': len(pairs), 'assemblyCount': len(records), 'scope': 'Every admitted source support face whose actual buffered XY intersection with another source/nav support has positive area in the5–35cm height-gap band. Exact affine half-plane clipping bounds the band. Final diagnostic footprint unions use1e-8m coordinate precision for topology stability; source/runtime data unchanged. Detailed nav progression uses source vertices/centroids matching actual detailed nav within10cm. These are review candidates, not automatic terrain assignments.', 'records': records}
    (out / f'{name}.json').write_text(json.dumps(report, indent=2))
    print(name, 'assemblies', len(records), 'rising-nav', sum(row['reviewPriority'] == 'rising-nav-overlap' for row in records), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('maps', nargs='+')
    args = parser.parse_args()
    root = Path('E:/IcarusWorldAudit/2026-09-06')
    out = root / 'tactical-visibility-revision/competing-floor-assemblies-v3'
    out.mkdir(exist_ok=True)
    for name in args.maps:
        audit(root, name, out)
