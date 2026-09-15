"""Analytic capsule clearance and exact source containment of standing contacts.

A capsule remains a real clearance body when its upper contacts lie inside a
solid or kill volume. No faceted curved standing surface is invented.
"""
import hashlib
import numpy as np
import shapely
from scipy.spatial import ConvexHull, QhullError
from native_capsule_collision import support


def player_center_bounds(shape, slope_degrees=44., radius=.42, height=1.96):
    """Contain every possible walkable contact's standing player centre.

    Contact normals satisfy n.z >= cos(slope). The contact lies on the
    capsule axis segment plus r*n; the player bottom sphere centre is another
    player-radius*n away. The middle of the standing capsule is height/2-r
    above that sphere centre. This also covers the cylindrical contact band.
    """
    c = np.asarray(shape['centerMeters'])
    a = np.asarray(shape['axis'])
    h = shape['segmentHalfLengthMeters']
    r = shape['radiusMeters'] + radius
    rho = r*np.sin(np.deg2rad(slope_degrees))
    lo = c - h*np.abs(a) + [-rho, -rho, r*np.cos(np.deg2rad(slope_degrees))+height/2-radius]
    hi = c + h*np.abs(a) + [rho, rho, r+height/2-radius]
    # For an upright capsule, every upward contact belongs to its upper cap.
    if np.linalg.norm(a[:2]) < 1e-12:
        lo[2] = c[2]+h+r*np.cos(np.deg2rad(slope_degrees))+height/2-radius
    return lo, hi


def blocked_standing_prism(shape, volumes, slope_degrees=44.):
    lo, hi = player_center_bounds(shape, slope_degrees)
    containing = []
    for i in volumes.tree.query(shapely.box(*lo[:2], *hi[:2])):
        eq = volumes.equations[i]
        if eq is None or volumes.rows[i].get('analyticCapsule'):
            continue
        lengths = np.linalg.norm(eq[:, :3], axis=1)
        maximum = ((np.where(eq[:, :3] >= 0., hi, lo)*eq[:, :3]).sum(1)+eq[:, 3])/lengths
        if maximum.max() < -.001:
            containing.append(dict(sourceCollision=volumes.rows[i]['id'],
                minimumInsetMeters=float(-maximum.max()), kill=bool(volumes.rows[i].get('kill'))))
    if not containing:
        return None
    return dict(kind='all-walkable-player-centres-inside-source-solid',
        playerCenterBounds=[lo.tolist(), hi.tolist()], slopeDegrees=slope_degrees,
        playerRadiusMeters=.42, playerHeightMeters=1.96, containingVolumes=containing)


def blocked_contact_prism(shape, volumes, slope_degrees=44.):
    """Prove every potentially walkable contact lies strictly inside a solid.

    Radius=height=0 requests the complete source contact bound, before the
    standing-player offset. Interior contact means a neighbourhood of the
    player's touching sphere also penetrates that solid.
    """
    lo, hi = player_center_bounds(shape, slope_degrees, radius=0., height=0.)
    containing = []
    for i in volumes.tree.query(shapely.box(*lo[:2], *hi[:2])):
        eq = volumes.equations[i]
        if eq is None or volumes.rows[i].get('analyticCapsule'):
            continue
        lengths = np.linalg.norm(eq[:, :3], axis=1)
        maximum = ((np.where(eq[:, :3] >= 0., hi, lo)*eq[:, :3]).sum(1)+eq[:, 3])/lengths
        if maximum.max() < -.001:
            containing.append(dict(sourceCollision=volumes.rows[i]['id'],
                minimumInsetMeters=float(-maximum.max()), kill=bool(volumes.rows[i].get('kill'))))
    if not containing:
        return None
    return dict(kind='all-walkable-source-contacts-inside-source-solid',
        contactBounds=[lo.tolist(), hi.tolist()], slopeDegrees=slope_degrees,
        containingVolumes=containing)


def closed_convex_equations(triangles):
    """Certify an existing triangle boundary, never fill a concavity or hole."""
    vertices, indices = np.unique(triangles.reshape(-1, 3), axis=0, return_inverse=True)
    if len(vertices) < 4:
        return None
    indices = indices.reshape(-1, 3)
    edges = np.sort(np.concatenate([indices[:, [0, 1]], indices[:, [1, 2]], indices[:, [2, 0]]]), axis=1)
    if not np.all(np.unique(edges, axis=0, return_counts=True)[1] == 2):
        return None
    try:
        hull = ConvexHull(vertices)
    except QhullError:
        return None
    area = np.linalg.norm(np.cross(triangles[:, 1]-triangles[:, 0], triangles[:, 2]-triangles[:, 0]), axis=1).sum()/2
    boundary = np.max(triangles.mean(1)@hull.equations[:, :3].T+hull.equations[:, 3], axis=1)
    if abs(area-hull.area) > 1e-7*max(1., hull.area) or np.max(abs(boundary)) > 1e-7:
        return None
    return hull.equations


def enclosed_in_assembly(shape, volumes):
    lo, hi = shape['bounds']
    cache = getattr(volumes, '_capsule_assembly_equations', None)
    if cache is None:
        cache = volumes._capsule_assembly_equations = {}
    for i in volumes.tree.query(shapely.box(*lo[:2], *hi[:2])):
        row = volumes.rows[i]
        if row.get('analyticCapsule') or row.get('kill'):
            continue
        eq = volumes.equations[i]
        if eq is None:
            if i not in cache:
                cache[i] = closed_convex_equations(volumes.triangles[i])
            eq = cache[i]
        if eq is None:
            continue
        lengths = np.linalg.norm(eq[:, :3], axis=1)
        maximum = (support(shape, eq[:, :3])+eq[:, 3])/lengths
        if maximum.max() < -.001:
            return dict(kind='complete-analytic-capsule-inside-source-solid',
                sourceCollision=row['id'], minimumInsetMeters=float(-maximum.max()),
                sourceTrianglesSha256=hashlib.sha256(volumes.triangles[i].tobytes()).hexdigest(),
                convexBoundaryCertified=True)
    return None


def analytic_capsule_obstacle(shape, domain, plane, height=1.96, contact_tolerance=.001):
    """Intersect enclosing support halfplanes of the exact rounded body."""
    from build_all_map_gameplay_supports import clip_support_to_standing_domain
    k = np.arange(256)
    zz = 1-2*(k+.5)/256
    angle = k*np.pi*(3-np.sqrt(5))
    rr = np.sqrt(1-zz*zz)
    normal = np.r_[-np.asarray(plane[:2]), 1.]
    normal /= np.linalg.norm(normal)
    axis = np.asarray(shape['axis'])
    directions = np.concatenate([np.eye(3), -np.eye(3), [normal, -normal, axis, -axis],
        np.c_[rr*np.cos(angle), rr*np.sin(angle), zz]])
    return clip_support_to_standing_domain(directions, support(shape, directions),
        domain, plane, height, contact_tolerance)
