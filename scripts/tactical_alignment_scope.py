"""Prove old source retention remains valid under side registration and local W."""
import argparse
import gzip
import json
from pathlib import Path
import xml.etree.ElementTree as ET

import numpy as np
from shapely import Polygon, MultiPoint, from_geojson, points, distance, union_all
from svgpathtools import parse_path, Line, CubicBezier, QuadraticBezier, Arc

from tactical_alignment_candidate import Warp


def controls(path):
    document = ET.parse(path)
    root = document.getroot()
    parents = {child: parent for parent in root.iter() for child in parent}
    result = []
    for element in root.iter():
        if not element.tag.endswith('path') or element.get('fill', '').lower() != '#271406':
            continue
        ancestor = element
        while ancestor is not None:
            if 'transform' in ancestor.attrib or 'style' in ancestor.attrib:
                raise ValueError('Transformed receiver requires explicit handling')
            ancestor = parents.get(ancestor)
        for segment in parse_path(element.get('d')):
            values = [segment.start, segment.end]
            if isinstance(segment, CubicBezier): values += [segment.control1, segment.control2]
            elif isinstance(segment, QuadraticBezier): values += [segment.control]
            elif isinstance(segment, Arc):
                x0, x1, y0, y1 = segment.bbox()
                values += [complex(x0, y0), complex(x0, y1), complex(x1, y0), complex(x1, y1)]
            elif not isinstance(segment, Line): raise ValueError('Unsupported SVG segment')
            result.extend([[v.real, v.imag] for v in values])
    return np.array(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    names = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']
    reports = []
    for name, catalog in names.items():
        scope = json.loads((args.audit_root / f'compact-prototype/all-map-svg-foliage-v2/{name}/scope.json').read_text())
        old_hull = from_geojson(scope['nativeObserverReceiverHull'])
        sides = json.loads((args.audit_root / f'tactical-alignment-sides-v1/{name}.json').read_text())
        receiver_points = []
        for side in ['attack', 'defense']:
            affine = np.array(sides['nativeToAttackSvg' if side == 'attack' else 'nativeToDefenseSvg'])
            source = controls(Path(f'assets/maps/{name}_map{"_defense" if side == "defense" else ""}.svg'))
            receiver_points.extend((source - affine[:, 2]) @ np.linalg.inv(affine[:, :2]).T)
        nav = json.loads(gzip.decompress(Path(f'assets/maps/world/{name}_navigation.json.gz').read_bytes()))
        vertex_ids = np.unique(np.concatenate([p for p, allowed in zip(nav['polygons'], nav['walkable']) if allowed]))
        uv = np.array(nav['vertices']).reshape(-1, 3)[vertex_ids, :2] / nav['coordinateScale']
        ui = catalog['uiTransform']
        observers = np.column_stack(((uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier']),
                                     -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])))
        proposed = MultiPoint(np.vstack((receiver_points, observers))).convex_hull
        outside = float(np.max(distance(points(np.array(proposed.exterior.coords)), old_hull)))
        boundary_clearance = float(np.min(distance(points(np.array(proposed.exterior.coords)), old_hull.boundary)))
        report = {'map': name, 'maximumNewHullVertexOutsideOldScopeMeters': outside,
                  'newHullVertexBoundaryClearanceMeters': boundary_clearance,
                  'newSideReceiversAndOriginalObserversInsideOldScope': bool(old_hull.covers(proposed)),
                  'warp': 'identity', 'requiredConservativeExpansionMeters': outside}
        if name == 'split':
            warp = Warp()
            affine = np.array(sides['nativeToAttackSvg'])
            inverse = np.linalg.inv(affine[:, :2])
            active = np.any(np.linalg.norm(warp.delta[warp.tri.simplices], axis=2) > 0, axis=1)
            cells = (warp.points[warp.tri.simplices[active]] - affine[:, 2]) @ inverse.T
            support = union_all([Polygon(cell) for cell in cells])
            displacement = float(np.linalg.norm(warp.delta @ inverse.T, axis=1).max())
            inside_support = bool(old_hull.contains(support))
            report.update({'warp': 'split-local-structural-alignment-v1',
                           'maximumWarpDisplacementMeters': displacement,
                           'entireActiveWarpCellSupportStrictlyInsideOldScope': inside_support,
                           'activeSupportBoundaryClearanceMeters': float(support.distance(old_hull.boundary)),
                           'minimumWarpCellJacobian': float(warp.jacobians.min()),
                           'requiredConservativeExpansionMeters': outside if inside_support else outside + displacement,
                           'proof': 'W is a continuous orientation-preserving piecewise-affine homeomorphism, identity on/outside the old convex hull when all active cells are strictly interior. Therefore W(H)=H and W^-1(H)=H: all corrected receiver/observer segments and their source preimages stay inside retained H.'})
        reports.append(report)
        print(json.dumps(report), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(reports, indent=2))


if __name__ == '__main__':
    main()
