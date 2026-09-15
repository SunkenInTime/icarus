"""Conservative swept eye-to-affine-receiver AABB for offline shadow audits."""
import numpy as np


def outward_add(a, b):
    return np.nextafter(a[0] + b[0], -np.inf), np.nextafter(a[1] + b[1], np.inf)


def outward_product(a, b):
    product = float(a) * float(b)
    return np.nextafter(product, -np.inf), np.nextafter(product, np.inf)


def swept_bounds(eye, receiver):
    """Every eye-to-target segment lies inside this closed bounding box.

    Receiver lifting uses outward arithmetic at each operation. Source triangle
    bounds use their stored exact floating coordinates. AABB overlap may retain
    extra faces, but must not reject a blocking face.
    """
    eye = np.asarray(eye, dtype=float)
    footprint = np.asarray(receiver.footprint, dtype=float)
    a, b, c = receiver.floor_plane
    if not np.isfinite(np.r_[eye, footprint.ravel(), a, b, c, receiver.standing_height]).all():
        raise ValueError('Finite source coordinates required')
    z = []
    for x, y in footprint:
        interval = outward_add(outward_product(a, x), outward_product(b, y))
        interval = outward_add(interval, (c, c))
        z.append(outward_add(interval, (receiver.standing_height, receiver.standing_height)))
    lower = np.minimum(eye, [*footprint.min(0), min(v[0] for v in z)])
    upper = np.maximum(eye, [*footprint.max(0), max(v[1] for v in z)])
    if not np.isfinite(np.r_[lower, upper]).all():
        raise ValueError('Receiver bound overflow')
    return lower, upper


def candidates(eye, receiver, triangle_lower, triangle_upper):
    low, high = swept_bounds(eye, receiver)
    return np.flatnonzero(np.all(triangle_upper >= low, axis=1) &
                          np.all(triangle_lower <= high, axis=1))
