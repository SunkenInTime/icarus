"""Proposal-only finite correction for Split's existing 17/18/19 source corner."""
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from authored_region_cells import barycentric
from seal_split_legacy105_rank_one_declarations import seal
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT/'tactical-visibility-revision'


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def declaration():
    raw_path = ROOT/'supplemented-v2/world/split/geometry.npz'
    raw = np.load(raw_path)
    metadata_path = raw_path.with_suffix('.json')
    metadata = json.loads(metadata_path.read_text())
    warp_path = REV/'display-warps-v1/split.display-warp.json.gz'
    w = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((w['projection']['axisU'], w['projection']['axisV']))
    origin = np.array(w['projection']['origin'])
    ws = np.array(w['sourceNativeMeters']).reshape(-1, 2)@matrix.T+origin
    wt = np.array(w['targetAttackSvg']).reshape(-1, 2)
    wc = np.array(w['triangles']).reshape(-1, 3)
    forward = explicit_warp(ws, wt-ws, wc)
    warp_polygons = shapely.polygons(ws[wc])
    tree = shapely.STRtree(warp_polygons)
    bindings_path = REV/'split-wall-family-normalized-candidate-v30-cached-v1/bindings.json'
    bindings = json.loads(bindings_path.read_text())
    old17 = next(f for f in bindings['families'] if f['edge'] == 17)
    along17 = lambda x: old17['targetAlong'][0] + (x-old17['sourceAlong'][0]) / np.diff(old17['sourceAlong'])[0]*np.diff(old17['targetAlong'])[0]
    objects = [140, 141, 142, 143, 392, 394, 449, 5800, 5841, 5857, 5873]
    meshes = {}
    for oid in objects:
        obj = metadata['objects'][oid]
        tris = raw['points'][raw['faces'][obj['firstFace']:obj['firstFace']+obj['faceCount']]].astype(float)
        tris[:, :, :2] = tris[:, :, :2]@matrix.T+origin
        meshes[oid] = tris
    constraints = []

    def coordinate(oid, axis, approximate):
        values = meshes[oid][:, :, axis].ravel()
        value = float(values[np.argmin(abs(values-approximate))])
        assert abs(value-approximate) < 1e-5
        ids = np.flatnonzero(np.any(meshes[oid][:, :, axis] == value, axis=1))
        constraints.append(dict(object=oid, axis=axis, sourceCoordinate=value,
            originalFaceIds=(ids+metadata['objects'][oid]['firstFace']).tolist()))
        return value

    shell_left = coordinate(5857, 0, 345.75439791)
    lower_left = coordinate(5857, 0, 388.028614)
    corner_start = coordinate(5857, 0, 404.398642)
    plinth_x = coordinate(5857, 0, 408.117274)
    standing_x = coordinate(5857, 0, 408.308322)
    monitor_x = float(meshes[5841][:, :, 0].min())
    beam_x = float(meshes[5800][:, :, 0].min())
    backing_right = float(meshes[5873][:, :, 0].max())
    light_top = float(meshes[449][:, :, 1].min())
    light_bottom = float(meshes[449][:, :, 1].max())
    bottom_near = coordinate(5857, 1, 85.343464)
    bottom_far = coordinate(5857, 1, 85.867751)
    bottom_standing = coordinate(5857, 1, 85.441210)
    xs = [340., shell_left, 349.664063, 382., 384., lower_left,
          monitor_x, corner_start, beam_x, plinth_x, standing_x, backing_right, 412., 416.]
    ys = [44., 54., 56.42, 57.73311265, 58.07386812970583, 58.176256,
          58.98, light_top, 60., 83., light_bottom, 84.494647,
          bottom_near, bottom_standing, bottom_far, 87.5, 94., 96.]
    xs = np.array(sorted(set(xs)))
    ys = np.array(sorted(set(ys)))
    top_x = np.array([along17(x) if x <= corner_start else
        np.interp(x, [corner_start, beam_x, backing_right, 412., 416.],
                  [along17(corner_start), 409.855, 409.855, 412., 416.]) for x in xs])
    # Both the original low plinth and the upper return meet the same authored
    # wall. This is a declared depth collapse, never an invented vertical face.
    plain_x = np.interp(xs, [340., 384., lower_left, beam_x, backing_right, 412., 416.],
                       [340., 384., 388.058, 409.855, 409.855, 412., 416.])
    detail_x = np.interp(xs, [340., 384., lower_left, monitor_x, backing_right, 412., 416.],
                        [340., 384., 388.058, 409.855, 409.855, 412., 416.])
    source = []
    target = []
    for y in ys:
        top_weight = np.interp(y, [44., 54., 56.42, 58.98, light_top, 96.], [0., 0., 1., 1., 0., 0.])
        detail_weight = np.interp(y, [44., 58.98, light_top, light_bottom, 84.494647, 96.], [0., 0., 1., 1., 0., 0.])
        active_weight = np.interp(y, [44., 54., 56.42, bottom_far, 94., 96.], [0., 0., 1., 1., 0., 0.])
        tx = (1-detail_weight)*plain_x + detail_weight*detail_x
        tx = (1-top_weight)*tx + top_weight*top_x
        tx = (1-active_weight)*xs + active_weight*tx
        line_y = np.interp(y, [44., 54., 56.42, 58.98, bottom_near, bottom_far, 87.5, 96.],
                          [44., 54., 56.809, 56.809, 84.9854, 84.9854, 87.5, 96.])
        for col, x in enumerate(xs):
            p = np.array([x, y])
            normal_weight = max(top_weight, float(np.clip((x-384.)/(lower_left-384.), 0, 1)))
            q = np.array([tx[col], (1-normal_weight)*y+normal_weight*line_y])
            if x in [xs[0], xs[-1]] or y in [ys[0], ys[-1]]:
                q = forward.apply(p[None])[0]
            source.append(p)
            target.append(q)
    source = np.array(source)
    target = np.array(target)
    initial = []
    nx = len(xs)
    for row in range(len(ys)-1):
        for col in range(nx-1):
            a = row*nx+col
            initial.extend([[a, a+1, a+nx+1], [a, a+nx+1, a+nx]])
    outer = shapely.box(xs[0], ys[0], xs[-1], ys[-1]).boundary
    vertices = []
    mapped = []
    cells = []
    lookup = {}

    def add(p, q):
        key = tuple(p)
        if key in lookup:
            i = lookup[key]
            assert np.linalg.norm(mapped[i]-q) < 1e-10
            return i
        i = len(vertices)
        vertices.append(p)
        mapped.append(q)
        lookup[key] = i
        return i

    for ids in initial:
        tri = source[ids]
        values = target[ids]
        polygon = shapely.Polygon(tri)
        for wi in tree.query(polygon, predicate='intersects'):
            for part in shapely.get_parts(shapely.intersection(polygon, warp_polygons[wi])):
                if not isinstance(part, shapely.Polygon) or part.area == 0:
                    continue
                for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
                    p = np.array(piece.exterior.coords)[:3]
                    q = barycentric(p, tri)@values
                    for axis in range(2):
                        if np.all(values[:, axis] == values[0, axis]):
                            q[:, axis] = values[0, axis]
                    boundary = shapely.distance(shapely.points(p), outer) < 1e-10
                    q[boundary] = forward.apply(p[boundary])
                    ids = [add(a, b) for a, b in zip(p, q)]
                    if len(set(ids)) == 3:
                        cells.append(ids)
    face_ids = []
    for oid in objects:
        obj = metadata['objects'][oid]
        face_ids.extend(range(obj['firstFace'], obj['firstFace']+obj['faceCount']))
    family = dict(edge=200018, mappingType='piecewise-affine-region-v1',
        sourceVerticesSvg=np.array(vertices).tolist(), targetVerticesSvg=np.array(mapped).tolist(),
        triangles=cells, box=[float(xs[0]), float(ys[0]), float(xs[-1]), float(ys[-1])],
        identityOuterBoundary=True, objects=objects, reviewedSourceFaces=sorted(face_ids),
        reviewedAuthoredSpans=[dict(legacyStraightEdgeIndex=e, startSvg=a, endSvg=b) for e, a, b in [
            (17, [315.225, 56.809], [409.855, 56.809]),
            (18, [409.855, 56.809], [409.855, 84.9854]),
            (19, [409.855, 84.9854], [388.058, 84.9854])]],
        sourceGeometrySha256=sha(raw_path), sourceMetadataSha256=sha(metadata_path),
        displayWarpSha256=sha(warp_path), priorCandidateBindingsSha256=sha(bindings_path),
        sourceConstraints=constraints,
        original17AlongContract=dict(sourceAlong=old17['sourceAlong'], targetAlong=old17['targetAlong'],
            unchangedSourceInterval=[shell_left, corner_start],
            adjustedCornerSourceInterval=[corner_start, standing_x],
            lowPlinthSourceX=plinth_x, upperReturnSourceX=standing_x,
            upperBeamNearSourceX=beam_x,
            upperBeamOriginalZRange=[float(meshes[5800][:, :, 2].min()), float(meshes[5800][:, :, 2].max())]),
        role='Existing finite wall and its reviewed mounted details share authored XY contacts. Original Z, UV, caps and height openings remain source-derived. The separate pitched roof is not a wall-depth detail.',
        reviewStatus='Proposal only. No source pack, application data, or renderer was modified.',
        precedence='Replace the complete5857 membership of old17 with this region. Keep old17 for7107 and429. Other original families stay unchanged.',
        pending=['Root review of mounted detail and upper5800 membership.',
                 'Independent original-height first hits against the unchanged full oracle, including upper roof controls.',
                 'Complete candidate source partition and both artwork sides at native8x before acceptance.'])
    family, rank_proof = seal(family)
    return family, forward, dict(rank=rank_proof, topology=verify_region_topology(family, forward))


if __name__ == '__main__':
    out = REV/'split-asite-return18-connected-proposal-v2'
    out.mkdir(exist_ok=False)
    family, forward, proof = declaration()
    (out/'region-declaration.json').write_text(json.dumps(family, indent=2)+'\n')
    (out/'region-topology-review.json').write_text(json.dumps(proof, indent=2)+'\n')
    print(json.dumps({k:v for k,v in proof['topology'].items() if k != 'declaredRankOneStoredResiduals'}))
