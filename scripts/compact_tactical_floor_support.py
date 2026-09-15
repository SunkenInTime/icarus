"""Merge coplanar floor footprints without choosing a standing-floor policy.

This is a storage experiment. It preserves each plane group's XY union, holes,
and separate heights. Its measured height error bounds interpolation everywhere
on each input triangle. It does not certify the input floor classification.
"""
import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import shapely


def compact(vertices, triangles, source_faces, height_tolerance=1e-5):
    points = vertices[triangles]
    matrices = np.concatenate([points[:, :, :2], np.ones((len(points), 3, 1))], axis=2)
    planes = np.linalg.solve(matrices, points[:, :, 2, None])[:, :, 0]
    if not np.isfinite(planes).all() or height_tolerance < 0:
        raise ValueError('Invalid source planes or tolerance')
    # Rounding only proposes groups. The explicit per-vertex gate below bounds
    # any height change; vertices and XY boundaries themselves are not rounded.
    _, group_ids = np.unique(np.round(planes, 8), axis=0, return_inverse=True)
    order = np.argsort(group_ids, kind='stable')
    groups = np.split(order, np.flatnonzero(np.diff(group_ids[order])) + 1)
    verified = []
    for group in groups:
        plane = planes[group[0]]
        predicted = points[group, :, :2] @ plane[:2] + plane[2]
        error = float(np.abs(predicted - points[group, :, 2]).max())
        if error > height_tolerance:
            verified.extend((np.array([index]), planes[index], 0.) for index in group)
        else:
            verified.append((group, plane, error))

    out_vertices, out_faces, face_groups, lookup = [], [], [], {}
    group_sources, source_offsets, out_planes = [], [0], []
    maximum_height_error = maximum_footprint_error = 0.
    input_footprint_area = output_footprint_area = 0.
    for group_id, (group, plane, height_error) in enumerate(verified):
        source_polygons = shapely.polygons(points[group, :, :2])
        footprint = shapely.union_all(source_polygons)
        if not footprint.is_valid:
            raise ValueError('Invalid source floor footprint')
        children = []
        for polygon in shapely.get_parts(footprint):
            children.extend(shapely.get_parts(shapely.constrained_delaunay_triangles(polygon)))
        reproduced = shapely.union_all(children)
        footprint_error = footprint.symmetric_difference(reproduced).area
        if footprint_error > max(1e-10, footprint.area * 1e-11):
            raise ValueError(f'Floor footprint changed by {footprint_error} square metres')
        if abs(sum(child.area for child in children) - reproduced.area) > max(1e-10, footprint.area * 1e-11):
            raise ValueError('Retriangulated floor has overlapping interiors')
        maximum_height_error = max(maximum_height_error, height_error)
        maximum_footprint_error = max(maximum_footprint_error, footprint_error)
        input_footprint_area += footprint.area
        output_footprint_area += reproduced.area
        for child in children:
            face = []
            for xy in np.asarray(child.exterior.coords)[:3]:
                xyz = (*xy, float(xy @ plane[:2] + plane[2]))
                if xyz not in lookup:
                    lookup[xyz] = len(out_vertices)
                    out_vertices.append(xyz)
                face.append(lookup[xyz])
            out_faces.append(face)
            face_groups.append(group_id)
        out_planes.append(plane)
        group_sources.extend(source_faces[group].tolist())
        source_offsets.append(len(group_sources))
    report = dict(inputTriangles=len(triangles), outputTriangles=len(out_faces),
                  inputVertices=len(vertices), outputVertices=len(out_vertices),
                  planeGroups=len(verified), heightToleranceMeters=height_tolerance,
                  maximumHeightErrorMeters=maximum_height_error,
                  maximumGroupFootprintErrorMeters2=maximum_footprint_error,
                  summedInputGroupAreaMeters2=input_footprint_area,
                  summedOutputGroupAreaMeters2=output_footprint_area)
    arrays = dict(vertices=np.asarray(out_vertices, dtype='<f8'),
                  triangles=np.asarray(out_faces, dtype='<u4'),
                  triangleGroups=np.asarray(face_groups, dtype='<u4'),
                  groupPlanes=np.asarray(out_planes, dtype='<f8'),
                  groupSourceOffsets=np.asarray(source_offsets, dtype='<u4'),
                  groupSourceFaces=np.asarray(group_sources, dtype='<i8'))
    return arrays, report


def run(source, output):
    if output.exists():
        raise ValueError('Preserving existing experiment')
    started = time.perf_counter()
    with np.load(source, allow_pickle=False) as data:
        arrays, report = compact(data['vertices'], data['triangles'], data['sourceFaces'])
    output.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(output, **arrays)
    report.update(sourceFile=str(source), sourceSha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                  sourceBytes=source.stat().st_size, outputBytes=output.stat().st_size,
                  outputSha256=hashlib.sha256(output.read_bytes()).hexdigest(),
                  elapsedSeconds=time.perf_counter() - started,
                  status='Storage experiment only; input floor classification remains unapproved')
    output.with_suffix('.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    run(args.source, args.output)
