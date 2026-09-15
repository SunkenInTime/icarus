"""Measure Tube floor contacts and capsule clearance without opening a candidate."""
from collections import defaultdict
import json
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import shapely
from shapely.affinity import translate

from audit_all_map_gameplay_levels import ROOT, read, planes
from build_all_map_gameplay_supports import standing_obstacles
from compile_icebox_ramp_ground import sha
from gameplay_standing_volumes import walkable_slope_angle, collision_parts


def measure(source_dir=Path('work/icebox-all-v2'), svg_points=None, output_name='tube-source-levels.json'):
    if svg_points is None:
        svg_points = [[185., y] for y in [175., 195., 215., 225., 232., 235., 245., 250., 255.]]
    rows_path = source_dir/'source-colliders.json'
    archive_path = source_dir/'source-colliders.npz'
    rows = read(rows_path)
    assert read(source_dir/'collision-accounting.json')['allSceneColliders']
    assert not read(source_dir/'collision-accounting.json')['unresolved']
    with np.load(archive_path) as archive:
        triangles = [archive[str(i)] for i in range(len(rows))]
    bounds = np.asarray([r['bounds'] for r in rows])
    # All bodies use their actual oriented triangle boundary here, including
    # solid containment. This is a separate point check of the volume solver.
    volumes = SimpleNamespace(rows=rows, triangles=triangles, equations=[None]*len(rows),
        tree=shapely.STRtree(shapely.box(bounds[:, 0, 0], bounds[:, 0, 1], bounds[:, 1, 0], bounds[:, 1, 1])))
    alignment_path = ROOT/'tactical-alignment-sides-v1/icebox.json'
    alignment = read(alignment_path)
    matrix = np.asarray(alignment['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    path_points = np.array([inverse @ (np.array(svg)-matrix[:, 2]) for svg in svg_points])
    relevant = volumes.tree.query(shapely.MultiPoint(path_points).convex_hull.buffer(.42))
    oriented = []
    for index in relevant:
        tri = triangles[index]
        certified = collision_parts({'CollisionTraceFlag': 'CTF_UseComplexAsSimple'}, tri, np.eye(4))
        if certified[0][1] is not None:
            # Qhull's native-volume simplices have arbitrary winding. The main
            # domain audit uses their outward equations. Orient the same source
            # face coordinates before this independent triangle-boundary check.
            center = tri.reshape(-1, 3).mean(0)
            normals = np.cross(tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0])
            reverse = np.einsum('ij,ij->i', normals, tri.mean(1)-center) < 0
            tri = tri.copy()
            tri[reverse] = tri[reverse][:, [0, 2, 1]]
            triangles[index] = tri
            oriented.append(rows[index]['id'])
    results = []
    for svg in svg_points:
        svg = np.array(svg)
        xy = inverse @ (svg-matrix[:, 2])
        point = shapely.Point(xy)
        candidates = defaultdict(list)
        for index in volumes.tree.query(point.buffer(.42)):
            row, tri = rows[index], triangles[index]
            if row['unwalkable'] or row['kill'] or row.get('collisionDefaultsUnknown'):
                continue
            normals = np.cross(tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0])
            lengths = np.linalg.norm(normals, axis=1)
            possible = (lengths > 1e-10) & (normals[:, 2] >= np.cos(np.deg2rad(walkable_slope_angle(row)))*lengths)
            for face, triangle, plane in zip(np.flatnonzero(possible), tri[possible], planes(tri[possible])):
                shift = -.42*plane[:2]/np.sqrt(1+plane[:2]@plane[:2])
                footprint = translate(shapely.Polygon(triangle[:, :2]), *shift)
                if footprint.covers(point):
                    candidates[tuple(np.round(plane, 4))].append([int(index), int(face)])
        levels = []
        for key, faces in candidates.items():
            plane = np.asarray(key)
            local = point.buffer(.0001)
            blockers = standing_obstacles(volumes, local, plane[2], floor_plane=plane)
            clear = not blockers.covers(point)
            levels.append(dict(floorMeters=float(plane[:2]@xy+plane[2]), nativePlane=list(key),
                sourceFaces=faces, sourceCollisions=sorted({rows[i]['id'] for i, _ in faces}),
                standingClear=clear))
        result = dict(attackSvg=svg.tolist(), nativeXY=xy.tolist(),
            levels=sorted(levels, key=lambda r: r['floorMeters']))
        results.append(result)
        print(json.dumps(result), flush=True)
    result = dict(sourceCollidersSha256=sha(rows_path), sourceMeshesSha256=sha(archive_path),
        alignmentSha256=sha(alignment_path), algorithmSha256=sha(Path(__file__)),
        convexBoundaryOrientation=oriented,
        points=results, scope='Fixed source positions. Source-only contact and standing clearance using oriented triangle boundaries; no candidate or bundled height input.')
    (source_dir/output_name).write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    measure()
