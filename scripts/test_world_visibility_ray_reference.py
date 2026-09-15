import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

from world_visibility_ray_reference import (
    eligible_ground_faces, ground_facing_exclusions, ground_override_cast, heldout_origins, load_ground_facing,
    load_ground_support,
    native_floor_overlap_area, nearest_elevation, ray_triangle, sample_alpha,
    validate_reference_lineage,
)


class IndependentRayTests(unittest.TestCase):
    def test_scoped_native_hull_replaces_only_its_parent_and_art_footprint(self):
        floor = np.array([[[0., 0., 0.], [1., 0., 0.], [0., 1., 0.]]])
        override = {'entry': {'file': 'native-hull.npz'}, 'corners': floor + [0, 0, .1],
                    'nativeFaceIds': np.array([7]), 'scopeCorners': floor,
                    'nativeCorners': np.concatenate([floor, floor + [0, 0, 3]]),
                    'nativeParents': np.array([12, 13])}
        hit = ground_override_cast([override], [.25, .25, .12], [0, 0, -1], .04, 12)
        self.assertEqual(hit['hitMeters'], [.25, .25, .1])
        self.assertEqual(hit['nativeHullFace'], 7)
        self.assertEqual(hit['normal'], [0, 0, 1])
        for xy, parent in [([.25, .25], 13), ([.25, .25], 99), ([.75, .75], 12)]:
            self.assertIsNone(ground_override_cast([override], [*xy, .12], [0, 0, -1], .04, parent))
        # Inside the override footprint, missing a too-short ray must not
        # fall through to the obsolete Art floor beneath the true hull.
        miss = ground_override_cast([override], [.25, .25, .02], [0, 0, -1], .04, 12)
        self.assertIsNotNone(miss)
        self.assertIsNone(miss['hitMeters'])
        with self.assertRaises(ValueError):
            ground_override_cast([override], [.25, .25, .12], [0, 0, -1], .04, None)
        outside_window = {**override, 'scopeCorners': floor + [0, 0, .5]}
        self.assertIsNone(ground_override_cast([outside_window], [.25, .25, .12], [0, 0, -1], .04, 12))

    def test_selective_support_changes_only_proven_authored_ranges(self):
        points = np.array([[0., 0., 1.], [-1., 0., 1.], [0., 1., 1.]], dtype=np.float32)
        faces, ids = np.array([[0, 1, 2], [0, 1, 2], [0, 2, 1]]), np.zeros(3, dtype=int)
        signs, materials = np.array([-1, -1, -1], dtype=np.int8), [{'category': 'opaque'}]
        support = {'_authoredMask': np.array([True, False, False]), '_excludedMask': np.zeros(3, dtype=bool)}
        np.testing.assert_array_equal(eligible_ground_faces(points, faces, ids, materials, signs, support=support), [0, 2])
        np.testing.assert_array_equal(eligible_ground_faces(points.astype(float), faces, ids, materials,
                                                           signs, support=support), [0, 2])

    def test_selective_support_requires_exact_native_evidence_and_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            metadata, floor = self.facing_fixture(folder, np.array([1, -1], dtype=np.int8))
            _, facing = load_ground_facing(folder, metadata, floor, 'base', 2)
            proof = {'schemaVersion': 1, 'status': 'native-pawn-support-evidence', 'maps': [
                {'map': 'split', 'nativeCandidateGeometrySha256': 'base', 'placements': [
                    {'firstFace': 0, 'faceCount': 1, 'classification': 'declared-pawn-blocking-complex'}]}]}
            (folder / 'native-proof.json').write_text(json.dumps(proof))
            support = {'schemaVersion': 1, 'map': 'split', 'geometrySha256': 'base', 'faceCount': 2,
                       'defaultMode': 'baseline-geometric-winding', 'baselinePointsDtype': 'float32',
                       'sourceProofFile': 'native-proof.json',
                       'sourceProofSha256': hashlib.sha256((folder / 'native-proof.json').read_bytes()).hexdigest(),
                       'authoredFacingRanges': [{'firstFace': 0, 'faceCount': 1, 'reason': 'native complex support',
                                                'sourceRecordId': 'split:0'}]}
            def load(document):
                path = folder / 'ground-support.json'; path.write_text(json.dumps(document))
                sha = hashlib.sha256(path.read_bytes()).hexdigest()
                return load_ground_support(folder, {**metadata, 'groundSupport': {'file': path.name, 'sha256': sha}},
                                           {**floor, 'groundSupportSha256': sha}, 'base', 2, facing)
            result, info = load(support)
            np.testing.assert_array_equal(result['_authoredMask'], [True, False])
            self.assertEqual(info['authoredFacingFaces'], 1)
            for changed in (
                {**support, 'sourceProofSha256': 'wrong'},
                {**support, 'baselinePointsDtype': 'float64'},
                {**support, 'geometrySha256': 'unrelated'},
                {**support, 'authoredFacingRanges': [{**support['authoredFacingRanges'][0], 'firstFace': 1}]},
                {**support, 'authoredFacingRanges': [{**support['authoredFacingRanges'][0], 'sourceRecordId': 'split:1'}]},
                {**support, 'authoredFacingRanges': support['authoredFacingRanges'] * 2},
            ):
                with self.subTest(support=changed), self.assertRaises(ValueError):
                    load(changed)

    def test_native_floor_domain_replay_respects_sloped_height_window(self):
        native = np.array([[0., 0., 0.], [2., 0., 2.], [0., 2., 0.]])
        triangle = native.copy()
        self.assertAlmostEqual(native_floor_overlap_area(triangle, native), 2)
        self.assertAlmostEqual(native_floor_overlap_area(triangle, native[::-1]), 2)
        triangle[:, 2] += .30002
        self.assertEqual(native_floor_overlap_area(triangle, native), 0)
        triangle[:, 2] -= .90004
        self.assertEqual(native_floor_overlap_area(triangle, native), 0)
        # This horizontal face passes through the sloped native floor window.
        # Its global height is not sufficient to decide local admission.
        triangle[:, 2] = 1
        self.assertGreater(native_floor_overlap_area(triangle, native), 0)
        self.assertLess(native_floor_overlap_area(triangle, native), 2)

    def test_ground_domain_exclusions_replay_geometry_and_reject_false_proofs(self):
        native = np.array([[[0., 0., 0.], [1., 0., 0.], [0., 1., 0.]]])
        points = np.concatenate([native[0] + [0, 0, 1], native[0] + [2, 0, 0], native[0]])
        faces = np.arange(9).reshape(3, 3)
        ids, materials = np.zeros(3, dtype=int), [{'category': 'opaque'}]
        def record(index):
            return {'sourceFace': index, 'triangleMeters': points[faces[index]].tolist()}
        proof = {'groundExcludedOutsideHeightFaces': [record(0)],
                 'groundExcludedOutsideDomainFaces': [record(1)]}
        excluded, counts = ground_facing_exclusions(proof, points, faces, ids, materials, 3,
                                                    native_triangles=native)
        self.assertEqual(excluded, [0, 1])
        self.assertEqual(counts['outsideDomainFaces'], 1)
        for invalid in (
            {'groundExcludedOutsideHeightFaces': [record(2)]},
            {'groundExcludedOutsideDomainFaces': [record(2)]},
            {'groundExcludedOutsideDomainFaces': [{**record(1), 'triangleMeters': record(0)['triangleMeters']}]},
        ):
            with self.subTest(proof=invalid), self.assertRaises(ValueError):
                ground_facing_exclusions(invalid, points, faces, ids, materials, 3, native_triangles=native)
        with self.assertRaises(ValueError):
            ground_facing_exclusions(proof, points, faces, ids, materials, 3)

    def test_facing_exclusions_cannot_hide_real_ground_surfaces(self):
        points = np.array([[0., 0., 0.], [.0001, 0., 0.], [0., .0001, 0.],
                           [0., 0., 0.], [1., 0., 0.], [0., 1., 0.]])
        faces = np.array([[0, 1, 2], [3, 4, 5], [3, 4, 5]])
        ids = np.array([0, 0, 1])
        materials = [{'category': 'opaque'}, {'category': 'masked'}]
        proof = {'groundExcludedSubthresholdFaces': [{'sourceFace': 0, 'areaSquareMeters': 5e-9}],
                 'groundExcludedSingularRanges': [{'firstFace': 2, 'faceCount': 1}]}
        excluded, counts = ground_facing_exclusions(proof, points, faces, ids, materials, 3)
        self.assertEqual(excluded, [0, 2])
        self.assertEqual(counts['subthresholdFaces'], 1)
        np.testing.assert_array_equal(eligible_ground_faces(
            points, faces, ids, materials, np.ones(3, dtype=np.int8), excluded), [1])
        for invalid in (
            {'groundExcludedSubthresholdFaces': [{'sourceFace': 1, 'areaSquareMeters': 5e-9}]},
            {'degenerateSourceFaces': [1]},
            {'groundExcludedSingularRanges': [{'firstFace': 1, 'faceCount': 1}]},
            {'groundExcludedSingularRanges': [{'firstFace': 2, 'faceCount': 2}]},
            {'degenerateSourceFaces': [True]},
        ):
            with self.subTest(proof=invalid), self.assertRaises(ValueError):
                ground_facing_exclusions(invalid, points, faces, ids, materials, 3)

    def facing_fixture(self, folder, signs, **changes):
        signs_path = folder / 'ground-facing.npz'
        np.savez_compressed(signs_path, facingSigns=signs)
        sidecar = {'schemaVersion': 1, 'map': 'split', 'geometrySha256': 'base',
                   'faceCount': len(signs), 'dtype': 'int8', 'signsFile': signs_path.name,
                   'signsSha256': hashlib.sha256(signs_path.read_bytes()).hexdigest(),
                   'meaning': 'authored-front-normal = geometric-cross * facingSign', **changes}
        path = folder / 'ground-facing.json'
        path.write_text(json.dumps(sidecar))
        fingerprint = hashlib.sha256(path.read_bytes()).hexdigest()
        return ({'map': 'split', 'groundFacing': {'file': path.name, 'sha256': fingerprint}},
                {'geometrySha256': 'base', 'groundFacingSha256': fingerprint})

    def test_ground_facing_restores_mirrored_top_and_rejects_underside_and_mask(self):
        points = np.array([[0., 0., 1.], [-1., 0., 1.], [0., 1., 1.]])
        faces = np.array([[0, 1, 2], [0, 2, 1], [0, 1, 2], [0, 1, 2], [0, 2, 1]])
        materials = [{'category': 'opaque'}, {'category': 'masked'}, {'category': 'unresolved'}]
        ids = np.array([0, 0, 1, 2, 0])
        np.testing.assert_array_equal(eligible_ground_faces(points, faces, ids, materials), [1, 4])
        # Only the four validated Art faces participate in standing ground.
        signs = np.array([-1, -1, -1, -1], dtype=np.int8)
        np.testing.assert_array_equal(eligible_ground_faces(points, faces, ids, materials, signs), [0, 3])

    def test_authored_slope_is_identical_after_exact_art_dtype_promotion(self):
        # A triangle beside the slope cutoff changes the float32 comparison.
        # Both Art-only and combined sources must apply the v3 predicate alike.
        points = np.array([[-4.902409076690674, 1.2593454122543335, -1.6077028512954712],
                           [-4.902409076690674, 2.004781484603882, -1.6077028512954712],
                           [-2.5339763164520264, 1.2593454122543335, 1.161302089691162]], dtype=np.float32)
        faces, ids = np.array([[0, 2, 1]]), np.array([0])
        materials, signs = [{'category': 'opaque'}], np.array([1], dtype=np.int8)
        original = eligible_ground_faces(points, faces, ids, materials, signs)
        promoted = eligible_ground_faces(points.astype(float), faces, ids, materials, signs)
        np.testing.assert_array_equal(original, promoted)
        self.assertEqual(len(original), 0)

    def test_ground_facing_requires_hashed_shape_and_composition_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            metadata, floor = self.facing_fixture(folder, np.array([1, -1], dtype=np.int8))
            signs, info = load_ground_facing(folder, metadata, floor, 'base', 2)
            np.testing.assert_array_equal(signs, [1, -1])
            self.assertEqual(info['mode'], 'authored-source-facing')
            self.assertEqual(info['excludedSupplementalFaces'], 0)
            combined = {**metadata, 'baseGeometrySha256': 'base',
                        'status': 'corrected-art-with-approved-static-scenery',
                        'groundFacing': {**metadata['groundFacing'], 'scope': 'base-art'},
                        'supplementation': {'baseArtValuesPreservedExactly': True, 'baseArtFaceCount': 2}}
            _, info = load_ground_facing(folder, combined, floor, 'combined', 5)
            self.assertEqual(info['excludedSupplementalFaces'], 3)
            self.assertEqual(info['scope'], 'base-art')
            for changed in (
                {**combined, 'baseGeometrySha256': 'unrelated'},
                {**combined, 'groundFacing': metadata['groundFacing']},
                {**combined, 'supplementation': {'baseArtValuesPreservedExactly': True, 'baseArtFaceCount': 3}},
            ):
                with self.subTest(metadata=changed), self.assertRaises(ValueError):
                    load_ground_facing(folder, changed, floor, 'combined', 5)
            with self.assertRaises(ValueError):
                load_ground_facing(folder, metadata, floor, 'base', 3)
            with self.assertRaises(ValueError):
                load_ground_facing(folder, metadata, {**floor, 'groundFacingSha256': 'wrong'}, 'base', 2)
            with self.assertRaises(ValueError):
                load_ground_facing(folder, {}, floor, 'base', 2)
            (folder / 'ground-facing.npz').write_bytes(b'corrupted archive')
            with self.assertRaises(ValueError):
                load_ground_facing(folder, metadata, floor, 'base', 2)

    def test_ground_facing_rejects_wrong_array_encoding_even_with_valid_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for signs in (np.array([1, 0], dtype=np.int8), np.array([1, -1], dtype=np.int32),
                          np.array([[1], [-1]], dtype=np.int8)):
                metadata, floor = self.facing_fixture(folder, signs)
                with self.subTest(signs=signs), self.assertRaises(ValueError):
                    load_ground_facing(folder, metadata, floor, 'base', 2)
            metadata, floor = self.facing_fixture(folder, np.array([1, -1], dtype=np.int8), signsFile='../outside.npz')
            with self.assertRaises(ValueError):
                load_ground_facing(folder, metadata, floor, 'base', 2)

    def test_reference_accepts_only_verified_supplement_floor_lineage(self):
        metadata = {'geometrySha256': 'combined', 'baseGeometrySha256': 'base',
                    'supplementGeometrySha256': 'extra',
                    'status': 'corrected-art-with-approved-static-scenery',
                    'supplementation': {'baseArtValuesPreservedExactly': True,
                        'floorFilesPreservedSha256': {'floor-mesh.json': 'floor'}}}
        floor = {'geometrySha256': 'base'}
        validate_reference_lineage(metadata, floor, 'combined', 'floor')
        validate_reference_lineage({'geometrySha256': 'base'}, floor, 'base', 'floor')
        for changed in (
            {**metadata, 'status': 'unreviewed'},
            {**metadata, 'baseGeometrySha256': 'other'},
            {**metadata, 'supplementGeometrySha256': None},
            {**metadata, 'supplementation': {}},
        ):
            with self.subTest(metadata=changed), self.assertRaises(ValueError):
                validate_reference_lineage(changed, floor, 'combined', 'floor')
        for geometry_hash, floor_hash in [('corrupt', 'floor'), ('combined', 'corrupt')]:
            with self.subTest(hashes=(geometry_hash, floor_hash)), self.assertRaises(ValueError):
                validate_reference_lineage(metadata, floor, geometry_hash, floor_hash)
        changed = copy.deepcopy(metadata)
        changed['supplementation']['baseArtValuesPreservedExactly'] = False
        with self.assertRaises(ValueError):
            validate_reference_lineage(changed, floor, 'combined', 'floor')

    def test_nearest_elevation_uses_lower_ties_and_clamps_endpoints(self):
        self.assertEqual(nearest_elevation([175, 180, 190], 177.5), 175)
        self.assertEqual(nearest_elevation([175, 180, 190], 177.5001), 180)
        self.assertEqual(nearest_elevation([175, 180, 190], 100), 175)
        self.assertEqual(nearest_elevation([175, 180, 190], 200), 190)

    def test_summit_clipped_floor_origin_requires_double_precision(self):
        # Source face670032: this real clipped sliver exposed the float32 BVH
        # miss. Preserve the original ray; moving it onto the floor would hide
        # the numerical problem instead of verifying the supplied origin.
        triangle = np.array([
            [33.631046295166016, -83.9839096069336, 2.109072685241699],
            [33.5687141418457, -84.00000762939453, 2.1372244358062744],
            [33.642391204833984, -84.01136779785156, 2.1080777645111084],
        ])
        origin = np.array([33.601601288047625, -84.00507739076744, 2.1442119367399552])
        direction = np.array([0., 0., -1.])
        result = ray_triangle(origin, direction, triangle)
        self.assertIsNotNone(result)
        self.assertGreater(min(result[1]), 0)
        self.assertAlmostEqual(origin[2] - result[0], 2.12421412496, places=10)
        self.assertIsNone(ray_triangle(origin.astype(np.float32).astype(float), direction, triangle))

    def test_bilinear_alpha_and_wraps(self):
        pixels = np.array([[0, 1], [1, 0]], dtype=float)
        policy = {'wrapS': 'repeat', 'wrapT': 'repeat', 'alphaScale': 1, 'alphaBias': 0}
        self.assertEqual(sample_alpha(pixels, [.25, .25], policy), 0)
        self.assertEqual(sample_alpha(pixels, [.75, .25], policy), 1)
        self.assertEqual(sample_alpha(pixels, [.5, .5], policy), .5)
        self.assertEqual(sample_alpha(pixels, [1.75, .25], policy), 1)
        self.assertEqual(sample_alpha(pixels, [-.25, .25], policy), 1)
        self.assertEqual(sample_alpha(pixels, [1.75, .25], {**policy, 'wrapS': 'mirror'}), 0)
        self.assertEqual(sample_alpha(pixels, [-.25, .25], {**policy, 'wrapS': 'clamp'}), 0)
        self.assertEqual(sample_alpha(pixels, [-.25, .25], {**policy, 'wrapS': 'black', 'alphaBias': .2}), .2)
        self.assertEqual(sample_alpha(pixels, [.5, .5], {**policy, 'alphaScale': .5, 'alphaBias': .1}), .35)

    def test_triangle_intersection_checks_both_windings_and_barycentrics(self):
        triangle = np.array([[5, -1, -1], [5, 1, -1], [5, 0, 1]], dtype=float)
        origin, direction = np.zeros(3), np.array([1, 0, 0])
        for vertices in [triangle, triangle[::-1]]:
            result = ray_triangle(origin, direction, vertices)
            self.assertIsNotNone(result)
            distance, weights = result
            self.assertAlmostEqual(distance, 5)
            np.testing.assert_allclose(np.asarray(weights) @ vertices, [5, 0, 0])
        self.assertIsNone(ray_triangle(origin, -direction, triangle))

    def test_heldout_origins_are_reproducible_interiors_on_real_floor_plane(self):
        mesh = {'coordinateScale': 100, 'vertices': [0, 0, 0, 100, 0, 100, 0, 100, 0],
                'triangles': [17, 0, 1, 2]}
        ui = {'XMultiplier': .01, 'YMultiplier': .01, 'XScalarToAdd': 0, 'YScalarToAdd': 0}
        rows = heldout_origins(mesh, ui, 8, 274)
        self.assertEqual(rows, heldout_origins(mesh, ui, 8, 274))
        for row in rows:
            x, y, z = row['positionMeters']
            self.assertEqual(row['parentNavPolygon'], 17)
            self.assertTrue(all(0 < weight < 1 for weight in row['barycentric']))
            self.assertAlmostEqual(z, -y)
            self.assertGreater(x, 0)

    def test_floor_overlap_keeps_highest_surface_per_parent_and_stacked_alternatives(self):
        mesh = {'coordinateScale': 100,
                'vertices': [0, 0, 0, 100, 0, 0, 0, 100, 0,
                             0, 0, 200, 100, 0, 200, 0, 100, 200,
                             0, 0, 400, 100, 0, 400, 0, 100, 400],
                'triangles': [17, 0, 1, 2, 17, 3, 4, 5, 18, 6, 7, 8]}
        ui = {'XMultiplier': .01, 'YMultiplier': .01, 'XScalarToAdd': 0, 'YScalarToAdd': 0}
        for row in heldout_origins(mesh, ui, 16, 284):
            self.assertAlmostEqual(row['positionMeters'][2], 2 if row['parentNavPolygon'] == 17 else 4)
            self.assertEqual([v['floorHeightCm'] for v in row['floorAlternatives']], [200, 400])


if __name__ == '__main__':
    unittest.main()
