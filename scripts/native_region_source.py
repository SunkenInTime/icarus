"""Exact original-native triangle construction, independent of admission policy.

This supplies coordinates to the finite clipper. It cannot admit a point
outside a source cell or grant the barrier's coordinate-extension certificate.
"""
from fractions import Fraction
import numpy as np


def native_source_rows(native,matrix,origin):
    native=np.asarray(native,dtype=float);matrix=np.asarray(matrix,dtype=float);origin=np.asarray(origin,dtype=float)
    if native.shape!=(3,3) or matrix.shape!=(2,2) or origin.shape!=(2,):
        raise ValueError('Expected native triangle, 2x2 projection and XY origin')
    if not all(np.isfinite(value).all() for value in [native,matrix,origin]):
        raise ValueError('Source construction must be finite')
    q=lambda value:Fraction(float(value))
    xyz=[[q(value) for value in row] for row in native]
    projection=[[q(value) for value in row] for row in matrix];offset=[q(value) for value in origin]
    return [[sum(projection[k][i]*xyz[j][i] for i in range(2))+offset[k] for k in range(2)]
            +[xyz[j][2]]+[Fraction(int(i==j)) for i in range(3)] for j in range(3)]
