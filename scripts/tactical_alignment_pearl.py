"""Build the audited Pearl A back-wall registration from source ray contacts."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from shapely import Point, Polygon, from_geojson, union_all

from tactical_alignment_warps import from_controls


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(args.output)
    evidence = args.audit_root / 'tactical-visibility-revision/gallery-pearl-edge35-probe-v1/source-horizontal-rays.json'
    records = json.loads(evidence.read_text())['cases']
    line = np.array([[380.455, 51.1064], [441.502, 112.156]])
    axis = line[1] - line[0]
    length = np.linalg.norm(axis)
    axis /= length
    normal = np.array([-axis[1], axis[0]])
    hits = np.array([r['sourceHorizontalHit']['hitSvg'] for r in records])
    along = (hits - line[0]) @ axis
    offset = (hits - line[0]) @ normal
    order = np.argsort(along)
    along, offset = along[order], offset[order]
    # Adjacent first/last contacts belong to the same source wall plane. Extend
    # those plane slopes to the authored endpoints; keep the arch join local.
    start = offset[0] - along[0] * (offset[1] - offset[0]) / (along[1] - along[0])
    end = offset[-1] + (length - along[-1]) * (offset[-1] - offset[-2]) / (along[-1] - along[-2])
    knots = np.r_[0., along, length]
    profile = np.r_[start, offset, end]
    ts = np.unique(np.r_[-3., knots, np.arange(0., length, 2.), length + 3.])
    points, delta = [], []
    for t in ts:
        height = np.interp(t, knots, profile)
        for n in [-5., height, 5.]:
            points.append(line[0] + t * axis + n * normal)
            delta.append(-height * normal if n == height and 0 <= t <= length else np.zeros(2))
    patch = Polygon([line[0] + t * axis + n * normal for t, n in [(-3, -5), (length + 3, -5), (length + 3, 5), (-3, 5)]])
    sides = json.loads((args.audit_root / 'tactical-alignment-sides-v1/pearl.json').read_text())
    box = sides['attackViewBox']
    lattice = np.array([(x, y) for x in np.arange(-100, box[2] + 125, 20)
                        for y in np.arange(-100, box[3] + 125, 20)])
    fixed = [p for p in lattice if not patch.buffer(1e-7).covers(Point(p))]
    points.extend(fixed)
    delta.extend(np.zeros((len(fixed), 2)))
    warp = from_controls(points, delta)
    scope = json.loads((args.audit_root / 'compact-prototype/all-map-svg-foliage-v2/pearl/scope.json').read_text())
    hull = from_geojson(scope['nativeObserverReceiverHull'])
    affine = np.array(sides['nativeToAttackSvg'])
    inverse = np.linalg.inv(affine[:, :2])
    active = np.any(np.linalg.norm(warp.delta[warp.tri.simplices], axis=2) > 0, axis=1)
    cells = (warp.points[warp.tri.simplices[active]] - affine[:, 2]) @ inverse.T
    support = union_all([Polygon(cell) for cell in cells])
    interior_support = hull.contains(support)
    # This facade is on the outer map boundary. Its outward correction may
    # expand the retained domain, which is safe if the complete original
    # observer/receiver hull remains covered by the transformed source domain.
    domain_svg = Polygon(np.array(hull.exterior.coords) @ affine[:, :2].T + affine[:, 2])
    active_svg = [Polygon(cell) for cell in warp.points[warp.tri.simplices[active]]]
    pieces = [domain_svg.difference(union_all(active_svg))]
    for cell in active_svg:
        part = cell.intersection(domain_svg)
        if part.is_empty or part.area == 0:
            continue
        polygons = [part] if part.geom_type == 'Polygon' else list(part.geoms)
        for polygon in polygons:
            if polygon.geom_type == 'Polygon':
                pieces.append(Polygon(warp.apply(np.array(polygon.exterior.coords))))
    transformed_scope = union_all(pieces)
    omitted = domain_svg.difference(transformed_scope.buffer(1e-9))
    if not omitted.is_empty:
        raise ValueError(f'Pearl inverse receiver scope not retained: {omitted.area} SVG squared')
    expected = hits - ((hits - line[0]) @ normal)[:, None] * normal
    error = float(np.linalg.norm(warp.apply(hits) - expected, axis=1).max())
    if error > 1e-8 or warp.jacobians.min() <= .5 or warp.jacobians.max() >= 2:
        raise ValueError(f'Pearl correspondence failed: {error}, {warp.jacobians.min()}, {warp.jacobians.max()}')
    args.output.mkdir(parents=True)
    np.savez_compressed(args.output / 'warp.npz', points=warp.points,
                        displacements=warp.delta, triangles=warp.tri.simplices)
    report = {'map': 'pearl', 'adopted': False, 'svgLineId': 35,
              'sourceEvidence': str(evidence), 'sourceEvidenceSha256': hashlib.sha256(evidence.read_bytes()).hexdigest(),
              'sourceObjects': sorted(set(r['sourceHorizontalHit']['sourceObject'] for r in records)),
              'sourceContactResidualSvg': error, 'minimumCellJacobian': float(warp.jacobians.min()),
              'maximumCellJacobian': float(warp.jacobians.max()),
              'activeSupportInsideOldScope': interior_support,
              'originalHullCoveredByTransformedSourceHull': True,
              'activeSupportClearanceMeters': float(support.distance(hull.boundary)),
              'profileAlongSvg': knots.tolist(), 'profileOffsetSvg': profile.tolist(),
              'unchanged': 'Edge 78 and all geometry outside the bounded edge 35 patch',
              'limits': 'Candidate requires receiver-masked after renders and end/corner probes before adoption.'}
    (args.output / 'candidate.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
