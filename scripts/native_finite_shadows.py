"""Test-only wrapper for finite opaque shadows; no receiver-layer selection."""
import ctypes
import numpy as np


class NativeFiniteShadows:
    def __init__(self, library):
        self.library = ctypes.CDLL(str(library))
        self.project_native = self.library.finite_receiver_project
        dp = ctypes.POINTER(ctypes.c_double)
        self.project_native.argtypes = [dp, dp, ctypes.c_int, dp, ctypes.c_double,
            dp, ctypes.c_int, ctypes.POINTER(ctypes.c_float), ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint8)]
        self.project_native.restype = ctypes.c_int

    def project(self, eye, opaque_triangles, receiver):
        eye = np.ascontiguousarray(eye, dtype=np.float64)
        triangles = np.ascontiguousarray(opaque_triangles, dtype=np.float64)
        plane = np.ascontiguousarray(receiver.floor_plane, dtype=np.float64)
        footprint = np.ascontiguousarray(receiver.footprint, dtype=np.float64)
        if eye.shape != (3,) or triangles.ndim != 3 or triangles.shape[1:] != (3, 3) or plane.shape != (3,) or footprint.ndim != 2 or footprint.shape[1] != 2 or len(footprint) < 3:
            raise ValueError('Invalid finite-shadow input dimensions')
        output = np.empty(max(1, len(triangles) * (len(footprint)+6)*6), dtype=np.float32)
        fallback = np.zeros(len(triangles), dtype=np.uint8)
        dp = ctypes.POINTER(ctypes.c_double)
        count = self.project_native(eye.ctypes.data_as(dp), triangles.ctypes.data_as(dp), len(triangles),
            plane.ctypes.data_as(dp), float(receiver.standing_height), footprint.ctypes.data_as(dp), len(footprint),
            output.ctypes.data_as(ctypes.POINTER(ctypes.c_float)), len(output),
            fallback.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)))
        if count < 0:
            raise ValueError(f'Native finite projection rejected input or output capacity: {count}')
        return output[:count].reshape(-1, 3, 2), fallback
