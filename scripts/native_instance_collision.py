"""Construct instance physics transforms from serialized matrices, not USD.

UE 5.3 InstancedStaticMesh.cpp:2638 converts the saved instance matrix to an
FTransform, then multiplies by the component FTransform. Matrix decomposition
and quaternion normalization follow TransformNonVectorized.h and Quat.h at
c865e168d0935b8e5f4bd865ddcc1c733c8ce7cf. The parser's approximate inverse square
root is deliberately not used for this independent physical reference.
"""
from functools import lru_cache
import hashlib
import json
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation


def rotation_from_rows(matrix):
    """UE's matrix-to-quaternion branches followed by exact normalization."""
    q = np.zeros(4)
    trace = np.trace(matrix)
    if trace > 0:
        root = np.sqrt(trace + 1)
        q[3] = .5 * root
        q[:3] = np.array([matrix[1, 2] - matrix[2, 1],
                           matrix[2, 0] - matrix[0, 2], matrix[0, 1] - matrix[1, 0]]) * (.5 / root)
    else:
        i = int(np.argmax(np.diag(matrix)))
        j, k = (i + 1) % 3, (i + 2) % 3
        root = np.sqrt(matrix[i, i] - matrix[j, j] - matrix[k, k] + 1)
        q[i] = .5 * root
        q[3] = (matrix[j, k] - matrix[k, j]) * (.5 / root)
        q[j] = (matrix[i, j] + matrix[j, i]) * (.5 / root)
        q[k] = (matrix[i, k] + matrix[k, i]) * (.5 / root)
    return Rotation.from_quat(q / np.linalg.norm(q)).as_matrix().T


def decompose(matrix):
    scale = np.linalg.norm(matrix[:3, :3], axis=1)
    if np.any(scale < 1e-8):
        raise ValueError('Degenerate serialized instance transform')
    if np.linalg.det(matrix[:3, :3]) < 0:
        scale[0] *= -1
    return scale, rotation_from_rows(matrix[:3, :3] / scale[:, None]), matrix[3, :3]


def compose_physics(instance, parent):
    scale_a, rotation_a, translation_a = decompose(instance)
    scale_b, rotation_b, translation_b = decompose(parent)
    scale = scale_a * scale_b
    result = np.eye(4)
    result[3, :3] = (translation_a * scale_b) @ rotation_b + translation_b
    if np.any(scale_a < 0) or np.any(scale_b < 0):
        linear = (scale_a[:, None] * rotation_a) @ (scale_b[:, None] * rotation_b)
        axes = linear / np.linalg.norm(linear, axis=1)[:, None]
        rotation = rotation_from_rows(np.sign(scale)[:, None] * axes)
    else:
        rotation = rotation_a @ rotation_b
    result[:3, :3] = scale[:, None] * rotation
    return result


@lru_cache(maxsize=32)
def records(path):
    data = Path(path).read_bytes()
    rows = json.loads(data)
    indices = {r['objectIndex']: r for r in rows}
    if len(indices) != len(rows):
        raise ValueError('Duplicate native instance component index')
    return indices, hashlib.sha256(data).hexdigest()


def instance_physics_matrix(root, placement, component, parent, export=None):
    export = export or root/'icebox-native-instance-transforms-v1'
    level = Path(placement['nativeLevel'])
    properties = next(p for p in level.parents if p.name == 'properties')
    relative = level.relative_to(properties)
    extracted = export/'properties'/relative
    if hashlib.sha256(extracted.read_bytes()).hexdigest() != placement['nativeLevelSha256']:
        raise ValueError('Serialized instance matrices belong to a different level revision')
    path = export/'instance-transforms'/relative
    rows, digest = records(str(path))
    row = rows[placement['nativeComponentIndex']]
    if row['name'] != component['Name']:
        raise ValueError('Native instance component identity differs from placement')
    instance = np.array(row['instances'][placement['sourceInstance']]).reshape(4, 4)
    mirror = np.diag([1., -1., 1., 1.])
    physics = compose_physics(mirror @ instance @ mirror, parent)
    return physics, dict(serializedMatrixSource=str(path), serializedMatrixSha256=digest,
        nativeComponentIndex=placement['nativeComponentIndex'], sourceInstance=placement['sourceInstance'],
        method='UE5.3 FTransform(serialized instance matrix) * component transform; normalized quaternion')
