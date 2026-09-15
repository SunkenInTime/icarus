"""Build reversible, nonoverlapping local facade warp candidates for review."""
import argparse
import json
from pathlib import Path

import numpy as np
from scipy.spatial import Delaunay
from shapely import Polygon, Point, from_geojson, union_all

from tactical_alignment_candidate import Warp


def from_controls(points, delta):
    warp = object.__new__(Warp)
    warp.points, warp.delta = np.asarray(points), np.asarray(delta)
    warp.tri = Delaunay(warp.points)
    source = warp.points[warp.tri.simplices]
    target = source + warp.delta[warp.tri.simplices]
    cross = lambda a: (a[:, 1, 0] - a[:, 0, 0]) * (a[:, 2, 1] - a[:, 0, 1]) - (a[:, 1, 1] - a[:, 0, 1]) * (a[:, 2, 0] - a[:, 0, 0])
    warp.jacobians = cross(target) / cross(source)
    return warp


def load_warp(path):
    data = np.load(path)
    if 'explicitTriangles' in data:
        from tactical_alignment_composite import explicit_warp
        return explicit_warp(data['points'], data['displacements'], data['triangles'])
    return from_controls(data['points'], data['displacements'])


def build(name, root, output):
    report = json.loads((root / f'tactical-alignment-correspondences-v2/{name}.json').read_text())
    sides = json.loads((root / f'tactical-alignment-sides-v1/{name}.json').read_text())
    old_scope = json.loads((root / f'compact-prototype/all-map-svg-foliage-v2/{name}/scope.json').read_text())
    hull = from_geojson(old_scope['nativeObserverReceiverHull'])
    affine = np.array(sides['nativeToAttackSvg'])
    inverse = np.linalg.inv(affine[:, :2])
    box = sides['attackViewBox']
    accepted, patches, control_points, control_delta = [], [], [], []
    for record in report['records']:
        record['warpSelectionFlags'] = list(record['flags'])
        if record['flags']:
            continue
        line = np.array(record['sourceLineSvg'])
        displacement = np.array(record['displacementSvg'])
        axis = (line[1] - line[0]) / np.linalg.norm(line[1] - line[0])
        normal = np.array([-axis[1], axis[0]])
        length = np.linalg.norm(line[1] - line[0])
        outline = np.array([line[0] + x * axis + y * normal for x, y in [(-3, -5), (length + 3, -5), (length + 3, 5), (-3, 5)]])
        patch = Polygon(outline)
        native_patch = Polygon((outline - affine[:, 2]) @ inverse.T)
        if any(patch.intersects(p.buffer(1)) for p in patches):
            record['warpSelectionFlags'].append('overlapping-local-patch')
            continue
        if not hull.contains(native_patch.buffer(1)):
            record['warpSelectionFlags'].append('insufficient-source-scope-clearance')
            continue
        # Dense fixed guard edges isolate the affine displacement from neighboring
        # structures. Along the entire confirmed plane, every control moves equally.
        xs = np.unique(np.r_[-3, 0, np.arange(0, length, 2), length, length + 3])
        ys = [-5, 0, 5]
        points = np.array([line[0] + x * axis + y * normal for x in xs for y in ys])
        delta = np.array([displacement if y == 0 and 0 <= x <= length else np.zeros(2) for x in xs for y in ys])
        control_points.extend(points)
        control_delta.extend(delta)
        patches.append(patch)
        accepted.append(record)
    # Fixed outer lattice makes the map identity away from reviewed patches.
    lattice = np.array([(x, y) for x in np.arange(-100, box[2] + 125, 20)
                        for y in np.arange(-100, box[3] + 125, 20)])
    admitted = [p for p in lattice if not any(patch.buffer(1e-7).covers(Point(p)) for patch in patches)]
    control_points.extend(admitted)
    control_delta.extend(np.zeros((len(admitted), 2)))
    points, delta = np.array(control_points), np.array(control_delta)
    _, ids = np.unique(np.round(points, 9), axis=0, return_index=True)
    points, delta = points[ids], delta[ids]
    warp = from_controls(points, delta)
    active = np.any(np.linalg.norm(warp.delta[warp.tri.simplices], axis=2) > 0, axis=1)
    active_native = (warp.points[warp.tri.simplices[active]] - affine[:, 2]) @ inverse.T
    support = union_all([Polygon(cell) for cell in active_native])
    scope_safe = support.is_empty or hull.contains(support)
    errors = []
    for record in accepted:
        source, target = np.array(record['sourceLineSvg']), np.array(record['targetLineSvg'])
        t = np.linspace(0, 1, 101)[:, None]
        before, expected = source[0] * (1 - t) + source[1] * t, target[0] * (1 - t) + target[1] * t
        error = float(np.linalg.norm(warp.apply(before) - expected, axis=1).max())
        record['maximumConstraintResidualSvg'] = error
        errors.append(error)
    gate = bool(warp.jacobians.min() > .5 and warp.jacobians.max() < 2 and scope_safe and max(errors, default=0) < .001)
    report.update({'format': 'icarus-local-warp-review-candidate-v1', 'selectedConstraints': len(accepted),
        'minimumCellJacobian': float(warp.jacobians.min()), 'maximumCellJacobian': float(warp.jacobians.max()),
        'maximumControlDisplacementSvg': float(np.linalg.norm(delta, axis=1).max()),
        'maximumControlDisplacementMeters': float(np.linalg.norm(delta @ inverse.T, axis=1).max()),
        'maximumConstraintResidualSvg': max(errors, default=0), 'activeSupportInsideOldScope': scope_safe,
        'activeSupportClearanceMeters': float(support.distance(hull.boundary)) if not support.is_empty else None,
        'gatesPassed': gate, 'selected': accepted,
        'policy': 'Existing conservative correspondence gates plus disjoint 5SVG guard patches, fixed outside lattice, >0.5/<2 Jacobian, <.001SVG constraint error, old scope containment. Still requires source/visual review.'})
    folder = output / name
    folder.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(folder / 'warp.npz', points=warp.points, displacements=warp.delta, triangles=warp.tri.simplices)
    (folder / 'candidate.json').write_text(json.dumps(report, indent=2))
    print(name, len(accepted), gate, report['minimumCellJacobian'], report['maximumConstraintResidualSvg'], flush=True)
    return {k: v for k, v in report.items() if k not in ['records', 'selected']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    names = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']
    summaries = [build(name, args.audit_root, args.output) for name in names]
    (args.output / 'summary.json').write_text(json.dumps(summaries, indent=2))


if __name__ == '__main__':
    main()
