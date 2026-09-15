"""Read the geometry prefix of a single UE 5.3 Chaos triangle collider.

The bounded layout follows ChaosDerivedData.cpp, ImplicitObject::SerializeImp,
TParticles::Serialize and FTriangleMeshIndices::Serialize at UE commit
c865e168d0935b8e5f4bd865ddcc1c733c8ce7cf. Later BVH/material data is not decoded.
"""
import struct
import numpy as np


def triangle_mesh(data):
    if len(data) < 46:
        raise ValueError('Truncated cooked triangle mesh')
    precision, simple, complex_count, exists, tag = struct.unpack_from('<5i', data)
    if (precision, simple, complex_count, exists, tag, data[20]) != (4, 0, 1, 1, 0, 11):
        raise ValueError('Unsupported cooked collision geometry layout')
    convex, collide, collision_type, serialize_particles, vertex_count = struct.unpack_from('<iiBii', data, 21)
    if convex != 0 or collide not in [0, 1] or collision_type != 11 or serialize_particles != 1:
        raise ValueError('Unsupported cooked triangle object flags')
    if not 3 <= vertex_count <= 5_000_000:
        raise ValueError('Invalid cooked particle count')
    offset = 38 + 12 * vertex_count
    if offset + 8 > len(data):
        raise ValueError('Truncated cooked particle array')
    vertices = np.frombuffer(data, dtype='<f4', count=vertex_count * 3, offset=38).reshape(-1, 3).astype(float)
    large, face_count = struct.unpack_from('<ii', data, offset)
    if large not in [0, 1] or not 1 <= face_count <= 10_000_000:
        raise ValueError('Invalid cooked triangle index header')
    end = offset + 8 + face_count * 3 * (4 if large else 2)
    if end + 24 > len(data):
        raise ValueError('Truncated cooked triangle index array')
    indices = np.frombuffer(data, dtype='<u4' if large else '<u2', count=face_count * 3,
        offset=offset + 8).reshape(-1, 3).astype(int)
    if not np.isfinite(vertices).all() or indices.max() >= vertex_count:
        raise ValueError('Invalid cooked triangle coordinates or indices')
    return vertices, indices, dict(vertexCount=vertex_count, triangleCount=face_count,
        indexWidthBytes=4 if large else 2, geometryPrefixBytes=end, trailingBytes=len(data)-end)
