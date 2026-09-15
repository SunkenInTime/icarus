"""Bounded empty-transit certificate using source planes and actual nav links.

This accepts only parents fully covered by one exact source plane, with source
height agreement at every detailed-nav vertex, no competing nearby source plane,
and no source blocker section at standing height. Rejected parents remain in the
general atlas. It is a conservative compiler experiment, not a full map bake.
"""
import argparse
from collections import Counter, defaultdict
from functools import reduce
import gzip
import hashlib
import json
import math
from pathlib import Path
import numpy as np
import shapely
from probe_source_floor_regressions import load_support, source_model
from probe_static_floor_sections import query_box, sections


def exact_plane_keys(points):
    """Canonical planes over the exact dyadic coordinates, with no rounding."""
    scale = max(value.as_integer_ratio()[1] for value in points.ravel())
    result = []
    for triangle in points:
        xyz = [[int(value.as_integer_ratio()[0]) * (scale // value.as_integer_ratio()[1]) for value in row] for row in triangle]
        a, b = [[xyz[j][i]-xyz[0][i] for i in range(3)] for j in [1, 2]]
        normal = [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
        values = [normal[0]*scale, normal[1]*scale, normal[2]*scale, -sum(normal[i]*xyz[0][i] for i in range(3))]
        divisor = reduce(math.gcd, values)
        if values[2] < 0:
            divisor = -divisor
        result.append(tuple(value // divisor for value in values))
    return result


def run(revision, name, center, radius):
    support = load_support(revision, name, True)
    source = source_model(revision, name, True)
    nav_path = revision / f'baseline-world/{name}_navigation.json.gz'
    nav = json.loads(gzip.decompress(nav_path.read_bytes()))
    ui = json.loads((revision / 'baseline-world/height_catalog.json').read_text())['maps'][name]['uiTransform']
    def native_xy(encoded):
        uv = np.asarray(encoded, dtype=float) / nav['coordinateScale']
        return np.c_[(uv[:, 1]-ui['YScalarToAdd'])/(100*ui['YMultiplier']), -(uv[:, 0]-ui['XScalarToAdd'])/(100*ui['XMultiplier'])]
    vertices = native_xy(np.array(nav['vertices']).reshape(-1, 3)[:, :2])
    parent_shapes = [shapely.Polygon(vertices[ring]) for ring in nav['polygons']]
    region = shapely.box(center[0]-radius, center[1]-radius, center[0]+radius, center[1]+radius)
    parents = [i for i, polygon in enumerate(parent_shapes) if nav['walkable'][i] and region.covers(polygon)]
    detail = np.array(nav['floorMesh']['triangles']).reshape(-1, 4)
    detail_parents = detail[np.array(nav['walkable'])[detail[:, 0]], 0]
    detailed_ids = support.detailed_navigation_indices
    assert len(detail_parents) == len(detailed_ids)
    local_cells = support.tree.query(region, predicate='intersects')
    local_cells = local_cells[support.source_ids[local_cells] >= 0]
    normals = np.cross(support.points[local_cells, 1]-support.points[local_cells, 0], support.points[local_cells, 2]-support.points[local_cells, 0])
    # Explicit control scope only. Source visibility is untouched.
    retained = abs(normals[:, 2]) >= .65*np.linalg.norm(normals, axis=1)
    steep_count = int((~retained).sum())
    local_cells = local_cells[retained]
    groups = defaultdict(list)
    for cell, key in zip(local_cells, exact_plane_keys(support.points[local_cells])):
        groups[key].append(int(cell))
    keys = list(groups)
    planes = np.array([[-key[0]/key[2], -key[1]/key[2], -key[3]/key[2]] for key in keys])
    footprints = np.array([shapely.union_all(support.original_polygons[groups[key]]) for key in keys], dtype=object)
    tree = shapely.STRtree(footprints)
    accepted, rejected = {}, Counter()
    for parent in parents:
        polygon = parent_shapes[parent]
        ids = tree.query(polygon, predicate='intersects')
        detail_points = support.points[detailed_ids[detail_parents == parent]].reshape(-1, 3)
        if not len(detail_points):
            rejected['no-detailed-source-backed-floor'] += 1; continue
        covering = []
        for group in ids:
            if not footprints[group].covers(polygon):
                continue
            residual = np.max(abs(detail_points[:, :2] @ planes[group, :2]+planes[group, 2]-detail_points[:, 2]))
            if residual <= .0001:
                covering.append((int(group), float(residual)))
        if len(covering) != 1:
            rejected['no-unique-exact-source-plane-cover'] += 1; continue
        group, residual = covering[0]
        competing = False
        for other in ids:
            if other == group:
                continue
            overlap = polygon.intersection(footprints[other])
            if overlap.area <= 1e-12:
                continue
            xy = shapely.get_coordinates(overlap)
            delta = np.c_[xy, np.ones(len(xy))] @ (planes[other]-planes[group])
            if delta.min() <= .350001 and delta.max() >= -.350001:
                competing = True; break
        if competing:
            rejected['other-nearby-source-plane'] += 1; continue
        xy = np.array(polygon.exterior.coords)[:-1]
        height = xy @ planes[group, :2]+planes[group, 2]+1.75
        faces = query_box(source, np.r_[xy.min(0), height.min()]-1e-8, np.r_[xy.max(0), height.max()]+1e-8)
        source_points = source.arrays['vertices'][source.arrays['faces'][faces]]
        residuals = source_points[:, :, 2]-source_points[:, :, :2]@planes[group, :2]-planes[group, 2]-1.75
        contact = False
        for triangle, values in zip(source_points, residuals):
            on = abs(values) <= 1e-10
            if on.any() and shapely.MultiPoint(triangle[on, :2]).convex_hull.intersects(polygon):
                contact = True; break
        if contact:
            rejected['standing-source-boundary-contact'] += 1; continue
        result = sections(source_points, faces, planes[group], xy)
        if result is None or len(result[0]):
            rejected['standing-source-section-present'] += 1; continue
        accepted[parent] = dict(parent=parent, sourcePlane=planes[group].tolist(), exactPlaneGroup=group,
                                sourceFaces=[int(support.source_ids[cell]) for cell in groups[keys[group]]],
                                navVertexResidualMeters=residual, polygon=shapely.to_geojson(polygon),
                                sourceSectionCount=0)
    links = np.array(nav['links']).reshape(-1, 6)
    transitions = []
    for link_index, link in enumerate(links):
        a, b = map(int, link[:2])
        if a not in accepted or b not in accepted:
            continue
        portal = native_xy(link[2:].reshape(2, 2))
        incoming, outgoing = np.array(accepted[a]['sourcePlane']), np.array(accepted[b]['sourcePlane'])
        heights = np.c_[portal, np.ones(2)] @ np.stack([incoming, outgoing]).T
        if np.max(abs(heights[:, 1]-heights[:, 0])) > .350001:
            continue
        transitions.append(dict(nativeLink=int(link_index), incomingParent=a, outgoingParent=b,
                                endpoints=portal.tolist(), incomingSourcePlane=incoming.tolist(), outgoingSourcePlane=outgoing.tolist(),
                                maximumSourceStepMeters=float(np.max(abs(heights[:, 1]-heights[:, 0])))))
    # Local sheet identity is kept even if a remote path joins stacked levels.
    owners = {parent: parent for parent in accepted}
    members = {parent: {parent} for parent in accepted}
    shapes = {parent: parent_shapes[parent] for parent in accepted}
    def owner(parent):
        while owners[parent] != parent:
            parent = owners[parent]
        return parent
    for transition in transitions:
        a, b = owner(transition['incomingParent']), owner(transition['outgoingParent'])
        if a == b or shapes[a].intersection(shapes[b]).area > 1e-10:
            continue
        owners[b] = a; members[a] |= members.pop(b); shapes[a] = shapes[a].union(shapes.pop(b))
    sheets = [dict(id=key, parents=sorted(value), footprint=shapely.to_geojson(shapes[key]),
                   outgoingTransitions=[i for i, transition in enumerate(transitions) if transition['incomingParent'] in value and transition['outgoingParent'] not in value])
              for key, value in members.items()]
    output = revision / 'sheet-transit-certificate-v1'
    output.mkdir(exist_ok=True)
    result = dict(scope=__doc__, map=name, center=center, radiusMeters=radius, examinedParents=len(parents),
                  acceptedParents=len(accepted), rejected=dict(rejected), sourcePlanes=len(keys), steepSourceSupportsOmitted=steep_count,
                  sourceSupportPolicy='Diagnostic abs(normalZ)>=0.65 gate; original visibility remains complete. No native slope-rule claim.',
                  sourcePlanePolicy='Exact dyadic source coplanarity; no coordinate or plane rounding. Every detailed nav vertex agrees within0.1mm; source plane supplies heights.',
                  sourceSha256=hashlib.sha256((revision/f'full-height-input-v1/{name}/{name}.height.bin.gz').read_bytes()).hexdigest(),
                  navSha256=hashlib.sha256(nav_path.read_bytes()).hexdigest(), parents=list(accepted.values()), transitions=transitions, sheets=sheets,
                  limitation='Bounded sufficient conditions only. Runtime must enter in the certified parent/source-plane state and retain exact exit state. General support outside these parent footprints, unknown roles, blocked cells, gaps, and raised observers remain in the original atlas.')
    (output/f'{name}.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({key:value for key,value in result.items() if key not in ['parents','transitions','sheets']}), flush=True)
    print('transitions',len(transitions),'sheets',len(sheets),'largest sheet parents',max((len(s['parents']) for s in sheets),default=0),flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('--map', default='split')
    parser.add_argument('--center', type=float, nargs=2, default=[20.599371111492427,39.59257844288108])
    parser.add_argument('--radius', type=float, default=12.)
    args=parser.parse_args();run(args.revision,args.map,args.center,args.radius)
