"""Cull segments hidden behind closed blockers for a supplied observer domain.

This changes no retained endpoint. It is valid only for origins in the supplied
domain, with segments treated as closed, two-sided sight blockers. The enclosing
box makes the unbounded arrangement face explicit without adding output walls.
"""
import time

import numpy as np
import shapely


def navigation_domain(navigation, coordinate_scale, buffer_units=0):
    """Union every allowed navigation polygon, regardless of floor elevation."""
    vertices = np.asarray(navigation['vertices'], dtype=np.float64).reshape(-1, 3)
    points = vertices[:, :2] * (coordinate_scale / navigation['coordinateScale'])
    walkable = navigation.get('walkable', [True] * len(navigation['polygons']))
    if len(walkable) != len(navigation['polygons']):
        raise ValueError('Navigation walkable flags do not match polygons.')
    polygons = [shapely.Polygon(points[indices]) for indices, allowed in zip(navigation['polygons'], walkable)
                if allowed and len(indices) >= 3]
    if not polygons or not all(shapely.is_valid(polygons)):
        raise ValueError('Observer polygons must be nonempty and valid.')
    domain = shapely.union_all(polygons)
    if buffer_units < 0:
        raise ValueError('Observer buffer must not narrow the domain.')
    return domain.buffer(buffer_units) if buffer_units else domain


def visible_region(solid_segments, observer_polygons, *, candidate_bounds=None):
    """Return arrangement faces reachable from the complete observer domain.

    Return ``(region, summary)``. For pre-alpha culling, pass only solid blockers
    and set candidate_bounds to bounds of ALL candidate section segments. The
    finite returned region is meaningful only inside its enclosingBounds.
    Omitting alpha barriers overestimates reachable space, which is safe.
    """
    started = time.perf_counter()
    domain = (observer_polygons if isinstance(observer_polygons, shapely.Geometry)
              else shapely.union_all(observer_polygons))
    if domain.is_empty or not domain.is_valid or domain.geom_type not in ['Polygon', 'MultiPolygon']:
        raise ValueError('Observer domain must be a valid nonempty polygon area.')
    coordinates = np.asarray(solid_segments, dtype=np.float64)
    if not len(coordinates):
        coordinates = np.empty((0, 2, 2))
    if coordinates.shape[1:] != (2, 2) or not np.isfinite(coordinates).all():
        raise ValueError('Segments must contain finite pairs of XY endpoints.')
    if not np.any(coordinates[:, 0] != coordinates[:, 1], axis=1).all():
        raise ValueError('Zero-length segments are not supported.')
    bounds = np.asarray(domain.bounds, dtype=np.float64)
    if len(coordinates):
        bounds[:2] = np.minimum(bounds[:2], coordinates.min(axis=(0, 1)))
        bounds[2:] = np.maximum(bounds[2:], coordinates.max(axis=(0, 1)))
    if candidate_bounds is not None:
        candidates = np.asarray(candidate_bounds, dtype=np.float64)
        if candidates.shape != (4,) or not np.isfinite(candidates).all() or np.any(candidates[:2] > candidates[2:]):
            raise ValueError('Candidate bounds must be finite minX,minY,maxX,maxY.')
        bounds[:2] = np.minimum(bounds[:2], candidates[:2])
        bounds[2:] = np.maximum(bounds[2:], candidates[2:])
    margin = max(1.0, float(max(bounds[2:] - bounds[:2])) * .01)
    box = shapely.box(bounds[0] - margin, bounds[1] - margin, bounds[2] + margin, bounds[3] + margin)
    lines = shapely.linestrings(coordinates)
    noded = shapely.union_all(np.concatenate([lines, np.array([box.boundary], dtype=object)]))
    faces = shapely.get_parts(shapely.polygonize(shapely.get_parts(noded)))
    if not len(faces) or not shapely.is_valid(faces).all():
        raise ValueError('Failed to construct valid arrangement faces.')
    # Every observer point must belong to a constructed closed face. This is
    # also a check that polygonization represented the artificial outer face.
    covered = shapely.union_all(faces)
    if not covered.covers(domain):
        raise ValueError('Arrangement faces do not cover the observer domain.')
    shapely.prepare(domain)
    selected = shapely.intersects(domain, faces)
    visible = shapely.union_all(faces[selected])
    shapely.prepare(visible)
    return visible, {
        'method': 'observer-domain-arrangement-faces', 'solidSegments': len(solid_segments),
        'arrangementFaces': len(faces), 'observerFaces': int(selected.sum()),
        'observerDomainBounds': list(domain.bounds), 'enclosingBounds': list(box.bounds),
        'originContract': 'Only origins within the supplied observer polygon domain.',
        'seconds': time.perf_counter() - started,
    }


def visible_segment_indices(segments, region):
    """Conservatively retain complete candidate segments visible in region.

    Candidates must lie inside the enclosingBounds returned by visible_region.
    Midpoint tests can retain a segment but never discard one on their own.
    """
    coordinates = np.asarray(segments, dtype=np.float64)
    if not len(coordinates):
        return np.empty(0, dtype=np.int64)
    lines = shapely.linestrings(coordinates)
    visible = region
    shapely.prepare(visible)
    candidates = np.flatnonzero(shapely.intersects(visible, lines))
    # A contained midpoint is enough to retain a segment. It is not enough to
    # discard one, since callers can supply a segment crossing several faces.
    # Only the remaining candidates need an expensive line/polygon overlay.
    midpoints = shapely.points(coordinates[candidates].mean(axis=1))
    midpoint_visible = shapely.covers(visible, midpoints)
    uncertain = candidates[~midpoint_visible]
    # Point-only contact cannot be the first unique blocker: the selected
    # face's own retained boundary blocks that same contact point. Requiring
    # positive length removes internal diagonals which end on a wall boundary.
    pieces = shapely.intersection(lines[uncertain], visible)
    return np.sort(np.concatenate([candidates[midpoint_visible], uncertain[shapely.length(pieces) > 0]]))


def reduce_segments(segments, observer_polygons):
    """Return original segments reachable from any supplied observer polygon.

    The domain and segments use the same XY units. Touching a face with any
    part of the observer domain selects it, including origins on boundaries.
    No snapping, repair or approximate simplification changes the endpoints.
    """
    started = time.perf_counter()
    region, summary = visible_region(segments, observer_polygons)
    keep = visible_segment_indices(segments, region)
    result = [segments[int(i)] for i in keep]
    summary.update(inputSegments=len(segments), outputSegments=len(result),
                   removedSegments=len(segments) - len(result), retainedEndpointsChanged=False,
                   seconds=time.perf_counter() - started)
    return result, summary
