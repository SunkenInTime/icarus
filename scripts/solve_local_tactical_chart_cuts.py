"""Find independent overpass chart cuts with receiver-visible agreement.

Each bit is solved against the worst result for every other chart bit. A zero
cost result therefore cannot hide disagreement behind another region's label.
"""
import argparse
import gzip
import json
from pathlib import Path
import subprocess
import re
import numpy as np
import shapely
from shapely.affinity import affine_transform
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import maximum_flow
from build_global_tactical_candidate import GroundField
from audit_tactical_target_rays import ReferenceModel
from tactical_alignment_receiver import receiver_domain


def mincut(count, edges, errors, seeds, components, main):
    capacities = np.where(errors <= .01, 1, 10000 + np.ceil(errors * 100)).astype(np.int64)
    rows, columns, values = [], [], []
    for (a, b), capacity in zip(edges, capacities):
        rows.extend([a, b]); columns.extend([b, a]); values.extend([capacity, capacity])
    for side in (0, 1):
        for parent in seeds[side]:
            rows.append(count if side == 0 else parent)
            columns.append(parent if side == 0 else count + 1)
            values.append(100000000)
    graph = csr_matrix((values, (rows, columns)), shape=(count + 2, count + 2), dtype=np.int64)
    flow = maximum_flow(graph, count, count + 1)
    residual = (graph - flow.flow).tocsr()
    reached, pending = {count}, [count]
    while pending:
        node = pending.pop()
        for offset in range(residual.indptr[node], residual.indptr[node + 1]):
            neighbor = int(residual.indices[offset])
            if residual.data[offset] > 0 and neighbor not in reached:
                reached.add(neighbor); pending.append(neighbor)
    labels = np.array([int(i not in reached and components[i] == main) for i in range(count)])
    cuts = [dict(parents=list(edge), maximumRayDifferenceMeters=float(error))
            for edge, error in zip(edges, errors) if labels[edge[0]] != labels[edge[1]]]
    return labels, cuts


def solve(revision, name, directions=64, exclude_ground_surfaces=False):
    output = revision / 'local-ground-charts-v1' / name
    manifest = json.loads((output / 'manifest.json').read_text())
    previous = json.loads((revision / 'sheet-selection-v1' / f'{name}.json').read_text())
    nav = json.loads(gzip.decompress((revision / 'baseline-world' / f'{name}_navigation.json.gz').read_bytes()))
    base = GroundField(revision / 'global-ground-v1' / f'{name}.tactical-ground.json.gz')
    main = base.data['mainComponent']
    edges, seen = [], set()
    for row in np.array(nav['links']).reshape(-1, 6):
        a, b = int(row[0]), int(row[1])
        edge = tuple(sorted((a, b)))
        if edge not in seen and nav['components'][a] == main and nav['components'][b] == main:
            seen.add(edge); edges.append(edge)
    poses = np.fromfile(revision / 'sheet-selection-mincut-v1' / name / 'lower.queries.f64', dtype='<f8').reshape(-1, 3)
    if len(poses) != 2 * len(edges):
        raise ValueError('Cached portal query topology differs')
    poses[:, 2] += base.heights(poses[:, :2])
    source = ReferenceModel(revision / 'full-height-input-v1' / name / f'{name}.height.bin.gz')
    excluded_source = None
    suffix = '-ground-surfaces-excluded' if exclude_ground_surfaces else ''
    if exclude_ground_surfaces:
        rows = json.loads((revision.parent / 'completeness/combined-manifest-release-inputs-v2.json').read_text())
        world = Path(next(row for row in rows if row['map'] == name)['combinedWorldFolder'])
        objects = json.loads((world / 'geometry.json').read_text())['objects']
        starts = np.array([obj['firstFace'] for obj in objects])
        ids = np.load(revision / 'full-height-input-v1' / name / 'source-correspondence.npz')['sourceFaces']
        object_ids = np.searchsorted(starts, ids, side='right') - 1
        source_objects = np.array([bool(re.search(r'floor|stair|ramp|platform', obj['path'], re.I)) for obj in objects])
        triangles = source.arrays['vertices'][source.arrays['faces']]
        normals = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
        length = np.linalg.norm(normals, axis=1)
        excluded_source = source_objects[object_ids] & (np.abs(normals[:, 2]) >= .7 * np.maximum(length, 1e-15))
    results = []
    for chart in manifest['charts']:
        folder = output / str(chart['mask'])
        field = GroundField(chart['field'])
        values = poses.copy(); values[:, 2] -= field.heights(values[:, :2])
        query, rays = folder / 'portals.queries.f64', folder / f'portals.{directions}{suffix}.rays.f64'
        encoded = values.astype('<f8').tobytes()
        if not (query.exists() and query.read_bytes() == encoded and rays.exists() and rays.stat().st_size == len(values) * directions * 8):
            query.write_bytes(encoded)
            native_folder = revision / 'global-ground-complete-v2' / name / 'native' if chart['mask'] == 0 else folder / 'native'
            command = [str(revision / 'native-tactical-rays-build/Release/tactical_rays.exe'), str(native_folder), str(query), str(rays), str(directions), '65']
            if excluded_source is not None:
                source_ids = np.load(native_folder.parent / 'correspondence.npz')['sourceFaces']
                mask_path = folder / 'excluded-ground-surfaces.u8'
                excluded_source[source_ids].astype('u1').tofile(mask_path)
                command.append(str(mask_path))
            subprocess.run(command, check=True)
        results.append(np.fromfile(rays, dtype='<f8').reshape(-1, directions))
    side_data = json.loads((revision.parent / 'tactical-alignment-sides-v1' / f'{name}.json').read_text())
    receivers = []
    for side in ('attack', 'defense'):
        matrix = np.array(side_data['nativeToAttackSvg' if side == 'attack' else 'nativeToDefenseSvg'])
        inverse = np.linalg.inv(matrix[:, :2]); shift = -inverse @ matrix[:, 2]
        shape = receiver_domain(Path(f'assets/maps/{name}_map{"_defense" if side == "defense" else ""}.svg'))
        receivers.append(affine_transform(shape, [*inverse[0], *inverse[1], *shift]))
    receiver = shapely.union_all(receivers).buffer(.002)
    region_reports, combined = [], np.zeros(len(nav['polygons']), dtype=int)
    for region in manifest['regions']:
        bit = 1 << region['index']
        errors = np.zeros((len(poses), directions))
        for mask in range(len(results)):
            if mask & bit:
                continue
            pair = [results[mask], results[mask | bit]]
            rows, directions_ids = np.where(np.abs(pair[0] - pair[1]) > .01)
            angles = directions_ids * 2 * np.pi / directions
            vectors = np.c_[np.cos(angles), np.sin(angles)]
            endpoints = np.stack([poses[rows, :2] + vectors * values[rows, directions_ids, None] for values in pair], axis=1)
            lengths = shapely.length(shapely.intersection(shapely.linestrings(endpoints), receiver))
            errors[rows, directions_ids] = np.maximum(errors[rows, directions_ids], lengths)
        seeds = [set(), set()]
        rejected = []
        bounds = shapely.box(*region['bounds']).buffer(.11)
        for cell in previous['overlapCells']:
            xy = cell['point']; levels = cell['levels']
            if len(levels) < 2 or levels[-1][0] - levels[0][0] <= 1.75 or not bounds.covers(shapely.Point(xy)):
                continue
            # A floor label alone does not prove a standing observer fits.
            hits = [source.cast([*xy, level[0] + .05], [*xy, level[0] + 1.75]) for level in (levels[0], levels[-1])]
            if any(hit is not None for hit in hits):
                rejected.append(dict(point=xy, levels=levels, hits=hits)); continue
            for side, level in enumerate((levels[0], levels[-1])):
                seeds[side].update(level[1])
        if not all(seeds) or seeds[0] & seeds[1]:
            raise ValueError('Missing or contradictory standing-overlap seeds')
        maximum = errors.reshape(len(edges), 2, directions).max(axis=(1, 2))
        labels, cuts = mincut(len(nav['polygons']), edges, maximum, seeds, nav['components'], main)
        combined |= labels * bit
        region_reports.append(dict(region=region['index'], lowerSeedParents=sorted(seeds[0]), upperSeedParents=sorted(seeds[1]),
                                   rejectedStandingCells=rejected, parentBitValues=labels.tolist(), cuts=cuts,
                                   maximumCutDisagreementMeters=max((c['maximumRayDifferenceMeters'] for c in cuts), default=0)))
    report = dict(map=name, parentVariants=combined.tolist(), regions=region_reports,
                  evaluatedPortals=len(edges), directionsPerPose=directions,
                  maximumCutDisagreementMeters=max(r['maximumCutDisagreementMeters'] for r in region_reports),
                  policy='Independent region cuts, weighted by worst receiver-visible disagreement over other chart bits. Dense final transition validation remains required.')
    report['excludedSurfacePolicy'] = 'DIAGNOSTIC ONLY: source floor/stair/ramp/platform objects, abs(original normal.z)>=0.7. Vertical fronts and all other objects retained.' if exclude_ground_surfaces else None
    (output / f'selection-{directions}{suffix}.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(map=name, maximumCutDisagreementMeters=report['maximumCutDisagreementMeters'],
                         regions=[dict(region=r['region'], cuts=len(r['cuts']), rejectedCells=len(r['rejectedStandingCells']), maximum=r['maximumCutDisagreementMeters']) for r in region_reports])), flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('map')
    parser.add_argument('--directions', type=int, default=64)
    parser.add_argument('--exclude-ground-surfaces', action='store_true')
    args = parser.parse_args()
    solve(args.revision, args.map, args.directions, args.exclude_ground_surfaces)
