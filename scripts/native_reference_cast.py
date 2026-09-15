"""Test-only native traversal with the independent Python alpha sampler."""
import ctypes
import numpy as np
from audit_tactical_target_rays import ReferenceModel
from world_visibility_ray_reference import sample_alpha


class NativeReferenceModel(ReferenceModel):
    def __init__(self, path, library):
        super().__init__(path)
        self.bind(library)

    def bind(self, library):
        self.library = ctypes.CDLL(str(library))
        self.nearest = self.library.nearest_triangle
        fp = ctypes.POINTER(ctypes.c_double)
        ip = ctypes.POINTER(ctypes.c_int32)
        up = ctypes.POINTER(ctypes.c_uint32)
        self.nearest.argtypes = [fp, up, fp, ip, fp, fp, ctypes.c_double,
                                 ctypes.c_double, ctypes.c_int, ip, ctypes.c_int32, fp]
        self.nearest.restype = ctypes.c_int
        self.pointers = [self.arrays[name].ctypes.data_as(kind) for name, kind in
                         [('vertices', fp), ('faces', up), ('bounds', fp), ('nodes', ip)]]

    def cast(self, origin, target, *, min_distance=1e-5, end_padding=1e-5, end_inclusive=False,
             excluded_faces=()):
        if not np.isfinite([min_distance, end_padding]).all() or min_distance < 0 or end_padding < 0:
            raise ValueError('Invalid endpoint guards')
        origin, target = np.array(origin, dtype=np.float64), np.array(target, dtype=np.float64)
        output = np.zeros(3)
        fp, ip = ctypes.POINTER(ctypes.c_double), ctypes.POINTER(ctypes.c_int32)
        excluded = list(excluded_faces)
        if any(not isinstance(face, (int, np.integer)) or face < 0 or
               face >= len(self.arrays['faces']) for face in excluded):
            raise ValueError('Excluded face is outside this source pack')
        excluded = sorted(set(excluded))
        while True:
            excluded_array = np.array(excluded or [-1], dtype=np.int32)
            face = self.nearest(*self.pointers, origin.ctypes.data_as(fp), target.ctypes.data_as(fp),
                                min_distance, end_padding, int(end_inclusive), excluded_array.ctypes.data_as(ip), len(excluded),
                                output.ctypes.data_as(fp))
            if face == -2:
                raise ValueError('Native BVH stack overflow')
            if face < 0:
                return None
            distance, u, v = output
            mask = int(self.arrays['faceMasks'][face])
            if mask >= 0:
                material = self.materials[int(self.arrays['maskedMaterials'][mask])]
                uv = np.array([1 - u - v, u, v]) @ self.arrays['maskedUvs'][mask]
                if sample_alpha(self.textures[material['texture']], uv, material) < material['threshold']:
                    # Exclude only the transparent face, preserving a solid
                    # coincident triangle at the same ray distance.
                    excluded.append(face)
                    continue
            triangle = self.arrays['vertices'][self.arrays['faces'][face]]
            normal = np.cross(triangle[1] - triangle[0], triangle[2] - triangle[0])
            normal /= np.linalg.norm(normal)
            direction = target - origin
            direction /= np.linalg.norm(direction)
            return dict(face=face, distanceMeters=float(distance), point=(origin + direction * distance).tolist(),
                        normal=normal.tolist(), masked=mask >= 0)
