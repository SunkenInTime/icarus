"""Serialized UE capsule shapes and complete influence bounds, in native metres.

Scaling follows UE 5.3 BodySetup.cpp:1842-1876 at revision
c865e168d0935b8e5f4bd865ddcc1c733c8ce7cf. Local pitch quarter-turns are covered;
other local rotations and mirrored placements remain unresolved.
"""
import json
import numpy as np
import shapely


def capsule_parts(body, matrix):
    aggregate = body.get('AggGeom', {})
    capsules = aggregate.get('SphylElems', [])
    if not capsules or any(v for k, v in aggregate.items() if k != 'SphylElems'):
        raise ValueError('Expected exclusively serialized capsule collision')
    scale = np.linalg.norm(matrix[:3, :3], axis=1)
    if not np.isfinite(matrix).all() or np.any(scale <= 0) or np.linalg.det(matrix[:3, :3]) <= 0:
        raise ValueError('Invalid or mirrored capsule placement')
    axes = matrix[:3, :3]/scale[:, None]
    if not np.allclose(axes@axes.T, np.eye(3), atol=1e-9):
        raise ValueError('Sheared capsule placement')
    result = []
    for element in capsules:
        rotation = element['Rotation']
        quarter_pitch = (abs(rotation.get('Pitch', 0.)) == 90. and
            rotation.get('Yaw', 0.) == 0. and rotation.get('Roll', 0.) == 0.)
        if any(rotation.values()) and not quarter_pitch:
            raise ValueError('Rotated local capsule element needs explicit conversion')
        if element.get('CollisionEnabled') not in (
                'ECollisionEnabled::QueryOnly', 'ECollisionEnabled::QueryAndPhysics'):
            raise ValueError('Capsule query eligibility needs explicit conversion')
        if element.get('RestOffset', 0.) != 0.:
            raise ValueError('Nonzero capsule rest offset needs explicit conversion')
        half_length = max((element['Length']/2+element['Radius'])*scale[2], .1)*.01
        radius = np.clip(element['Radius']*max(scale[:2])*.01, .001, half_length)
        half_segment = max(.0005, half_length-radius)
        local = np.array([element['Center'][k] for k in 'XYZ'])*[1., -1., 1.]
        center = (local@matrix[:3, :3]+matrix[3, :3])*.01
        # GetFinalScaled preserves the element rotation for positive scales.
        # UE's pitch quarter-turn takes local Z to -sign(Pitch) X. Dimensions
        # still use the original component XY/Z scale, not permuted axes.
        axis = -np.sign(rotation['Pitch'])*axes[0] if quarter_pitch else axes[2]
        extent = np.abs(axis)*half_segment+radius
        result.append(dict(kind='capsule', centerMeters=center.tolist(), axis=axis.tolist(),
            radiusMeters=float(radius), segmentHalfLengthMeters=float(half_segment),
            bounds=[(center-extent).tolist(), (center+extent).tolist()],
            sourceElement=element, sourceMatrix=matrix.tolist(),
            scalingSource='UE5.3 BodySetup.cpp:1842-1876; ChaosInterfaceUtils.cpp:137-155'))
    return result


def support(shape, directions):
    return (directions@np.array(shape['centerMeters']) + shape['radiusMeters']*
        np.linalg.norm(directions, axis=1) + shape['segmentHalfLengthMeters']*
        np.abs(directions@np.array(shape['axis'])))


def outside_capsules(body, matrix, region, margin=.42):
    """Prove every capsule's entire XY bound misses player influence in scope."""
    try:
        capsules = capsule_parts(body, matrix)
    except ValueError:
        return None
    records = []
    for capsule in capsules:
        lo, hi = capsule['bounds']
        bounds = shapely.box(*lo[:2], *hi[:2])
        distance = region.distance(bounds)
        if distance <= margin+.001:
            return None
        records.append(dict(capsule=capsule, distanceToRegionMeters=distance))
    return dict(reason='Complete analytic capsule bounds lie beyond the standing region and player radius.',
        sourceRegion=json.loads(shapely.to_geojson(region)), playerRadiusMeters=margin,
        capsules=records)
