import unittest
import json
from pathlib import Path
import shutil
import tempfile
import numpy as np

from supplement_world_visibility import join_segments, supplement, validate_combined_world
from seal_world_plane_manifest import digest, read_json, seal_plane_manifest, verify_plane_seal
from world_plane_test_fixture import completed_fixture, write_json
from verify_baked_world_rays import ray_distances


UI = {'XMultiplier': -.01, 'YMultiplier': .01, 'XScalarToAdd': 0, 'YScalarToAdd': 0}


class SupplementTests(unittest.TestCase):
    def test_empty_addition_preserves_every_quantized_endpoint(self):
        base = [((1, 2), (34, 56)), ((-8, 21), (16, -42))]
        self.assertEqual(join_segments(base, [], UI, 1), base)

    def test_new_crossing_is_split_without_moving_original_endpoints(self):
        # This UI maps world XY to UV YX.
        result = join_segments([((0, -2), (0, 2))], [[[-0., -2], [0., 2]]], UI, 1)
        self.assertEqual(len(result), 4)
        self.assertTrue(all((0, 0) in edge for edge in result))
        self.assertEqual({point for edge in result for point in edge},
                         {(0, -2), (0, 2), (-2, 0), (2, 0), (0, 0)})

    def test_addition_cannot_expose_a_previously_hidden_boundary(self):
        base = [((8, -5), (8, 5))]
        additions_world = [[[-2, 4], [2, 4]]]
        # Use a scaled quantized base so UV units represent physical meters.
        joined = np.asarray(join_segments((np.asarray(base) * 1000).tolist(), additions_world, UI, 1000)) / 1000
        starts = np.array([[0, y] for y in np.linspace(-4, 4, 37)])
        ends = starts + [20, 0]
        old = ray_distances(np.asarray(base), starts, ends)
        added = ray_distances(np.asarray(additions_world)[:, :, ::-1], starts, ends)
        actual = ray_distances(joined, starts, ends)
        np.testing.assert_allclose(actual, np.minimum(old, added), atol=1e-10)


class CompositionIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.manifest, self.base_folder = completed_fixture(self.root)
        seal_plane_manifest(self.manifest, self.base_folder)
        self.extra_folder, self.combined_folder = self.root / 'extra', self.root / 'combined'
        self.extra_folder.mkdir()
        self.combined_folder.mkdir()
        base = read_json(self.base_folder / 'geometry.json')
        shutil.copyfile(self.base_folder / 'geometry.npz', self.extra_folder / 'geometry.npz')
        extra = {'map': 'split', 'status': 'approved-static-scenery-supplement', 'issues': [],
                 'geometrySha256': digest(self.extra_folder / 'geometry.npz'), 'materials': base['materials']}
        write_json(self.extra_folder / 'geometry.json', extra)
        write_json(self.extra_folder / 'material-policies.json', read_json(self.manifest.with_suffix('.audit.json'))['policies'])
        with np.load(self.base_folder / 'geometry.npz') as source:
            arrays = {name: np.concatenate([source[name], source[name] + (3 if name == 'faces' else 1 if name == 'material_indices' else 0)])
                      for name in source.files}
        np.savez_compressed(self.combined_folder / 'geometry.npz', **arrays)
        floors = {}
        for name in ('floor-mesh.json', 'floor-refinement.json'):
            shutil.copyfile(self.base_folder / name, self.combined_folder / name)
            floors[name] = digest(self.base_folder / name)
        combined = {**base, 'materials': base['materials'] + extra['materials'],
                    'geometrySha256': digest(self.combined_folder / 'geometry.npz'),
                    'baseGeometrySha256': base['geometrySha256'], 'supplementGeometrySha256': extra['geometrySha256'],
                    'supplementation': {'supplementMetadataSha256': digest(self.extra_folder / 'geometry.json'),
                                        'floorFilesPreservedSha256': floors}}
        write_json(self.combined_folder / 'geometry.json', combined)

    def validate(self):
        validate_combined_world(self.base_folder, self.extra_folder, self.combined_folder, read_json(self.manifest),
                               read_json(self.extra_folder / 'geometry.json'), read_json(self.combined_folder / 'geometry.json'))

    def test_exact_append_produces_a_sealed_composition(self):
        output = self.root / 'result' / 'split.planes.json'
        result = supplement(self.manifest, self.extra_folder, self.combined_folder, output)
        seal = verify_plane_seal(output)
        self.assertEqual(seal['source'], result['source'])
        self.assertEqual(len(read_json(output.with_suffix('.audit.json'))['policies']), 2)
        with self.assertRaisesRegex(ValueError, 'fresh output'):
            supplement(self.manifest, self.extra_folder, self.combined_folder, output)

    def test_unapproved_material_policy_is_rejected_before_output(self):
        policies = read_json(self.extra_folder / 'material-policies.json')
        policies[0]['mode'] = 'ignore'
        write_json(self.extra_folder / 'material-policies.json', policies)
        with self.assertRaisesRegex(ValueError, 'Current material policies differ'):
            supplement(self.manifest, self.extra_folder, self.combined_folder, self.root / 'result.json')
        self.assertFalse((self.root / 'result.json').exists())

    def test_composition_binds_its_additional_source_proof(self):
        proof = self.root / 'background-exclusion.json'
        write_json(proof, {'nativeSource': 'background-sky'})
        output = self.root / 'result' / 'split.planes.json'
        supplement(self.manifest, self.extra_folder, self.combined_folder, output,
                   evidence_paths=[proof])
        seal = verify_plane_seal(output)
        self.assertEqual(seal['files'][str(proof.resolve())], digest(proof))
        write_json(proof, {'nativeSource': 'changed'})
        with self.assertRaises(ValueError):
            verify_plane_seal(output)

    def test_metadata_floor_and_projection_tampering_are_rejected(self):
        path = self.combined_folder / 'geometry.json'
        original = read_json(path)
        for key in ('metadata', 'floor', 'projection'):
            value = json.loads(json.dumps(original))
            if key == 'metadata':
                value['supplementation']['supplementMetadataSha256'] = '0' * 64
            elif key == 'floor':
                value['supplementation']['floorFilesPreservedSha256']['floor-mesh.json'] = '0' * 64
            else:
                value['uiTransform']['XMultiplier'] = .02
            write_json(path, value)
            with self.assertRaises(ValueError):
                self.validate()

    def test_changed_original_vertices_fail_even_with_updated_combined_hash(self):
        path = self.combined_folder / 'geometry.npz'
        with np.load(path) as source:
            arrays = {name: source[name] for name in source.files}
        arrays['points'][0, 0] += .01
        np.savez_compressed(path, **arrays)
        with self.assertRaisesRegex(ValueError, 'exact approved geometry append'):
            self.validate()

    def test_exact_float32_art_and_float64_instance_append_keeps_extra_precision(self):
        with np.load(self.base_folder / 'geometry.npz') as source:
            before = {name: source[name] for name in source.files}
        before['points'] = before['points'].astype(np.float32)
        np.savez_compressed(self.base_folder / 'geometry.npz', **before)
        extra = {name: values.copy() for name, values in before.items()}
        extra['points'] = extra['points'].astype(np.float64)
        extra['points'][0, 0] += 1e-10
        np.savez_compressed(self.extra_folder / 'geometry.npz', **extra)
        arrays = {name: np.concatenate([before[name], extra[name] +
                  (3 if name == 'faces' else 1 if name == 'material_indices' else 0)])
                  for name in before}
        np.savez_compressed(self.combined_folder / 'geometry.npz', **arrays)
        self.validate()
        arrays['points'] = arrays['points'].astype(np.float32)
        np.savez_compressed(self.combined_folder / 'geometry.npz', **arrays)
        with self.assertRaisesRegex(ValueError, 'exact approved geometry append'):
            self.validate()


if __name__ == '__main__':
    unittest.main()
