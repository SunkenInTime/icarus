"""Verify corresponding source seams meet the same authored SVG segment.

Each source segment is split at every cell boundary in both region maps.
Agreement at both ends of every affine interval proves agreement throughout
that interval. This checks declared planar contact, not source height coverage.
"""
import numpy as np
import shapely

from verify_region_mapping import region_arrays


def segment_cells(family, segment):
    source, target, cells = region_arrays(family)
    segment = np.asarray(segment, dtype=float)
    assert segment.shape == (2, 2) and np.isfinite(segment).all()
    direction = segment[1] - segment[0]
    length_squared = direction @ direction
    assert length_squared > 0, 'Source seam has no length'
    line = shapely.LineString(segment)
    polygons = shapely.polygons(source[cells])
    intersections = shapely.intersection(polygons, line)
    coordinates = shapely.get_coordinates(intersections)
    assert len(coordinates), 'Source seam is outside region'
    # Test containment against the area. Re-unioning clipped line pieces can
    # move their coordinates by an ulp, breaking exact line coincidence.
    assert shapely.difference(line, shapely.union_all(polygons)).length < 1e-9, 'Source seam escapes region'
    times = np.clip((coordinates-segment[0]) @ direction / length_squared, 0, 1)
    return source, target, cells, segment, np.unique(np.r_[0., times, 1.])


def interval_values(data, start, end):
    source, target, cells, segment, _ = data
    triangle = source[cells]
    inverse = np.linalg.inv(np.stack((triangle[:, 1]-triangle[:, 0],
                                      triangle[:, 2]-triangle[:, 0]), axis=2))
    points = segment[0] + np.array([start, (start+end)/2, end])[:, None] * (segment[1]-segment[0])
    uv = np.einsum('nij,nkj->nki', inverse, points[None]-triangle[:, :1])
    weights = np.concatenate((1-uv.sum(axis=2, keepdims=True), uv), axis=2)
    covering = weights.min(axis=(1, 2)) >= -1e-9
    assert covering.any(), 'Seam interval crosses a missing region cell'
    # Evaluate every coincident cell, so a shared-edge branch cannot hide a split.
    values = np.einsum('nij,njk->nik', weights[covering], target[cells[covering]])
    return values[:, [0, 2]]


def verify_contact(first, first_segment, second, second_segment, authored_segment,
                   tolerance=1e-7):
    a = segment_cells(first, first_segment)
    b = segment_cells(second, second_segment)
    authored = np.asarray(authored_segment, dtype=float)
    assert authored.shape == (2, 2) and np.isfinite(authored).all()
    times = np.unique(np.r_[a[-1], b[-1]])
    maximum = 0.
    for start, end in zip(times[:-1], times[1:]):
        expected = authored[0] + np.array([start, end])[:, None] * (authored[1]-authored[0])
        for data in (a, b):
            values = interval_values(data, start, end)
            error = float(np.linalg.norm(values-expected, axis=2).max())
            maximum = max(maximum, error)
    assert maximum <= tolerance, ('Source seams do not meet the authored contact', maximum)
    return dict(affineIntervals=len(times)-1, maximumAuthoredContactErrorSvg=maximum,
                continuousContactVerified=True, sourceHeightCoverageVerified=False)
