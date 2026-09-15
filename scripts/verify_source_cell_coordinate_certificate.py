"""Independent coordinate-error proof for an explicitly opted-in source field.

No builder certificate is trusted. Reconstruct original coordinates exactly,
bound distance to the declared cell by one binary64 XY storage interval, and
bound the difference from the continuous field. Source-area and display-cell
checks remain separate. Rank-one scalar overrides are intentionally unsupported.
"""
from collections import Counter
from fractions import Fraction
from functools import lru_cache
import hashlib
import json
import math


POLICY = dict(format='icarus-source-cell-coordinate-certificate-v1',
              coordinateStorageUlps=1, maximumMappedExtensionErrorSvg=1e-7)


def rational(value):
    return Fraction.from_float(float(value))


def encoded(value):
    return dict(numerator=str(value.numerator), denominator=str(value.denominator), decimal=float(value))


def subtract(a, b):
    return [x-y for x, y in zip(a, b)]


def dot(a, b):
    return sum(x*y for x, y in zip(a, b))


def cross(a, b):
    return a[0]*b[1]-a[1]*b[0]


def sqrt_upper(value):
    assert value >= 0
    seed = float(value)
    # A positive exact rational can underflow to zero. Starting nextafter
    # iteration there could require trillions of steps before reaching its
    # square root. The smallest positive double is a conservative seed.
    if value and seed == 0:
        seed = math.ulp(0.)
    result = math.sqrt(seed)
    while rational(result)**2 < value:
        result = math.nextafter(result, math.inf)
    return result


def weights(point, triangle):
    a, b = subtract(triangle[1], triangle[0]), subtract(triangle[2], triangle[0])
    p = subtract(point, triangle[0])
    determinant = cross(a, b)
    assert determinant != 0
    u, v = cross(p, b)/determinant, cross(a, p)/determinant
    return [1-u-v, u, v]


def jacobian_norm_squared(source, target):
    a, b = subtract(source[1], source[0]), subtract(source[2], source[0])
    determinant = cross(a, b)
    total = Fraction(0)
    for coordinate in range(2):
        u = target[1][coordinate]-target[0][coordinate]
        v = target[2][coordinate]-target[0][coordinate]
        total += ((u*b[1]-v*a[1])/determinant)**2
        total += ((a[0]*v-b[0]*u)/determinant)**2
    return total


@lru_cache(maxsize=8)
def prepare_field(serialized):
    field = json.loads(serialized)
    source = [[rational(x) for x in p] for p in field['sourceVerticesSvg']]
    target = [[rational(x) for x in p] for p in field['targetVerticesSvg']]
    cells = field['triangles']
    lower = [min(p[k] for p in source) for k in range(2)]
    upper = [max(p[k] for p in source) for k in range(2)]
    edges = Counter(); total_area = Fraction(0); norms = []
    for ids in cells:
        assert len(ids) == 3 and len(set(ids)) == 3
        a, b, c = [source[i] for i in ids]
        area2 = cross(subtract(b, a), subtract(c, a))
        assert area2 != 0
        positive = ids if area2 > 0 else list(reversed(ids))
        edges.update(zip(positive, positive[1:]+positive[:1]))
        total_area += abs(area2)/2
        norms.append(jacobian_norm_squared([source[i] for i in ids], [target[i] for i in ids]))
    for (a, b), count in edges.items():
        assert count == 1, 'Repeated oriented source edge'
        if (b, a) in edges:
            continue
        assert any(source[a][k] == source[b][k] and source[a][k] in (lower[k], upper[k]) for k in range(2)), 'Unpaired internal source edge'
    rectangle_area = (upper[0]-lower[0])*(upper[1]-lower[1])
    assert rectangle_area > 0 and total_area == rectangle_area, 'Source cells do not cover a convex rectangle once'
    return source, target, cells, lower, upper, norms, dict(
        fieldSha256=hashlib.sha256(serialized.encode()).hexdigest(),
        exactArea=encoded(total_area), maximumJacobianFrobeniusSquared=encoded(max(norms)),
        proof='Positive oriented triangle boundaries cancel internally; remaining edges lie on rectangle, exact area equals rectangle area. Shared target vertex IDs define a continuous affine field on that convex domain.')


def certify_coordinate_error(family, original, bary, matrix, origin, cell):
    assert family.get('sourceContainmentArithmeticPolicy') == POLICY, 'Missing or unsupported coordinate-error policy'
    assert not family.get('declaredRankOneMappings'), 'Scalar rank-one overrides need a separate continuity proof'
    serialized = json.dumps({key:family[key] for key in ('sourceVerticesSvg','targetVerticesSvg','triangles')}, separators=(',', ':'), allow_nan=False)
    source, target, cells, lower, upper, norms, field_proof = prepare_field(serialized)
    assert 0 <= cell < len(cells)
    triangle = [source[i] for i in cells[cell]]
    native = [[rational(x) for x in row] for row in original]
    transform = [[rational(x) for x in row] for row in matrix]
    offset = [rational(x) for x in origin]
    stretch = math.nextafter(sqrt_upper(max(norms))+sqrt_upper(norms[cell]), math.inf)
    rows, result = [], []
    for coefficients in bary:
        coefficients = [rational(x) for x in coefficients]
        point_native = [native[0][k] + sum(coefficients[j]*(native[j][k]-native[0][k]) for j in (1,2)) for k in range(2)]
        point = [dot(transform[k], point_native)+offset[k] for k in range(2)]
        assert all(lower[k] <= point[k] <= upper[k] for k in range(2)), 'Source coordinate escapes the declared convex domain'
        exact_weights = weights(point, triangle)
        distances = []
        if min(exact_weights) >= 0:
            distances.append(Fraction(0))
        for start, end in zip(triangle, triangle[1:]+triangle[:1]):
            direction = subtract(end, start)
            t = max(Fraction(0), min(Fraction(1), dot(subtract(point, start), direction)/dot(direction, direction)))
            residual = subtract(point, [start[k]+t*direction[k] for k in range(2)])
            distances.append(dot(residual, residual))
        distance_squared = min(distances)
        storage_squared = sum(rational(math.ulp(float(coordinate)))**2 for coordinate in point)
        assert distance_squared <= storage_squared, 'Source-cell escape exceeds one XY storage interval'
        error = math.nextafter(stretch*sqrt_upper(distance_squared), math.inf) if distance_squared else 0.
        assert error < POLICY['maximumMappedExtensionErrorSvg'], 'Mapped extension exceeds authored-position budget'
        rows.append(dict(exactSourcePoint=[encoded(x) for x in point], exactWeights=[encoded(x) for x in exact_weights],
            exactSquaredOutsideDistance=encoded(distance_squared), exactSquaredStorageBudget=encoded(storage_squared),
            maximumMappedExtensionErrorSvg=error))
        result.append([float(x) for x in exact_weights])
    return result, dict(policy=POLICY, field=field_proof, declaredCell=cell, vertices=rows,
        maximumMappedExtensionErrorSvg=max(row['maximumMappedExtensionErrorSvg'] for row in rows),
        scope='Distance to a convex cell is convex, so vertex bounds cover the entire source fragment. The field is continuous on its convex rectangle; summed outward-rounded Jacobian bounds limit deviation of the assigned affine extension. Source partition and displayed-wall contact remain independent checks.')
