import unittest
from pathlib import Path
import tempfile

from finalize_world_maps import select_maps, validate_reference, validate_packed_candidate, checked_source_evidence
from seal_world_plane_manifest import digest, read_json, seal_plane_manifest
from pack_world_visibility import pack
from world_plane_test_fixture import completed_fixture, write_json


class FinalizerTests(unittest.TestCase):
    def test_additional_support_evidence_requires_exact_distinct_files(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'support-proof.json'
            path.write_text('verified native hull')
            record = {'path': str(path), 'sha256': digest(path)}
            self.assertEqual(checked_source_evidence({'sourceEvidence': [record]}), [path.resolve()])
            with self.assertRaisesRegex(ValueError, 'duplicated'):
                checked_source_evidence({'sourceEvidence': [record, record]})
            path.write_text('changed support')
            with self.assertRaisesRegex(ValueError, 'changed'):
                checked_source_evidence({'sourceEvidence': [record]})

    def test_resume_rejects_different_seal_missing_coverage_and_changed_asset(self):
        with tempfile.TemporaryDirectory() as folder:
            planes, world = completed_fixture(folder)
            seal_plane_manifest(planes, world)
            output = Path(folder) / 'packed'
            pack(planes, output)
            manifest = output / 'split_visibility.manifest.json'
            data = validate_packed_candidate(manifest, planes)
            changed = {**data, 'source': {**data['source'], 'planeSealSha256': '0' * 64}}
            write_json(manifest, changed)
            with self.assertRaisesRegex(ValueError, 'different sealed planes'):
                validate_packed_candidate(manifest, planes)
            write_json(manifest, {**data, 'layers': []})
            with self.assertRaisesRegex(ValueError, 'different plane coverage'):
                validate_packed_candidate(manifest, planes)
            write_json(manifest, data)
            child = output / data['chunks'][0]['asset']
            child.write_bytes(child.read_bytes() + b'corrupt')
            with self.assertRaisesRegex(ValueError, 'asset changed'):
                validate_packed_candidate(manifest, planes)

    def test_default_requires_every_map(self):
        with self.assertRaisesRegex(ValueError, 'Missing required source maps: bind'):
            select_maps([{'map': 'split'}], None, ['split', 'bind'])

    def test_duplicate_source_rows_are_not_silently_overwritten(self):
        with self.assertRaisesRegex(ValueError, 'Duplicate map row'):
            select_maps([{'map': 'split'}, {'map': 'split'}], ['split'], ['split'])

    def test_explicit_subset_and_required_order(self):
        rows = [{'map': 'bind'}, {'map': 'split'}]
        self.assertEqual(select_maps(rows, None, ['split', 'bind'])[1], ['split', 'bind'])
        self.assertEqual(select_maps(rows, ['split'], ['split', 'bind'])[1], ['split'])
        with self.assertRaisesRegex(ValueError, 'unique'):
            select_maps(rows, ['split', 'split'], ['split', 'bind'])

    def test_reference_requires_current_metadata_floor_and_material_policies(self):
        with tempfile.TemporaryDirectory() as folder:
            manifest, world = completed_fixture(folder)
            base = read_json(manifest)
            navigation = manifest.with_name('split_navigation.json.gz')
            entry = {'combinedWorldFolder': str(world), 'geometrySha256': base['source']['geometrySha256']}
            reference_path = Path(folder) / 'reference.json'
            policies_path = reference_path.with_suffix('.policies.json')
            policies = {'navigationSha256': base['source']['navigationSha256'], 'walkable': None,
                        'policies': read_json(manifest.with_suffix('.audit.json'))['policies']}
            write_json(policies_path, policies)
            source = {**base['source'], 'metadataSha256': digest(world / 'geometry.json'),
                      'floorMeshSha256': digest(world / 'floor-mesh.json'), 'materialPoliciesSha256': digest(policies_path)}
            reference = {'map': 'split', 'eyeHeightCm': 175, 'source': source,
                         'origins': [{'id': '0'}], 'sampling': {'directions': 1},
                         'summary': {'origins': 1, 'rays': 1, 'alphaSamplingErrors': {}, 'floorAgreement': 1},
                         'rays': [{'planeElevationCm': 175, 'planeReference': {'distanceMeters': 1}}]}
            write_json(reference_path, reference)
            validate_reference(reference_path, base, entry, navigation)
            for key, value in [('alphaSamplingErrors', {'unresolved': 1}), ('floorAgreement', 0), ('rays', 2)]:
                with self.subTest(key=key):
                    write_json(reference_path, {**reference, 'summary': {**reference['summary'], key: value}})
                    with self.assertRaises(ValueError):
                        validate_reference(reference_path, base, entry, navigation)
            for key in ('metadataSha256', 'floorMeshSha256', 'materialPoliciesSha256', 'navigationSha256'):
                with self.subTest(key=key):
                    changed = {**reference, 'source': {**source, key: '0' * 64}}
                    write_json(reference_path, changed)
                    with self.assertRaises(ValueError):
                        validate_reference(reference_path, base, entry, navigation)
            write_json(reference_path, reference)
            policies['policies'][0]['mode'] = 'ignore'
            write_json(policies_path, policies)
            reference['source']['materialPoliciesSha256'] = digest(policies_path)
            write_json(reference_path, reference)
            with self.assertRaisesRegex(ValueError, 'Current material policies differ'):
                validate_reference(reference_path, base, entry, navigation)


if __name__ == '__main__':
    unittest.main()
