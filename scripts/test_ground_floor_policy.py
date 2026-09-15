import json
from pathlib import Path
import tempfile
import unittest

import numpy as np
import shapely

from bake_navigation_floors import bake, plane
from ground_floor_policy import FloorOverrides, digest, ground_policy_mask


def write_json(path, data):
    path.write_text(json.dumps(data))
    return digest(path)


class GroundFloorPolicyTest(unittest.TestCase):
    def test_native_proof_limits_authored_correction_to_approved_placement(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            raw = {'points': np.array([[0., 0., 0.], [-1., 0., 0.], [0., 1., 0.]], dtype=np.float32),
                   'faces': np.array([[0, 1, 2], [0, 1, 2], [0, 2, 1]]),
                   'material_indices': np.zeros(3, dtype=int)}
            navigation = folder / 'native.json'
            write_json(navigation, {'navigationSha256': 'native'})
            np.savez_compressed(folder / 'signs.npz', facingSigns=np.array([-1, -1, -1], dtype=np.int8))
            facing = {'schemaVersion': 1, 'map': 'test', 'geometrySha256': 'geometry', 'faceCount': 3,
                      'dtype': 'int8', 'signsFile': 'signs.npz', 'signsSha256': digest(folder/'signs.npz'),
                      'meaning': 'authored-front-normal = geometric-cross * facingSign'}
            proof = {'maps': [{'map': 'test', 'nativeCandidateGeometrySha256': 'geometry',
                              'placements': [{'firstFace': 0, 'faceCount': 1,
                                              'classification': 'declared-pawn-blocking-complex'}]}]}
            support = {'schemaVersion': 1, 'map': 'test', 'geometrySha256': 'geometry', 'faceCount': 3,
                       'sourceNavigationXYZSha256': digest(navigation),
                       'sourceProofFile': 'proof.json', 'sourceProofSha256': write_json(folder/'proof.json', proof),
                       'defaultMode': 'baseline-geometric-winding', 'baselinePointsDtype': 'float32',
                       'authoredFacingRanges': [{'firstFace': 0, 'faceCount': 1, 'sourceRecordId': 'test:0'}]}
            metadata = {'map': 'test', 'geometrySha256': 'geometry', 'materials': [{'category': 'opaque'}],
                        'groundFacing': {'file': 'facing.json', 'sha256': write_json(folder/'facing.json', facing)}}

            def evaluate(document):
                metadata['groundSupport'] = {'file': 'support.json', 'sha256': write_json(folder/'support.json', document)}
                return ground_policy_mask(folder, metadata, raw, navigation)[0]

            np.testing.assert_array_equal(evaluate(support), [True, False, True])
            for changed in (
                {**support, 'authoredFacingRanges': [{'firstFace': 1, 'faceCount': 1, 'sourceRecordId': 'test:1'}]},
                {**support, 'sourceProofSha256': 'wrong'},
                {**support, 'authoredFacingRanges': [{'firstFace': 0, 'faceCount': 2, 'sourceRecordId': 'test:0'}]},
            ):
                with self.subTest(changed=changed), self.assertRaises(ValueError):
                    evaluate(changed)

    def test_override_requires_both_art_and_native_height_scope(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            native = np.array([[0., 0., 0.], [1., 0., 0.], [0., 1., 0.]])
            hull = native + [0, 0, .1]
            np.savez_compressed(folder/'hull.npz', points=hull, faces=np.array([[0, 1, 2]]))
            proof_hash = write_json(folder/'proof.json', {})
            support = {'overrideFloorMeshes': [{'file': 'hull.npz', 'sha256': digest(folder/'hull.npz'),
                'sourceProofFile': 'proof.json', 'sourceProofSha256': proof_hash,
                'scopeArtFaces': [0], 'parentNavPolygons': [7]}]}
            raw = {'points': native + [0, 0, .2], 'faces': np.array([[0, 1, 2]])}
            pieces = FloorOverrides(folder, raw, support).pieces(7, native)
            self.assertAlmostEqual(sum(p.area for _, p in pieces), .5)
            self.assertAlmostEqual(pieces[0][0][2], .1)
            self.assertEqual(FloorOverrides(folder, raw, support).pieces(8, native), [])
            self.assertEqual(FloorOverrides(folder, raw, support).pieces(7, native+[0, 0, 3]), [])
            # The hull remains in the native window, but the Art face that
            # authorizes replacement no longer belongs to this floor stratum.
            raw['points'] += [0, 0, .2]
            self.assertEqual(FloorOverrides(folder, raw, support).pieces(7, native), [])

    def test_baked_hull_replaces_old_height_only_inside_local_scope(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            points, faces = [], []
            for x1, x2, z in [(0, 1, .2), (1, 2, .2), (0, 2, 3.)]:
                first = len(points)
                points.extend([(x1, 0, z), (x2, 0, z), (x2, 2, z), (x1, 2, z)])
                faces.extend([(first, first+1, first+2), (first, first+2, first+3)])
            np.savez_compressed(folder/'geometry.npz', points=np.array(points, dtype=np.float32),
                                faces=np.array(faces), material_indices=np.zeros(len(faces), dtype=int))
            geometry_hash = digest(folder/'geometry.npz')
            nav = {'map': 'test', 'navigationSha256': 'native',
                   'vertices': [0, 0, 15, 200, 0, 15, 200, -200, 15, 0, -200, 15,
                                0, 0, 300, 200, 0, 300, 200, -200, 300, 0, -200, 300],
                   'triangles': [7, 0, 1, 2, 7, 0, 2, 3, 8, 4, 5, 6, 8, 4, 6, 7]}
            navigation = folder/'native.json'; write_json(navigation, nav)
            proof = {'maps': [{'map': 'test', 'nativeCandidateGeometrySha256': geometry_hash, 'placements': []}]}
            np.savez_compressed(folder/'hull.npz', points=np.array([(0, 0, .1), (2, 0, .1), (2, 2, .1), (0, 2, .1)]),
                                faces=np.array([[0, 1, 2], [0, 2, 3]]))
            support = {'schemaVersion': 1, 'map': 'test', 'geometrySha256': geometry_hash, 'faceCount': len(faces),
                       'sourceNavigationXYZSha256': digest(navigation),
                       'sourceProofFile': 'proof.json', 'sourceProofSha256': write_json(folder/'proof.json', proof),
                       'defaultMode': 'baseline-geometric-winding', 'baselinePointsDtype': 'float32',
                       'authoredFacingRanges': [], 'overrideFloorMeshes': [
                           {'file': 'hull.npz', 'sha256': digest(folder/'hull.npz'), 'sourceProofFile': 'proof.json',
                            'sourceProofSha256': digest(folder/'proof.json'), 'scopeArtFaces': [0, 1], 'parentNavPolygons': [7]}]}
            metadata = {'map': 'test', 'geometrySha256': geometry_hash, 'materials': [{'category': 'opaque'}],
                        'uiTransform': {'XMultiplier': .001, 'XScalarToAdd': .5, 'YMultiplier': -.001, 'YScalarToAdd': .5},
                        'groundSupport': {'file': 'support.json', 'sha256': write_json(folder/'support.json', support)}}
            write_json(folder/'geometry.json', metadata)
            report = bake(folder, navigation, folder/'floor.json')['floorMesh']
            vertices = np.asarray(report['vertices']).reshape(-1, 3).astype(float)
            uv = vertices[:, :2].copy()/report['coordinateScale']
            vertices[:, 0] = (uv[:, 1]-.5)/-.1
            vertices[:, 1] = -(uv[:, 0]-.5)/.1
            triangles = np.asarray(report['triangles']).reshape(-1, 4)

            def heights(x, y, parent):
                values = []
                for p, *ids in triangles:
                    xyz = vertices[ids]
                    if p == parent and shapely.Polygon(xyz[:, :2]).covers(shapely.Point(x, y)):
                        values.append(round(float(plane(xyz) @ [x, y, 1]), 6))
                return set(values)

            self.assertEqual(heights(.3, .7, 7), {10.})
            self.assertEqual(heights(1.3, .7, 7), {20.})
            self.assertEqual(heights(.3, .7, 8), {300.})


if __name__ == '__main__':
    unittest.main()
