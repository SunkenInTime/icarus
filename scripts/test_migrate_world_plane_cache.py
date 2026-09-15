import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

from migrate_world_plane_cache import changed_faces, intersects_changed_height, migrate, require_same_array, require_same_sampling, changed_height_intervals, height_is_changed
from world_geometry_bake import bake, digest


class PlaneCacheMigrationTests(unittest.TestCase):
    def test_policy_builder_can_change_but_section_sampler_cannot(self):
        with tempfile.TemporaryDirectory() as directory:
            old, new = Path(directory) / 'old.py', Path(directory) / 'new.py'
            old.write_text('def build_policy(): return 1\ndef clip(): return 2\n')
            new.write_text('def build_policy(): return 3\ndef clip(): return 2\n')
            require_same_sampling(old, new)
            new.write_text('def build_policy(): return 3\ndef clip(): return 4\n')
            with self.assertRaisesRegex(ValueError, 'sampling code changed'):
                require_same_sampling(old, new)

    def test_confidence_changes_preserve_solid_geometry_but_alpha_changes_do_not(self):
        before = [{'mode': 'solid', 'certain': False}, {'mode': 'alpha-test', 'threshold': .2}]
        after = [{'mode': 'solid', 'certain': True}, {'mode': 'alpha-test', 'threshold': .3}]
        np.testing.assert_equal(changed_faces(np.array([0, 1]), np.array([0, 1]), before, after), [False, True])

    def test_identical_mask_bytes_and_sampling_survive_material_alias_changes(self):
        before = {'mode': 'alpha-test', 'alphaTextureSha256': 'a' * 64, 'threshold': .3,
                  'wrapS': 'repeat', 'wrapT': 'clamp', 'source': 'old', 'certain': False}
        after = {**before, 'source': 'new', 'blenderName': 'native', 'certain': True,
                 'alphaScale': 1., 'alphaBias': 0.}
        np.testing.assert_equal(changed_faces(np.array([0]), np.array([0]), [before], [after]), [False])
        for field, value in (('alphaTextureSha256', 'b' * 64), ('wrapT', 'repeat'),
                             ('threshold', .4), ('alphaScale', .9), ('textureAlphaRange', [0, 255])):
            np.testing.assert_equal(changed_faces(np.array([0]), np.array([0]), [before], [{**after, field: value}]), [True])

    def test_merged_height_ranges_match_direct_float32_and_float64_sections(self):
        random = np.random.default_rng(36)
        for dtype in (np.float32, np.float64):
            triangles = random.uniform(-10, 10, (90, 3, 3)).astype(dtype)
            intervals = changed_height_intervals(triangles)
            probes = list(random.uniform(-1500, 1500, 100)) + (triangles[:, :, 2].reshape(-1) * 100).tolist()
            for elevation in probes:
                self.assertEqual(height_is_changed(intervals, dtype, elevation),
                                 intersects_changed_height(triangles, elevation))

    def test_height_test_keeps_exact_edges_and_float32_scalar_semantics(self):
        tri = np.array([[[0, 0, 6.7], [1, 0, 6.7], [1, 1, 6.6]]], dtype=np.float32)
        self.assertTrue(intersects_changed_height(tri, 670))
        self.assertFalse(intersects_changed_height(tri, 670.001))
        self.assertFalse(intersects_changed_height(np.empty((0, 3, 3)), 670))

    def test_source_dtype_and_uv_changes_refuse_migration(self):
        with self.assertRaisesRegex(ValueError, 'changed'):
            require_same_array(np.array([1.0], dtype=np.float32), np.array([1.0], dtype=np.float64), 'points')
        with self.assertRaisesRegex(ValueError, 'changed'):
            require_same_array(np.array([1.0]), np.array([1.00001]), 'uvs')

    def test_reused_cache_names_match_real_baker_and_changed_plane_is_recomputed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old, new = root / 'old', root / 'new'
            old.mkdir()
            new.mkdir()
            nav = {'map': 'split', 'coordinateScale': 1000,
                   'vertices': [0, 0, 0, 1000, 0, 100, 0, 1000, 0],
                   'polygons': [[0, 1, 2]], 'triangles': [0, 0, 1, 2], 'walkable': [True]}
            nav_path = root / 'navigation.json'
            nav_path.write_text(json.dumps(nav))
            for folder in (old, new):
                np.savez(folder / 'geometry.npz',
                         points=np.array([[.2, .2, .5], [.8, .2, .5], [.8, .2, 1.5],
                                          [.4, .1, 0], [.4, .8, 0], [.4, .8, 3]], dtype=np.float32),
                         faces=np.array([[0, 1, 2], [3, 4, 5]], dtype=np.int32),
                         uvs=np.zeros((2, 3, 2), dtype=np.float32),
                         material_indices=np.array([0, 1], dtype=np.int32))
                metadata = {'map': 'split', 'geometrySha256': digest(folder / 'geometry.npz'),
                            'referenceSha256': 'fixture',
                            'uiTransform': {'XMultiplier': -.01, 'YMultiplier': .01,
                                            'XScalarToAdd': 0, 'YScalarToAdd': 0},
                            'materials': [{'fixtureMaterial': 0}, {'fixtureMaterial': 1}]}
                (folder / 'geometry.json').write_text(json.dumps(metadata))
                (folder / 'floor-refinement.json').write_text(json.dumps({
                    'navigationSha256': digest(nav_path), 'refinedFloorHeightsCm': [0, 100, 0]}))
                (folder / 'floor-mesh.json').write_text(json.dumps({
                    'navigationSha256': digest(nav_path), 'geometrySha256': metadata['geometrySha256'],
                    'floorMesh': {'vertices': nav['vertices'], 'triangles': nav['triangles']}}))
            elevations = root / 'elevations.json'
            elevations.write_text('[100,200]')
            original = root / 'original.planes.json'
            repaired = root / 'repaired.planes.json'

            def old_policy(record, **unused):
                return {'mode': 'solid', 'certain': True, 'reason': 'fixture'}

            def new_policy(record, **unused):
                return {'mode': 'ignore' if record['fixtureMaterial'] == 0 else 'solid',
                        'certain': True, 'reason': 'fixture'}

            with contextlib.redirect_stdout(io.StringIO()):
                with patch('world_visibility_materials.build_policy', old_policy):
                    bake(old, nav_path, original, eye_height_cm=100, only_elevations=[100, 200], cache_only=True)
                with patch('migrate_world_plane_cache.build_policy', new_policy):
                    report = migrate(original, old, new, nav_path, elevations, root / 'migration.json')
                self.assertEqual(report['recomputedPlanes'], 1)
                self.assertEqual(report['reusedPlanes'], 1)
                targets = {row['elevationCm']: Path(row['target']) for row in report['layers']}
                self.assertFalse(targets[100].exists())
                self.assertTrue(targets[200].exists())
                reused_bytes = targets[200].read_bytes()
                with patch('world_visibility_materials.build_policy', new_policy):
                    bake(new, nav_path, repaired, eye_height_cm=100, only_elevations=[100, 200], cache_only=True)
                actual = json.loads(repaired.read_bytes())
                self.assertEqual([Path(row['cacheFile']) for row in actual['layers']], list(targets.values()))
                self.assertEqual(targets[200].read_bytes(), reused_bytes)
                self.assertTrue(targets[100].exists())
                floor = json.loads((new / 'floor-mesh.json').read_bytes())
                floor['floorMesh']['vertices'][2] += 1
                (new / 'floor-mesh.json').write_text(json.dumps(floor))
                with patch('migrate_world_plane_cache.build_policy', new_policy):
                    changed_floor = migrate(original, old, new, nav_path, elevations, root / 'changed-floor.json')
                self.assertTrue(changed_floor['standingFloorsChanged'])
                self.assertEqual(changed_floor['reusedPlanes'], 1)
                self.assertFalse(any(row['observerDomainChanged'] for row in changed_floor['layers']))

    def test_floor_changes_reuse_only_identical_domains_and_real_baker_recomputes_the_rest(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            root = Path(directory)
            old, new = root / 'old', root / 'new'
            vertices = []
            for index, height in enumerate((0, 100, 200)):
                for x, y in ((0, 0), (1000, 0), (0, 1000)):
                    vertices.extend((x + index * 2000, y, height))
            nav = {'map': 'split', 'coordinateScale': 1000, 'vertices': vertices,
                   'polygons': [[0, 1, 2], [3, 4, 5], [6, 7, 8]],
                   'triangles': [0, 0, 1, 2, 1, 3, 4, 5, 2, 6, 7, 8], 'walkable': [True] * 3}
            nav_path = root / 'navigation.json'
            nav_path.write_text(json.dumps(nav))
            for folder in (old, new):
                folder.mkdir()
                np.savez(folder / 'geometry.npz',
                         points=np.array([[.2, .2, 0], [.8, .2, 0], [.8, .2, 4]], dtype=np.float32),
                         faces=np.array([[0, 1, 2]], dtype=np.int32), uvs=np.zeros((1, 3, 2), dtype=np.float32),
                         material_indices=np.array([0], dtype=np.int32))
                metadata = {'map': 'split', 'geometrySha256': digest(folder / 'geometry.npz'),
                            'referenceSha256': 'fixture', 'materials': [{}],
                            'uiTransform': {'XMultiplier': -.01, 'YMultiplier': .01,
                                            'XScalarToAdd': 0, 'YScalarToAdd': 0}}
                (folder / 'geometry.json').write_text(json.dumps(metadata))
                floor_vertices = list(vertices)
                if folder == new:
                    for index in (3, 4, 5):
                        floor_vertices[index * 3 + 2] = 180
                (folder / 'floor-refinement.json').write_text(json.dumps({
                    'navigationSha256': digest(nav_path), 'refinedFloorHeightsCm': floor_vertices[2::3]}))
                (folder / 'floor-mesh.json').write_text(json.dumps({
                    'navigationSha256': digest(nav_path), 'geometrySha256': metadata['geometrySha256'],
                    'floorMesh': {'vertices': floor_vertices, 'triangles': nav['triangles']}}))
            elevations = [100, 200, 300]
            elevations_path = root / 'elevations.json'
            elevations_path.write_text(json.dumps(elevations))
            original, repaired = root / 'original.planes.json', root / 'repaired.planes.json'
            policy = {'mode': 'solid', 'certain': True, 'reason': 'fixture'}
            with patch('world_visibility_materials.build_policy', return_value=policy):
                bake(old, nav_path, original, eye_height_cm=100, only_elevations=elevations, cache_only=True)
            with patch('migrate_world_plane_cache.build_policy', return_value=policy):
                report = migrate(original, old, new, nav_path, elevations_path, root / 'migration.json')
            self.assertEqual(report['reusedPlanes'], 1)
            self.assertEqual(report['recomputedPlanes'], 2)
            self.assertEqual(report['noLongerEligibleElevationsCm'], [200])
            rows = {row['elevationCm']: row for row in report['layers']}
            self.assertFalse(rows[100]['observerDomainChanged'])
            self.assertTrue(rows[300]['observerDomainChanged'])
            self.assertFalse(Path(rows[300]['target']).exists())
            preserved = Path(rows[100]['target']).read_bytes()
            with patch('world_visibility_materials.build_policy', return_value=policy):
                bake(new, nav_path, repaired, eye_height_cm=100, only_elevations=elevations, cache_only=True)
            actual = json.loads(repaired.read_bytes())
            self.assertEqual([row['elevationCm'] for row in actual['layers']], [100, 300])
            self.assertEqual([Path(row['cacheFile']) for row in actual['layers']],
                             [Path(rows[z]['target']) for z in (100, 300)])
            self.assertEqual(Path(rows[100]['target']).read_bytes(), preserved)
            # Reject a changed original domain even if the plane cache exists.
            original_data = json.loads(original.read_bytes())
            original_data['layers'][0]['globalOrigins'] = False
            original.write_text(json.dumps(original_data))
            with patch('migrate_world_plane_cache.build_policy', return_value=policy):
                with self.assertRaisesRegex(ValueError, 'Original plane domains'):
                    migrate(original, old, new, nav_path, elevations_path, root / 'invalid.json')


if __name__ == '__main__':
    unittest.main()
