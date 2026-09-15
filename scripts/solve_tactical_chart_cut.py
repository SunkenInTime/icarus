"""Place static chart changes at nav portals where both visibility results agree."""
import argparse
import gzip
import json
from pathlib import Path
import subprocess
import numpy as np
import shapely
from shapely.affinity import affine_transform
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import maximum_flow
from build_global_tactical_candidate import GroundField
from tactical_alignment_receiver import receiver_domain


def solve(revision, name, directions=64):
    nav = json.loads(gzip.decompress((revision / 'baseline-world' / (name + '_navigation.json.gz')).read_bytes()))
    previous = json.loads((revision / 'sheet-selection-v1' / (name + '.json')).read_text())
    ui = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps'][name]['uiTransform']
    def convert(points, scale):
        out = np.array(points, dtype=float).reshape(-1, 3)
        uv = out[:, :2] / scale
        out[:, 0] = (uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier'])
        out[:, 1] = -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])
        out[:, 2] /= 100
        return out
    vertices = convert(nav['vertices'], nav['coordinateScale'])
    vertices[:, 2] = np.array(nav['refinedFloorHeightsCm']) / 100
    detail = nav['floorMesh']
    detail_vertices = convert(detail['vertices'], detail['coordinateScale'])
    detail_faces = np.array(detail['triangles']).reshape(-1, 4)
    detail_triangles = detail_vertices[detail_faces[:, 1:]]
    detail_shapes = shapely.polygons(detail_triangles[:, :, :2])
    detail_tree = shapely.STRtree(detail_shapes)
    coarse_faces = np.array(nav['triangles']).reshape(-1, 4)
    def floor_height(parent, xy):
        near = detail_tree.query(shapely.Point(xy), predicate='intersects')
        near = near[detail_faces[near, 0] == parent]
        tri_list = detail_triangles[near]
        if not len(tri_list):
            tri_list = vertices[coarse_faces[coarse_faces[:, 0] == parent, 1:]]
        values = []
        for tri in tri_list:
            shape = shapely.Polygon(tri[:, :2])
            if shape.area > 1e-12 and shape.buffer(1e-8).covers(shapely.Point(xy)):
                values.append(float(np.r_[xy, 1] @ np.linalg.solve(np.c_[tri[:, :2], np.ones(3)], tri[:, 2])))
        if not values:
            raise ValueError('No floor at portal approach')
        return max(values)
    lower = GroundField(revision / 'global-ground-v1' / (name + '.tactical-ground.json.gz'))
    upper = GroundField(revision / 'upper-ground-v2' / (name + '.tactical-ground.json.gz'))
    main = lower.data['mainComponent']
    centers = np.array([vertices[p].mean(0) for p in nav['polygons']])
    links = np.array(nav['links']).reshape(-1, 6)
    edges, poses = [], []
    seen = set()
    for row in links:
        a, b = int(row[0]), int(row[1])
        edge = tuple(sorted((a, b)))
        if edge in seen or nav['components'][a] != main or nav['components'][b] != main:
            continue
        seen.add(edge)
        uv = (row[2:4] + row[4:6]) / (2 * nav['coordinateScale'])
        midpoint = np.array([(uv[1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier']),
                             -(uv[0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])])
        for parent in edge:
            xy = midpoint * .98 + centers[parent, :2] * .02
            poses.append([*xy, floor_height(parent, xy) + 1.75])
        edges.append(edge)
    poses = np.array(poses)
    output = revision / 'sheet-selection-mincut-v1' / name
    output.mkdir(parents=True, exist_ok=True)
    native = revision / 'native-tactical-rays-build/Release/tactical_rays.exe'
    results = []
    for chart, field, folder in [('lower', lower, revision / 'global-ground-complete-v2' / name / 'native'),
                                 ('upper', upper, revision / 'upper-ground-complete-v2' / name / 'native')]:
        values = poses.copy()
        values[:, 2] -= field.heights(values[:, :2])
        input_path, target = output / (chart + '.queries.f64'), output / (chart + '.rays.f64')
        encoded = values.astype('<f8').tobytes()
        if not (input_path.exists() and input_path.read_bytes() == encoded and target.exists() and target.stat().st_size == len(values) * directions * 8):
            input_path.write_bytes(encoded)
            subprocess.run([str(native), str(folder), str(input_path), str(target), str(directions), '65'], check=True)
        results.append(np.fromfile(target, dtype='<f8').reshape(-1, directions))
    errors = np.abs(results[0] - results[1]).reshape(len(edges), 2, directions)
    raw_maximum_errors = errors.max(axis=(1, 2))
    side_data = json.loads((revision.parent / 'tactical-alignment-sides-v1' / (name + '.json')).read_text())
    receiver_shapes = []
    for side in ('attack', 'defense'):
        matrix = np.array(side_data['nativeToAttackSvg' if side == 'attack' else 'nativeToDefenseSvg'])
        inverse = np.linalg.inv(matrix[:, :2])
        shift = -inverse @ matrix[:, 2]
        shape = receiver_domain(Path(f'assets/maps/{name}_map{"_defense" if side == "defense" else ""}.svg'))
        receiver_shapes.append(affine_transform(shape, [*inverse[0], *inverse[1], *shift]))
    receiver = shapely.union_all(receiver_shapes).buffer(.002)
    visible_errors = np.zeros_like(errors).reshape(-1, directions)
    changed_rows, changed_directions = np.where(np.abs(results[0] - results[1]) > .01)
    angles = changed_directions * 2 * np.pi / directions
    vectors = np.c_[np.cos(angles), np.sin(angles)]
    endpoints = np.stack([poses[changed_rows, :2] + vectors * values[changed_rows, changed_directions, None]
                          for values in results], axis=1)
    exposed_lengths = shapely.length(shapely.intersection(shapely.linestrings(endpoints), receiver))
    visible_errors[changed_rows, changed_directions] = exposed_lengths
    maximum_errors = visible_errors.reshape(len(edges), 2, directions).max(axis=(1, 2))
    capacities = np.where(maximum_errors <= .01, 1, 10000 + np.ceil(maximum_errors * 100)).astype(np.int64)
    count = len(nav['polygons'])
    source, sink = count, count + 1
    rows, columns, values = [], [], []
    for (a, b), capacity in zip(edges, capacities):
        rows.extend([a, b]); columns.extend([b, a]); values.extend([capacity, capacity])
    for parent in previous['lowerSeedParents']:
        rows.append(source); columns.append(parent); values.append(100000000)
    for parent in previous['upperSeedParents']:
        rows.append(parent); columns.append(sink); values.append(100000000)
    graph = csr_matrix((values, (rows, columns)), shape=(count + 2, count + 2), dtype=np.int64)
    flow = maximum_flow(graph, source, sink)
    residual = (graph - flow.flow).tocsr()
    reachable, stack = {source}, [source]
    while stack:
        node = stack.pop()
        for offset in range(residual.indptr[node], residual.indptr[node + 1]):
            neighbor = int(residual.indices[offset])
            if residual.data[offset] > 0 and neighbor not in reachable:
                reachable.add(neighbor); stack.append(neighbor)
    labels = [int(i not in reachable and nav['components'][i] == main) for i in range(count)]
    cuts = [dict(parents=list(edge), capacity=int(capacity), maximumRayDifferenceMeters=float(error), maximumUnclippedRayDifferenceMeters=float(raw_maximum_errors[index]),
                 poses=poses[index * 2:index * 2 + 2].tolist(), centers=centers[list(edge)].tolist())
            for index, (edge, capacity, error) in enumerate(zip(edges, capacities, maximum_errors)) if labels[edge[0]] != labels[edge[1]]]
    report = dict(map=name, parentVariants=labels, lowerSeedParents=previous['lowerSeedParents'], upperSeedParents=previous['upperSeedParents'],
                  variantBoundaryPortals=cuts, evaluatedPortals=len(edges), directionsPerPose=directions, rangeMeters=65,
                  flowValue=int(flow.flow_value), zeroDisagreementCutFound=all(c['maximumRayDifferenceMeters'] <= .01 for c in cuts),
                  maximumCutDisagreementMeters=max((c['maximumRayDifferenceMeters'] for c in cuts), default=0),
                  receiverDomainPolicy='Union of both actual SVG side fills, expanded2mm for curve-boundary uncertainty. Local XY warp not yet applied.',
                  policy='Minimum cut weighted by source-backed native visible-receiver agreement at both standing portal approaches; selected cuts require denser validation.')
    (output / 'selection.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k not in ('parentVariants', 'lowerSeedParents', 'upperSeedParents', 'variantBoundaryPortals')}), flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('map')
    parser.add_argument('--directions', type=int, default=64)
    args = parser.parse_args()
    solve(args.revision, args.map, args.directions)
