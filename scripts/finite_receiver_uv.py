"""Projective source UVs on a finite standing-height receiver.

The shadow polygon only bounds candidate fragments. At each candidate receiver
XY, two affine numerators divided by one affine denominator recover source UV.
The frozen alpha texture and sampling policy are unchanged. This is not a shader.
"""
from dataclasses import dataclass
import numpy as np

from finite_receiver_shadows import build_shadows, renderer_mesh_checked


@dataclass
class ProjectiveUV:
    eye_xy: np.ndarray
    coefficients: np.ndarray

    def evaluate(self, xy, *, coefficient_dtype=np.float64):
        """Return UV or an explicit denominator/numerical fallback reason."""
        local = np.r_[np.asarray(xy, dtype=float)-self.eye_xy, 1.]
        matrix = self.coefficients.astype(coefficient_dtype)
        value = matrix.astype(float)@local
        bound = 64*np.finfo(coefficient_dtype).eps*np.sum(abs(matrix[2].astype(float)*local))
        if not np.isfinite(value).all() or abs(value[2]) <= bound:
            return None, 'projective-denominator-requires-source-fallback'
        uv = value[:2]/value[2]
        if not np.isfinite(uv).all():
            return None, 'nonfinite-projective-uv-requires-source-fallback'
        return uv, None


def build_projective_uv(eye, triangle, source_uv, receiver):
    eye, triangle, source_uv = (np.asarray(x, dtype=float) for x in (eye, triangle, source_uv))
    if eye.shape != (3,) or triangle.shape != (3, 3) or source_uv.shape != (3, 2):
        raise ValueError('Invalid projective UV input dimensions')
    if not all(np.isfinite(x).all() for x in (eye, triangle, source_uv)):
        return None, None, 'nonfinite-source-requires-fallback'
    rows, pending = build_shadows(eye, triangle[None], [receiver])
    if pending:
        return None, None, pending[0]['reason']
    if not rows:
        return None, np.empty((0, 2)), None
    _, output_fallback = renderer_mesh_checked(eye, rows)
    if output_fallback:
        return None, None, output_fallback[0]['reason']
    a, b, c = triangle
    e1, e2, relative = b-a, c-a, eye-a
    # Moller barycentric numerators become affine functions of receiver XY.
    # All coordinates below use receiverXY-eyeXY to reduce world cancellation.
    fa, fb, fc = receiver.floor_plane
    lift = np.array([[1., 0., 0.], [0., 1., 0.],
                     [fa, fb, fa*eye[0]+fb*eye[1]+fc+receiver.standing_height-eye[2]]])
    denominator = np.cross(e2, e1)@lift
    u_numerator = np.cross(e2, relative)@lift
    v_numerator = np.cross(relative, e1)@lift
    numerators = (source_uv[0, :, None]*denominator +
                  (source_uv[1]-source_uv[0])[:, None]*u_numerator +
                  (source_uv[2]-source_uv[0])[:, None]*v_numerator)
    matrix = np.vstack([numerators, denominator])
    scale = np.max(abs(matrix))
    if not np.isfinite(matrix).all() or not np.isfinite(scale) or scale == 0:
        return None, None, 'ill-conditioned-projective-coefficients-require-source-fallback'
    matrix /= scale
    return ProjectiveUV(eye[:2].copy(), matrix), rows[0]['polygon'], None
