"""Small on-disk completed bake for source-integrity regression tests."""
import gzip
import json
from pathlib import Path

import numpy as np

from seal_world_plane_manifest import digest
from world_visibility_materials import build_policy


def write_json(path, data):
    encoded = json.dumps(data, allow_nan=False).encode()
    Path(path).write_bytes(gzip.compress(encoded, mtime=0) if str(path).endswith('.gz') else encoded)


def completed_fixture(folder):
    folder = Path(folder)
    world = folder / 'world'
    world.mkdir()
    material = world / 'opaque.json'
    write_json(material, {'Parameters': {'BlendMode': 0}})
    record = {'source': str(material), 'sourceSha256': digest(material), 'category': 'opaque', 'blendMode': 0}
    np.savez_compressed(world / 'geometry.npz', points=np.array([[0., 0., 0.], [1., 0., 0.], [0., 1., 0.]]),
                        faces=np.array([[0, 1, 2]], dtype=np.int32), material_indices=np.array([0], dtype=np.int32),
                        uvs=np.zeros((1, 3, 2)))
    source = {'geometrySha256': digest(world / 'geometry.npz'), 'referenceSha256': 'a' * 64, 'navigationSha256': 'b' * 64}
    metadata = {'map': 'split', 'geometrySha256': source['geometrySha256'], 'referenceSha256': source['referenceSha256'],
                'materials': [record], 'uiTransform': {'XMultiplier': -.01, 'YMultiplier': .01, 'XScalarToAdd': 0, 'YScalarToAdd': 0}}
    write_json(world / 'geometry.json', metadata)
    floor = {'map': 'split', 'navigationSha256': source['navigationSha256'], 'geometrySha256': source['geometrySha256'],
             'floorMesh': {'vertices': [0, 0, 0, 1, 0, 0, 0, 1, 0], 'triangles': [0, 0, 1, 2], 'coordinateScale': 1}}
    refinement = {'map': 'split', 'navigationSha256': source['navigationSha256'], 'refinedFloorHeightsCm': [0, 0, 0]}
    write_json(world / 'floor-mesh.json', floor)
    write_json(world / 'floor-refinement.json', refinement)
    navigation = {'map': 'split', 'floorMesh': floor['floorMesh'], 'refinedFloorHeightsCm': [0, 0, 0],
                  'observerHeightCm': 175, 'defaultFloorElevationCm': 0}
    write_json(folder / 'split_navigation.json.gz', navigation)
    row = {'elevationCm': 175, 'segments': 1}
    cache = folder / 'plane.json.gz'
    write_json(cache, {'segments': [[[0, 0], [10, 10]]], 'statistics': row, 'alphaFailures': {}})
    manifest = folder / 'split.planes.json'
    data = {'version': 1, 'map': 'split', 'format': 'plane-cache-v1', 'coordinateScale': 1048576,
            'planarized': True, 'uvUnitsPerMeter': [1, 1], 'observerHeightCm': 175, 'defaultFloorElevationCm': 0,
            'menuElevationsCm': [175], 'source': source,
            'layers': [{'elevationCm': 175, 'globalOrigins': True, 'cacheFile': str(cache)}]}
    write_json(manifest, data)
    write_json(manifest.with_suffix('.audit.json'), {'map': 'split', 'referenceSha256': source['referenceSha256'],
               'alphaSamplingFailures': {}, 'policies': [build_policy(record)], 'layers': [row], 'summary': {'layers': 1}})
    return manifest, world
