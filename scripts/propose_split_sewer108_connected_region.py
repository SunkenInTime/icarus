"""Review-only finite XY field for Split's paired sewer entrance and outer shell.

The rear tunnel grate retains its original location. Source Z, UV, materials,
openings and caps are never generated from a maximum-height approximation.
"""
import argparse
import gzip
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
import shapely

from authored_region_cells import barycentric
from declare_split_legacy105_connected_region import ROOT, REV, sha
from render_split_remaining_corner_families import sections
from tactical_alignment_audit import vector_lines
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology


def main(version):
    output = REV / f'split-sewer108-connected-proposal-{version}'
    output.mkdir(exist_ok=False)
    geometry = ROOT / 'supplemented-v2/world/split/geometry.npz'
    raw = np.load(geometry)
    metadata = json.loads(geometry.with_suffix('.json').read_text())
    warp_path = REV / 'display-warps-v1/split.display-warp.json.gz'
    w = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((w['projection']['axisU'], w['projection']['axisV']))
    origin = np.array(w['projection']['origin'])
    ws = np.array(w['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    wt = np.array(w['targetAttackSvg']).reshape(-1, 2)
    wc = np.array(w['triangles']).reshape(-1, 3)
    forward = explicit_warp(ws, wt-ws, wc)
    objects = [6159, 6160, 6161, 6162, 6163, 6164, 6169, 6143, 814, 815, 6249]
    triangles, source_ids, owners, inventory = [], [], [], []
    retained_path = REV / 'full-height-input-v1/split/source-correspondence.npz'
    retained = np.load(retained_path)['sourceFaces']
    for oid in objects:
        obj = metadata['objects'][oid]
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        tri = raw['points'][raw['faces'][ids]].astype(float)
        tri[:, :, :2] = tri[:, :, :2] @ matrix.T + origin
        triangles.extend(tri)
        source_ids.extend(ids)
        owners.extend([oid] * len(ids))
        mids = raw['material_indices'][ids]
        kept = np.isin(ids, retained)
        inventory.append(dict(object=oid, path=obj['path'], rawFaceIds=ids.tolist(),
            boundsMeters=obj['boundsMeters'], materials=[dict(material=int(mid),
                metadata=metadata['materials'][int(mid)], rawFaces=ids[mids == mid].tolist(),
                retainedFaces=int(((mids == mid) & kept).sum()),
                omittedFaces=ids[(mids == mid) & ~kept].tolist()) for mid in np.unique(mids)]))
    triangles = np.array(triangles)
    owners = np.array(owners)
    source_ids = np.array(source_ids)
    constraints = []

    def value(oid, axis, approximate):
        coords = triangles[owners == oid, :, axis]
        v = float(coords.ravel()[np.argmin(abs(coords.ravel() - approximate))])
        assert abs(v-approximate) < 2e-5, (oid, axis, approximate, v)
        ids = source_ids[(owners == oid) & np.any(triangles[:, :, axis] == v, axis=1)]
        constraints.append(dict(object=oid, axis=axis, coordinate=v, rawSourceFaces=ids.tolist()))
        return v

    rear = value(6160, 0, 366.93306377)
    rear_cap = value(6160, 0, 368.96547)
    wall_start = value(6163, 0, 369.21211957)
    left_end = value(6169, 0, 356.81880942)
    left_plane = value(6169, 0, 357.47721856)
    north_return_path = REV/'split-sewer117-simple-proposal-v1/region-declaration.json'
    north_return = json.loads(north_return_path.read_text())
    left_plane = north_return['sourceBands']['right'][1]
    diagonal_start = value(6169, 0, 380.95180797)
    diagonal_end = value(6169, 0, 396.59028908)
    left_y = value(6169, 1, 273.04475899)
    top_y = value(6169, 1, 257.40812722)
    notch_left_near = value(6159, 0, 394.29866076)
    notch_left_nominal = value(6162, 0, 394.62465136)
    notch_left_far = value(6162, 0, 394.62724640)
    notch_right_near = value(6169, 0, 396.29329133)
    frame_right_far = value(6159, 0, 396.88988187)
    notch_right_far = float(triangles[np.isin(owners, [814, 815]), :, 0].max())
    constraints.append(dict(objects=[814,815], axis=0, coordinate=notch_right_far,
        rawSourceFaces=source_ids[np.isin(owners,[814,815]) & np.any(triangles[:,:,0] == notch_right_far,axis=1)].tolist()))
    outer_near = value(6169, 0, 404.14447771)
    outer_far = value(6169, 0, 404.44881315)
    lower_end = value(6169, 0, 388.68975221)
    lower_end_far = value(6169, 0, 388.98867)
    lower_return_path = REV/'split-sewer147-return-proposal-v1/region-declaration.json'
    lower_return = json.loads(lower_return_path.read_text())
    lower_end, lower_end_far = lower_return['sourceBands']['right']
    # The upper contour is a source-derived polyline. Its corresponding
    # authored diagonal is one exact span, not an axis-aligned staircase.
    north = lambda x: np.interp(x, [350., diagonal_start, diagonal_end, 411.],
                                [left_y, left_y, top_y, top_y])
    shell_points = triangles[owners == 6169].reshape(-1, 3)
    upper = shell_points[shell_points[:, 1] < 274.]
    residual = upper[:, 1] - north(upper[:, 0])
    # The right wall continues far below this contour. The reviewed 1.05-SVG
    # neighborhood isolates the attached north trim from that perpendicular
    # continuation; it only chooses field anchors and removes no source face.
    residual = residual[(residual > -1.) & (residual < 1.05)]
    band_low, band_high = float(residual.min()), float(residual.max())
    north_source = [350., left_end, left_plane, diagonal_start, diagonal_end, outer_near, outer_far, 411.]
    north_target = [350., 357.755, 357.755, 381.679, 397.096, 404.539, 404.539, 411.]
    north_x = lambda x: np.interp(x, north_source, north_target)
    north_target_y = lambda x: np.interp(x, [350., 381.679, 397.096, 411.],
                                       [273.182, 273.182, 257.234, 257.234])
    bindings_path = REV / 'split-wall-family-normalized-candidate-v31-precise-v1/bindings.json'
    bindings = json.loads(bindings_path.read_text())
    old108 = next(f for f in bindings['families'] if f['edge'] == 108)
    along = lambda x: old108['targetAlong'][0] + (x-old108['sourceAlong'][0]) / np.diff(old108['sourceAlong'])[0] * np.diff(old108['targetAlong'])[0]
    front_source = [350., rear_cap, wall_start, 393.5, notch_left_near, notch_left_nominal, notch_left_far,
                    notch_right_near, frame_right_far, notch_right_far, outer_near, outer_far, 411.]
    front_target = [350., rear_cap, along(wall_start), along(393.5), 394.97, 394.97, 394.97,
                    397.096, 397.096, 397.096, 404.539, 404.539, 411.]
    front_x = lambda x: np.interp(x, front_source, front_target)
    lower_source = [350., rear_cap, lower_end, lower_end_far, notch_left_near, notch_left_nominal, notch_left_far,
                    notch_right_near, frame_right_far, notch_right_far, outer_near, outer_far, 411.]
    lower_target = [350., rear_cap, 389.122, 389.122, 394.97, 394.97, 394.97,
                    397.096, 397.096, 397.096, 404.539, 404.539, 411.]
    lower_x = lambda x: np.interp(x, lower_source, lower_target)
    # All active band limits below are literal source vertices, not tolerances.
    notch_top = [value(6169, 1, 280.19342056), value(6169, 1, 280.91172440)]
    north_wall = [value(6160, 1, 288.60368872), value(6160, 1, 289.91896341)]
    upper_frame = [value(6162, 1, 290.653791977), value(6159, 1, 291.321052589)]
    lower_frame = [value(6159, 1, 301.731685757), value(6159, 1, 302.418535932)]
    south_wall_points = triangles[owners == 6160].reshape(-1, 3)
    south_wall_points = south_wall_points[(south_wall_points[:, 1] > 303.) & (south_wall_points[:, 0] >= wall_start)]
    south_wall = [float(south_wall_points[:, 1].min()), float(south_wall_points[:, 1].max())]
    bottom = [value(6169, 1, 311.68115512), value(6169, 1, 312.25218304)]
    xs = np.array(sorted(set(north_source + front_source + lower_source + [rear])))
    specs = [('identity', 249.), ('identity', 253.), ('north', band_low), ('north', band_high),
             ('north-x', 276.), ('notch-top', notch_top[0]), ('notch-top', notch_top[1]),
             ('front', 285.), ('north-wall', north_wall[0]), ('north-wall', north_wall[1]),
             ('upper-frame', upper_frame[0]), ('upper-frame', upper_frame[1]), ('front', 296.5),
             ('lower-frame', lower_frame[0]), ('lower-frame', lower_frame[1]),
             ('south-wall', south_wall[0]), ('south-wall', south_wall[1]), ('lower', 308.),
             ('bottom', bottom[0]), ('bottom', bottom[1]), ('identity', 315.), ('identity', 318.)]
    source, target = [], []
    for role, y in specs:
        sy = north(xs) + y if role == 'north' else np.full(len(xs), y)
        tx = xs.copy()
        ty = sy.copy()
        if role in ['north', 'north-x', 'notch-top']:
            tx = north_x(xs) if role != 'notch-top' else front_x(xs)
        elif role != 'identity':
            tx = lower_x(xs) if role in ['lower', 'bottom'] else front_x(xs)
        if role == 'north':
            ty = north_target_y(tx)
        elif role == 'notch-top':
            ty[:] = 280.094
        elif role in ['north-wall', 'south-wall']:
            blend = np.clip((xs-rear_cap)/(wall_start-rear_cap), 0, 1)
            ty = (1-blend)*sy + blend*(288.068 if role == 'north-wall' else 304.549)
        elif role in ['upper-frame', 'lower-frame']:
            blend = np.clip((xs-393.5)/(notch_left_near-393.5), 0, 1)
            ty = (1-blend)*sy + blend*(291.79 if role == 'upper-frame' else 300.827)
        elif role == 'bottom':
            blend = np.clip((xs-380.)/(lower_end-380.), 0, 1)
            ty = (1-blend)*sy + blend*311.46
        s = np.column_stack((xs, sy))
        t = np.column_stack((tx, ty))
        t[[0, -1]] = forward.apply(s[[0, -1]])
        if role == 'identity':
            t = forward.apply(s)
        source.extend(s)
        target.extend(t)
    source, target = np.array(source), np.array(target)
    initial, nx = [], len(xs)
    for row in range(len(specs)-1):
        for col in range(nx-1):
            a = row*nx+col
            initial.extend([[a, a+1, a+nx+1], [a, a+nx+1, a+nx]])
    outer = shapely.box(350., 249., 411., 318.).boundary
    polygons = shapely.polygons(ws[wc])
    tree = shapely.STRtree(polygons)
    vertices, mapped, cells, lookup = [], [], [], {}

    def add(p, q):
        key = tuple(p)
        if key in lookup:
            idx = lookup[key]
            assert np.linalg.norm(mapped[idx]-q) < 1e-10, (p, mapped[idx], q)
            return idx
        idx = len(vertices)
        vertices.append(p)
        mapped.append(q)
        lookup[key] = idx
        return idx

    for ids in initial:
        tri, values = source[ids], target[ids]
        polygon = shapely.Polygon(tri)
        assert polygon.area > 0, ('Invalid source cell', ids)
        for wi in tree.query(polygon, predicate='intersects'):
            for part in shapely.get_parts(shapely.intersection(polygon, polygons[wi])):
                if not isinstance(part, shapely.Polygon) or part.area == 0:
                    continue
                for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
                    p = np.array(piece.exterior.coords)[:3]
                    q = barycentric(p, tri) @ values
                    for axis in range(2):
                        if np.all(values[:, axis] == values[0, axis]):
                            q[:, axis] = values[0, axis]
                    boundary = shapely.distance(shapely.points(p), outer) < 1e-10
                    q[boundary] = forward.apply(p[boundary])
                    indices = [add(a, b) for a, b in zip(p, q)]
                    if len(set(indices)) == 3:
                        cells.append(indices)
    source, target, cells = np.array(vertices), np.array(mapped), np.array(cells)
    lines = vector_lines(Path('assets/maps/split_map.svg'))
    family = dict(edge=200108, mappingType='piecewise-affine-region-v1', objects=objects,
        box=[350., 249., 411., 318.], sourceVerticesSvg=source.tolist(),
        targetVerticesSvg=target.tolist(), triangles=cells.tolist(),
        reviewedSourceFaces=source_ids.tolist(), identityOuterBoundary=True,
        sourcePartitionMethod='finite-convex-cells-v1',
        sourceCoordinateConstruction='original-native-triangle-v1',
        declaredRankOneMappings=[], declaredConstantPointCells=[],
        reviewedAuthoredSpans=[dict(legacyStraightEdgeIndex=i, startSvg=lines[i][0].tolist(),
                                  endSvg=lines[i][1].tolist()) for i in list(range(108,117))+list(range(142,147))],
        sourceGeometrySha256=sha(geometry), sourceMetadataSha256=sha(geometry.with_suffix('.json')),
        displayWarpSha256=sha(warp_path), sourceConstraints=constraints,
        sourceInventory=inventory, originalRearGrateX=rear,
        attachmentSourceReviewSha256=sha(REV/'split-sewer108-attachment-review-v1/report.json'),
        northReturnDeclarationSha256=sha(north_return_path),
        lowerReturnDeclarationSha256=sha(lower_return_path),
        preservedRearGrateSourceBand=[350., rear_cap],
        upperContourSourceBand=[band_low, band_high],
        original108AlongContract=dict(sourceAlong=old108['sourceAlong'], targetAlong=old108['targetAlong'],
            unchangedSourceInterval=[wall_start, 393.5], terminalCollapse=[393.5, notch_left_far]),
        precedence='Replace complete 6163 membership of old108; keep old108 for 7895 and 7897. No other current family changes.',
        status='Proposal only, awaiting connected-source and interface review. No cumulative bake or app mutation.',
        sourceZPolicy='Retain every source Z, material admission, UV, cap and opening. Rear upper tunnel remains physically inset; its standing-target visibility is a separate floor-policy question.')
    for ci, cell in enumerate(cells):
        dst, src = target[cell], source[cell]
        distances = np.linalg.norm(dst[:, None]-dst[None, :], axis=2)
        ia, ib = np.unravel_index(distances.argmax(), distances.shape)
        if distances[ia, ib] == 0:
            family['declaredConstantPointCells'].append(ci)
            continue
        a, b = dst[[ia, ib]]
        delta = b-a
        parameters = (dst-a) @ delta / (delta @ delta)
        expected = a+parameters[:, None]*delta
        if (abs(dst-expected) > 4*np.spacing(np.maximum(1., abs(expected)))).any():
            continue
        gradient = np.linalg.solve(src[1:]-src[:1], parameters[1:]-parameters[0])
        norm = float(np.linalg.norm(gradient))
        if norm == 0:
            continue
        family['declaredRankOneMappings'].append(dict(id=f'sewer108-cell-{ci}',
            targetEndpointsSvg=[a.tolist(), b.tolist()], targetEndpointVertexIds=[int(cell[ia]), int(cell[ib])],
            sourceOriginSvg=src[ia].tolist(), sourceTangent=(gradient/norm).tolist(),
            sourceLengthSvg=1/norm, sourceEndpointArithmeticSvg=1e-12,
            cells=[dict(cell=ci, vertexParameters=np.clip(parameters, 0, 1).tolist())]))
    path = output / 'region-declaration.json'
    path.write_text(json.dumps(family, indent=2)+'\n')
    try:
        topology = verify_region_topology(family, forward)
    except (AssertionError, ValueError, np.linalg.LinAlgError) as error:
        topology = dict(passed=False, error=str(error))
    report = dict(declarationSha256=sha(path), scriptSha256=sha(Path(__file__)), topology=topology,
        fullSourceFaces=len(source_ids), sourceCells=len(cells), sourceVertices=len(source),
        retainedFaces=int(np.isin(source_ids, retained).sum()),
        fullInputCorrespondenceSha256=sha(retained_path), productionMutation=False,
        remaining=['Independent complete source partition before any cumulative bake.',
            'Exact shared contact with old108 source 7895/7897 and neighboring outer-shell terminations.',
            'Source first contacts and both-side native8x app views after root source review.',
            'Rear inset grate and lower tunnel wall beyond drawn142 remain height-policy questions.'])
    (output/'proposal-review.json').write_text(json.dumps(report, indent=2)+'\n')
    mapping = explicit_warp(source, target-source, cells)
    colors = dict(zip(objects, ['#218541', '#7a37aa', '#36bfc4', '#dd3730', '#d88d11', '#324acc', '#cf3599', '#64748b', '#ac680d', '#ad580d', '#22717b']))
    for name, box in [('whole', [350.,250.,411.,318.]), ('paired-opening', [391.,277.,400.,314.]), ('rear-transition',[365.,287.,372.,306.])]:
        fig, axes = plt.subplots(6,2,figsize=(12,20))
        for row, z in enumerate([2.75,3.25,4.85,5.75,6.75,8.25]):
            for owner, color in colors.items():
                segments, _ = sections(triangles[owners == owner], z)
                if len(segments):
                    axes[row, 0].add_collection(LineCollection([forward.apply(s) for s in segments], colors=color, linewidths=1.))
                    p = segments[:,:1] + np.linspace(0,1,241)[None,:,None]*(segments[:,1:]-segments[:,:1])
                    q = mapping.apply(p.reshape(-1,2)).reshape(p.shape)
                    axes[row, 1].add_collection(LineCollection(q, colors=color, linewidths=1.))
            for col in range(2):
                for line in lines:
                    axes[row,col].plot(*line.T, color='#191919', linewidth=1.2)
                axes[row,col].set(xlim=(box[0],box[2]), ylim=(box[3],box[1]),
                    title=f'{"Original" if col == 0 else "Proposed"} source at original Z {z:g} m')
                axes[row,col].set_aspect('equal')
                axes[row,col].grid(alpha=.15)
        fig.suptitle('Complete sewer entrance and outer shell. Original heights retained. Proposal only.\nBlack: authored SVG. Colored: original source sections; colors identify complete source objects.')
        fig.tight_layout(rect=[0,0,1,.97])
        fig.savefig(output/f'{name}-source-height-preview.png',dpi=150)
        plt.close(fig)
    print(json.dumps(dict(output=str(output), topology={k:v for k,v in topology.items() if k!='declaredRankOneStoredResiduals'},
        rawFaces=len(source_ids), cells=len(cells))))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='v1')
    main(parser.parse_args().version)
