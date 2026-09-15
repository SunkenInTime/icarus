import json
from pathlib import Path
import tempfile
import unittest

from seal_world_plane_manifest import read_json, seal_path, seal_plane_manifest, verify_plane_seal
from world_plane_test_fixture import completed_fixture, write_json


class SealTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.manifest, self.world = completed_fixture(self.directory.name)

    def test_completed_output_is_bound_and_labeled_honestly(self):
        seal = seal_plane_manifest(self.manifest, self.world)
        self.assertEqual(seal['attestation'], 'after-the-fact-completed-output-validation')
        self.assertFalse(seal['gameplayCertified'])
        self.assertEqual(verify_plane_seal(self.manifest), seal)
        with self.assertRaisesRegex(ValueError, 'already exists'):
            seal_plane_manifest(self.manifest, self.world)

    def test_mutated_cache_audit_floor_navigation_and_material_all_fail(self):
        seal_plane_manifest(self.manifest, self.world)
        for path in [Path(self.directory.name) / 'plane.json.gz', self.manifest.with_suffix('.audit.json'),
                     self.world / 'floor-mesh.json', Path(self.directory.name) / 'split_navigation.json.gz',
                     self.world / 'opaque.json', self.world / 'geometry.npz']:
            with self.subTest(path=path):
                original = path.read_bytes()
                path.write_bytes(original + b' ')
                with self.assertRaisesRegex(ValueError, 'Sealed input changed'):
                    verify_plane_seal(self.manifest)
                path.write_bytes(original)

    def test_nonempty_cache_alpha_failures_cannot_hide_behind_clean_audit(self):
        path = Path(self.directory.name) / 'plane.json.gz'
        cache = read_json(path)
        cache['alphaFailures'] = {'cell-budget': 1}
        write_json(path, cache)
        with self.assertRaisesRegex(ValueError, 'alpha sampling'):
            seal_plane_manifest(self.manifest, self.world)
        self.assertFalse(seal_path(self.manifest).exists())

    def test_wrong_cache_elevation_and_count_are_rejected(self):
        path = Path(self.directory.name) / 'plane.json.gz'
        original = read_json(path)
        for key, value, reason in [('elevationCm', 176, 'elevation'), ('segments', 2, 'segment count')]:
            cache = json.loads(json.dumps(original))
            cache['statistics'][key] = value
            write_json(path, cache)
            with self.assertRaisesRegex(ValueError, reason):
                seal_plane_manifest(self.manifest, self.world)

    def test_old_policy_interpretation_cannot_be_resealed_as_current(self):
        path = self.manifest.with_suffix('.audit.json')
        audit = read_json(path)
        audit['policies'][0]['mode'] = 'ignore'
        write_json(path, audit)
        with self.assertRaisesRegex(ValueError, 'Current material policies differ'):
            seal_plane_manifest(self.manifest, self.world)

    def test_known_material_source_change_is_not_downgraded_to_solid(self):
        write_json(self.world / 'opaque.json', {'Parameters': {'BlendMode': 5}})
        with self.assertRaisesRegex(ValueError, 'source disagrees'):
            seal_plane_manifest(self.manifest, self.world)

    def test_bundled_floor_and_metric_must_match_source(self):
        path = Path(self.directory.name) / 'split_navigation.json.gz'
        nav = read_json(path)
        nav['floorMesh']['vertices'][2] = 24
        write_json(path, nav)
        with self.assertRaisesRegex(ValueError, 'checked observer floor'):
            seal_plane_manifest(self.manifest, self.world)


if __name__ == '__main__':
    unittest.main()
