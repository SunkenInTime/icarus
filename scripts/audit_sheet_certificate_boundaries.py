"""Read-only checks against the frozen bounded Split empty-transit output."""
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from probe_source_floor_regressions import load_support, source_model
from probe_static_floor_sections import query_box, sections


def run(revision):
    certificate_path = revision / 'sheet-transit-certificate-v1/split.json'
    certificate_bytes = certificate_path.read_bytes()
    certificate = json.loads(certificate_bytes)
    support = load_support(revision, 'split', True)
    source = source_model(revision, 'split', True)
    source_points = source.arrays['vertices'][source.arrays['faces']]
    rows = []
    for parent in certificate['parents']:
        polygon = shapely.from_geojson(parent['polygon'])
        plane = np.array(parent['sourcePlane'])
        candidates = support.tree.query(polygon, predicate='intersects')
        candidates = candidates[support.source_ids[candidates] >= 0]
        nearby_steep = []
        for cell in candidates:
            triangle = support.points[cell]
            normal = np.cross(triangle[1] - triangle[0], triangle[2] - triangle[0])
            if abs(normal[2]) >= .65 * np.linalg.norm(normal):
                continue
            overlap = polygon.intersection(support.original_polygons[cell])
            if overlap.area <= 1e-12:
                continue
            xy = shapely.get_coordinates(overlap)
            delta = np.c_[xy, np.ones(len(xy))] @ (support.planes[cell] - plane)
            if delta.min() <= .350001 and delta.max() >= -.350001:
                nearby_steep.append(dict(cell=int(cell), face=int(support.source_ids[cell]),
                                         object=support.objects[cell], overlapArea=float(overlap.area),
                                         heightDeltaRange=[float(delta.min()), float(delta.max())]))
        xy = np.array(polygon.exterior.coords)[:-1]
        heights = xy @ plane[:2] + plane[2] + 1.75
        faces = query_box(source, np.r_[xy.min(0), heights.min()] - 1e-8,
                          np.r_[xy.max(0), heights.max()] + 1e-8)
        intersections = sections(source_points[faces], faces, plane, xy)
        rows.append(dict(parent=parent['parent'], convex=polygon.equals(polygon.convex_hull),
                         hasHoles=bool(polygon.interiors), nearbyOmittedSteepSupports=nearby_steep,
                         correctedSourceSections=None if intersections is None else
                         [dict(face=face, endpoints=segment.tolist())
                          for segment, face in zip(*intersections)]))
    polygons = {p['parent']: shapely.from_geojson(p['polygon']) for p in certificate['parents']}
    parent_records = {p['parent']: p for p in certificate['parents']}
    sheets = []
    for sheet in certificate['sheets']:
        expected = shapely.union_all([polygons[i] for i in sheet['parents']])
        footprint = shapely.from_geojson(sheet['footprint'])
        sheets.append(dict(id=sheet['id'],
                           sourcePlaneCount=len({tuple(parent_records[i]['sourcePlane']) for i in sheet['parents']}),
                           symmetricDifferenceArea=float(footprint.symmetric_difference(expected).area),
                           totalParentAreaMinusUnionArea=float(sum(polygons[i].area for i in sheet['parents']) - expected.area),
                           footprintType=footprint.geom_type))
    transitions = []
    for transition in certificate['transitions']:
        line = shapely.LineString(transition['endpoints'])
        a, b = transition['incomingParent'], transition['outgoingParent']
        transitions.append(dict(link=transition['nativeLink'], parents=[a, b],
                                portalOutsideParentMeters=[float(line.difference(polygons[i]).length) for i in (a, b)],
                                endpointBoundaryDistanceMeters=[float(shapely.Point(xy).distance(polygons[i].boundary))
                                                                for i in (a, b) for xy in transition['endpoints']]))
    report = dict(certificateSha256=hashlib.sha256(certificate_bytes).hexdigest(),
                  supportSha256=hashlib.sha256((revision / 'source-floor-support-all-walkable-v1/split.floor-support.npz').read_bytes()).hexdigest(),
                  sourceSha256=certificate['sourceSha256'], parents=rows, transitions=transitions, sheets=sheets)
    output = revision / 'sheet-transit-certificate-boundary-review-v1.json'
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(report=str(output), parents=len(rows),
                          omittedNearbySteepSupports=sum(len(row['nearbyOmittedSteepSupports']) for row in rows),
                          parentsWithCorrectedSourceContacts=[row['parent'] for row in rows if row['correctedSourceSections'] is None or row['correctedSourceSections']],
                          nonconvexParents=[row['parent'] for row in rows if not row['convex']],
                          maximumPortalEndpointBoundaryDistance=max((max(row['endpointBoundaryDistanceMeters']) for row in transitions), default=0))))


if __name__ == '__main__':
    run(Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision'))
