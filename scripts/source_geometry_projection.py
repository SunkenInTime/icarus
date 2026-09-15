"""Preserve source polygons when affine rounding creates a self-touch."""
import shapely
from shapely.affinity import affine_transform

from polygonal_area import polygonal


def project_source(shape, transform):
    assert shape.is_valid, shapely.is_valid_reason(shape)
    projected = affine_transform(shape, transform)
    if projected.is_valid:
        return polygonal(projected)
    repaired = polygonal(shapely.make_valid(projected))
    assert repaired.is_valid
    # An affine transform preserves topology. Only floating-point collapse
    # below the existing SVG overlay precision may require repair.
    assert abs(repaired.area-projected.area) <= 1e-8
    assert shapely.hausdorff_distance(projected.boundary, repaired.boundary) <= 1e-8
    return repaired
