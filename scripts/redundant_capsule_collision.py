"""Prove simple capsules strictly enclosed by existing convex player volumes.

An enclosed shape adds neither a collision boundary nor a standing floor. The
support function tests its complete curved boundary, without tessellation.
"""
import numpy as np
import shapely
from native_capsule_collision import capsule_parts
from gameplay_standing_volumes import collision_parts


def capsule_column_union(shape, volumes, margin=.001):
    """Certify an expanded capsule bounding prism using overlapping solids."""
    lo, hi = np.array(shape['bounds'])
    lo, hi = lo-margin, hi+margin
    intervals = []
    for index in volumes.tree.query(shapely.box(*lo[:2], *hi[:2])):
        equations = volumes.equations[index]
        if equations is None or volumes.rows[index].get('kill'):
            continue
        normals = equations[:, :3]
        normals = normals/np.linalg.norm(normals, axis=1)[:, None]
        offsets = equations[:, 3]/np.linalg.norm(equations[:, :3], axis=1)
        # The entire XY rectangle must satisfy every plane at each height.
        xy = (np.where(normals[:, :2] >= 0., hi[:2], lo[:2])*normals[:, :2]).sum(1)+offsets
        vertical = normals[:, 2]
        flat = abs(vertical) < 1e-12
        if np.any(xy[flat] > 0.):
            continue
        lower = max(lo[2], max(-xy[vertical < -1e-12]/vertical[vertical < -1e-12], default=-np.inf))
        upper = min(hi[2], min(-xy[vertical > 1e-12]/vertical[vertical > 1e-12], default=np.inf))
        if lower <= upper:
            intervals.append(dict(sourceCollision=volumes.rows[index]['id'],
                lowerMeters=float(lower), upperMeters=float(upper)))
    intervals.sort(key=lambda r: r['lowerMeters'])
    reached = lo[2]
    for interval in intervals:
        if interval['lowerMeters'] > reached:
            return None
        reached = max(reached, interval['upperMeters'])
    if reached < hi[2]:
        return None
    return dict(boundKind='convex-volume-column-union', analyticCapsule=shape,
        expansionMeters=margin, prismBounds=[lo.tolist(), hi.tolist()],
        containingVolumes=intervals)


def enclosed_capsules(body, matrix, volumes, *, exact_scaled=False):
    aggregate = body.get('AggGeom', {})
    capsules = aggregate.get('SphylElems', [])
    if not capsules or any(value for key, value in aggregate.items() if key not in ('SphylElems', 'BoxElems')):
        return None
    scale = np.linalg.norm(matrix[:3, :3], axis=1)
    if not np.isfinite(matrix).all() or scale.min() <= 0:
        return None
    axes = matrix[:3, :3] / scale[:, None]
    if not np.allclose(axes @ axes.T, np.eye(3), atol=1e-9):
        return None
    boxes = []
    for box in aggregate.get('BoxElems', []):
        if box.get('RestOffset', 0.) != 0.:
            return None
        try:
            parts = collision_parts(dict(AggGeom=dict(BoxElems=[box])), np.empty((0, 3, 3)), matrix)
        except ValueError:
            return None
        vertices = np.unique(parts[0][0].reshape(-1, 3), axis=0)
        lo, hi = vertices.min(0), vertices.max(0)
        containing = []
        for index in volumes.tree.query(shapely.box(*lo[:2], *hi[:2])):
            equations = volumes.equations[index]
            if equations is None or volumes.rows[index].get('kill'):
                continue
            normals = equations[:, :3]
            outside = (vertices @ normals.T + equations[:, 3]) / np.linalg.norm(normals, axis=1)
            if outside.max() < -.001:
                containing.append(dict(sourceCollision=volumes.rows[index]['id'],
                    minimumInsetMeters=float(-outside.max())))
        if not containing:
            return None
        boxes.append(dict(sourceElement=box, sourceMatrix=matrix.tolist(),
            verticesMeters=vertices.tolist(), containingVolumes=containing))
    analytic = None
    if exact_scaled:
        try:
            analytic = capsule_parts(dict(AggGeom=dict(SphylElems=capsules)), matrix)
        except ValueError:
            return None
    records = []
    for part, capsule in enumerate(capsules):
        if capsule.get('RestOffset', 0.) != 0.:
            return None
        center = np.array([capsule['Center'][key] for key in 'XYZ']) * [1, -1, 1]
        center = (center @ matrix[:3, :3] + matrix[3, :3]) * .01
        radius = capsule['Radius'] * scale[0] * .01
        half = capsule['Length'] * scale[0] * .005
        axis = axes[2]
        conservative = (any(capsule['Rotation'].values()) or
            not np.allclose(scale, scale[0], atol=1e-9, rtol=1e-9) or radius < .001 or half < .0005)
        if analytic is not None:
            shape = analytic[part]
            center = np.array(shape['centerMeters'])
            radius = shape['radiusMeters']
            half = shape['segmentHalfLengthMeters']
            axis = np.array(shape['axis'])
            conservative = False
        elif conservative:
            # UE GetScaledHalfLength bounds the complete capsule by
            # max((Length/2+Radius)*abs(scale.z), .1 cm). Its cylinder clamp
            # can add at most .05 cm. Using max(scale) and a sphere gives an
            # outer bound regardless of the capsule's resulting orientation.
            radius = max((capsule['Length']/2 + capsule['Radius']) * scale.max() * .01, .001) + .0005
            half = 0.
        candidates = volumes.tree.query(shapely.Point(center[:2]).buffer(radius + half))
        containing = []
        for index in candidates:
            equations = volumes.equations[index]
            if equations is None or volumes.rows[index].get('kill'):
                continue
            normals = equations[:, :3]
            lengths = np.linalg.norm(normals, axis=1)
            outside = (normals @ center + equations[:, 3] +
                radius * lengths + half * np.abs(normals @ axis)) / lengths
            if outside.max() < -.001:
                containing.append(dict(sourceCollision=volumes.rows[index]['id'],
                    minimumInsetMeters=float(-outside.max())))
        if not containing:
            if analytic is not None:
                union = capsule_column_union(analytic[part], volumes)
                if union is not None:
                    records.append(union)
                    continue
            # An enclosing sphere can protrude from a thin blocking volume
            # even though the complete scaled capsule stays inside it.
            return (enclosed_capsules(body, matrix, volumes, exact_scaled=True)
                if not exact_scaled else None)
        record = dict(centerMeters=center.tolist(), radiusMeters=float(radius),
            segmentHalfLengthMeters=float(half), axis=axis.tolist(), containingVolumes=containing,
            sourceElement=capsule, sourceMatrix=matrix.tolist())
        if conservative:
            record.update(boundKind='conservative-enclosing-sphere',
                sourceScale=scale.tolist(),
                scalingSource='https://github.com/chenyong2github/UnrealEngine/blob/c865e168d0935b8e5f4bd865ddcc1c733c8ce7cf/Engine/Source/Runtime/Engine/Private/PhysicsEngine/BodySetup.cpp#L1842')
        elif analytic is not None:
            record.update(boundKind='analytic-scaled-capsule', analyticCapsule=analytic[part])
        records.append(record)
    proof = dict(reason='Every capsule and accompanying box lies strictly inside resolved convex player collision.',
                 capsules=records)
    if boxes:
        proof['boxes'] = boxes
    return proof
