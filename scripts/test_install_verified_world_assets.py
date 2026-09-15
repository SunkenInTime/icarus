import copy
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from install_verified_world_assets import verified_files
from verify_world_runtime import preflight, sha256


def write_json(path, value):
    path.write_text(json.dumps(value), encoding='utf-8')


class InstallationGateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.references = self.root / 'references'
        self.references.mkdir()
        self.required = ['split', 'bind']
        self.source = {'scope': 'all_maps', 'allMapCoverageComplete': True, 'maps': []}
        self.runtime = {'scope': 'all_maps', 'runtimeStatus': 'passed',
                        'completeAllMapCoverage': True, 'worldDirectory': str(self.root),
                        'referenceDirectory': str(self.references), 'maps': []}
        self.inventory = {
            'status': 'all-map-same-plane-review-inventory', 'acceptedOrWaivedRays': 0,
            'allRequiredMapsCompared': True, 'allComparisonsUseFinalReferences': True,
            'allRequiredMapsReviewed': True, 'requiredMaps': 2, 'comparedMaps': 2,
            'reviewedMaps': 2, 'samePlaneRays': 4, 'retainedOutliersOver2cm': 1,
            'retainedOutliersOver10cm': 1, 'maps': []}
        self.files = set()
        for name in self.required:
            self.add_map(name, has_outlier=name == 'split')
        self.code = self.root / 'runtime.dart'
        self.code.write_bytes(b'verified runtime implementation')
        self.runtime['runtimeFiles'] = [{'path': str(self.code), 'sha256': sha256(self.code)}]
        self.source_path = self.root / 'source.json'
        self.runtime_path = self.root / 'runtime.json'
        self.inventory_path = self.root / 'inventory.json'

    def add_map(self, name, has_outlier):
        chunk = self.root / f'{name}_visibility_000.bin.gz'
        nav = self.root / f'{name}_navigation.json.gz'
        for path in (chunk, nav):
            path.write_bytes(path.name.encode())

        def descriptor(path):
            return {'asset': path.name, 'sha256': sha256(path), 'compressedBytes': path.stat().st_size}

        policy_path = self.references / f'{name}.policies.json'
        write_json(policy_path, {'policies': ['opaque']})
        fingerprints = {'geometrySha256': 'a' * 64, 'navigationSha256': sha256(nav),
                        'materialPoliciesSha256': sha256(policy_path)}
        manifest = self.root / f'{name}_visibility.manifest.json'
        write_json(manifest, {'map': name, 'format': 'chunked-v1', 'source': fingerprints,
                             'chunks': [descriptor(chunk)], 'navigationAsset': descriptor(nav),
                             'layers': [{'elevationCm': 175}]})
        reference = self.references / f'{name}.json'
        write_json(reference, {'map': name, 'source': fingerprints, 'origins': [{'id': 0}],
                               'sampling': {'directions': 2}, 'rays': [
                                   {'id': f'0-{i}', 'planeReference': {}, 'planeElevationCm': 175}
                                   for i in range(2)]})
        # Use the verifier's actual input schema, including reference asset paths.
        self.runtime['maps'].append({'map': name, 'runtimeStatus': 'passed',
                                     'input': preflight(name, self.root, self.references)})
        failures = [{'ray': '0-0', 'errorMeters': .25, 'referenceMeters': 2,
                     'bakedMeters': 2.25, 'elevationCm': 175, 'sourceFace': 1}] if has_outlier else []
        comparison = {'map': name, 'assetSha256': sha256(manifest), 'referenceSha256': sha256(reference),
                      'summary': {'rays': 2}, 'planeSummary': {'rays': 2, 'differentSelectedPlanes': 0,
                      'maxErrorMeters': .25 if has_outlier else .001}, 'planeFailures': failures}
        comparison_path = self.root / f'{name}-rays.json'
        write_json(comparison_path, comparison)
        self.source['maps'].append({'map': name, 'status': 'candidate-packed-and-compared',
            'referenceReport': str(comparison_path), 'summary': comparison['summary'],
            'planeSummary': comparison['planeSummary'], 'source': {
                'packedManifestSha256': sha256(manifest), 'referenceSha256': sha256(reference),
                'referencePoliciesSha256': sha256(policy_path)}})
        proof_path = self.root / f'{name}-reviewed-outliers.json'
        write_json(proof_path, {'map': name, 'statisticalOutliersRetained': True})
        self.inventory['maps'].append({'map': name, 'comparisonPresent': True,
            'allSamePlaneOutliersExplained': True, 'comparisonUsesFinalReference': True,
            'finalReferenceRayRecordsEqual': True, 'comparisonSha256': sha256(comparison_path),
            'samePlaneRays': 2, 'samePlaneOutliersOver2cm': len(failures),
            'samePlaneOutliersOver10cm': len(failures),
            'maximumSamePlaneErrorMeters': comparison['planeSummary']['maxErrorMeters'],
            'reviewEvidence': {'path': str(proof_path), 'sha256': sha256(proof_path)},
            'retainedOutliers': [{**row, 'explanation': 'Independently checked corner crossing.'}
                                 for row in failures]})
        self.files.update((manifest, chunk, nav))

    def verify(self):
        write_json(self.source_path, self.source)
        write_json(self.runtime_path, self.runtime)
        write_json(self.inventory_path, self.inventory)
        return verified_files(self.root, self.source_path, self.runtime_path,
                              self.inventory_path, self.required)

    def test_only_exact_audited_bytes_are_selected(self):
        (self.root / 'unlisted-stale-chunk.bin.gz').write_bytes(b'not part of this build')
        self.assertEqual(set(self.verify()), self.files)
        (self.root / 'split_visibility_000.bin.gz').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Runtime input changed'):
            self.verify()

    def test_partial_or_failed_audits_cannot_install(self):
        for document, key, value in ((self.source, 'scope', 'explicit_subset'),
                                     (self.source, 'allMapCoverageComplete', False),
                                     (self.runtime, 'scope', 'explicit_subset'),
                                     (self.runtime, 'runtimeStatus', 'failed'),
                                     (self.runtime, 'completeAllMapCoverage', False)):
            with self.subTest(key=key):
                previous = document[key]
                document[key] = value
                with self.assertRaisesRegex(ValueError, 'Complete passing'):
                    self.verify()
                document[key] = previous

    def test_all_audits_require_exact_unique_map_coverage(self):
        for document in (self.source, self.runtime, self.inventory):
            for change in ('missing', 'duplicate', 'wrong'):
                with self.subTest(document=list(document)[0], change=change):
                    previous = copy.deepcopy(document['maps'])
                    if change == 'missing':
                        document['maps'].pop()
                    elif change == 'duplicate':
                        document['maps'].append(copy.deepcopy(document['maps'][0]))
                    else:
                        document['maps'][0]['map'] = 'ascent'
                    with self.assertRaisesRegex(ValueError, 'Audit map coverage'):
                        self.verify()
                    document['maps'] = previous

    def test_identical_asset_in_another_directory_does_not_count(self):
        alternate = self.root / 'another-build'
        alternate.mkdir()
        for row in self.runtime['maps'][0]['input']['assets']:
            path = Path(row['path'])
            with self.subTest(asset=path.name):
                copy_path = alternate / path.name
                shutil.copyfile(path, copy_path)
                row['path'] = str(copy_path)
                with self.assertRaises(ValueError):
                    self.verify()
                row['path'] = str(path)

    def test_resolved_alias_matches_the_same_runtime_asset(self):
        alias = self.root / 'alias'
        alias.mkdir()
        row = self.runtime['maps'][0]['input']['assets'][0]
        row['path'] = str(alias / '..' / Path(row['path']).name)
        self.assertEqual(set(self.verify()), self.files)

    def test_duplicate_resolved_runtime_paths_are_rejected(self):
        alias = self.root / 'alias'
        alias.mkdir()
        assets = self.runtime['maps'][0]['input']['assets']
        duplicate = dict(assets[0])
        duplicate['path'] = str(alias / '..' / Path(duplicate['path']).name)
        assets.append(duplicate)
        with self.assertRaisesRegex(ValueError, 'Duplicate resolved'):
            self.verify()

    def test_linked_asset_keeps_the_filename_required_by_the_manifest(self):
        chunk = self.root / 'split_visibility_000.bin.gz'
        target = self.root / 'stored-blob.bin.gz'
        chunk.rename(target)
        try:
            chunk.symlink_to(target)
        except OSError as error:
            self.skipTest(f'Creating file symlinks is unavailable: {error}')
        self.assertEqual(set(self.verify()), self.files)

    def test_runtime_directory_must_be_the_candidate(self):
        self.runtime['worldDirectory'] = str(self.references)
        with self.assertRaisesRegex(ValueError, 'different candidate directory'):
            self.verify()

    def test_reference_and_policy_hashes_must_match_source_audit(self):
        lineage = self.source['maps'][0]['source']
        for key in ('referenceSha256', 'referencePoliciesSha256'):
            with self.subTest(key=key):
                previous = lineage[key]
                lineage[key] = 'b' * 64
                with self.assertRaisesRegex(ValueError, 'reference or material policies differ'):
                    self.verify()
                lineage[key] = previous

    def test_runtime_reference_fingerprints_must_match_reference_bytes(self):
        fingerprints = self.runtime['maps'][0]['input']['referenceFingerprints']
        for key in ('geometrySha256', 'materialPoliciesSha256'):
            with self.subTest(key=key):
                previous = fingerprints[key]
                fingerprints[key] = 'b' * 64
                with self.assertRaisesRegex(ValueError, 'reference or material policies differ'):
                    self.verify()
                fingerprints[key] = previous

    def test_reference_changed_after_runtime_is_rejected(self):
        reference = self.references / 'split.json'
        data = json.loads(reference.read_bytes())
        data['rays'][0]['planeElevationCm'] += 1
        write_json(reference, data)
        with self.assertRaisesRegex(ValueError, 'Runtime input changed'):
            self.verify()

    def test_policy_changed_after_source_audit_is_rejected(self):
        write_json(self.references / 'split.policies.json', {'policies': ['transparent']})
        with self.assertRaisesRegex(ValueError, 'reference or material policies differ'):
            self.verify()

    def test_missing_inventory_is_rejected(self):
        self.verify()
        self.inventory_path.unlink()
        with self.assertRaises(FileNotFoundError):
            verified_files(self.root, self.source_path, self.runtime_path,
                           self.inventory_path, self.required)

    def test_unfinished_inventory_or_waived_rays_are_rejected(self):
        for key, value in (('allRequiredMapsCompared', False), ('allRequiredMapsReviewed', False),
                           ('allComparisonsUseFinalReferences', False), ('reviewedMaps', 1),
                           ('acceptedOrWaivedRays', 1)):
            with self.subTest(key=key):
                previous = self.inventory[key]
                self.inventory[key] = value
                with self.assertRaisesRegex(ValueError, 'complete all-map source outlier review'):
                    self.verify()
                self.inventory[key] = previous

    def test_review_requires_exact_comparison_bytes_even_for_zero_outliers(self):
        for name in self.required:
            with self.subTest(map=name):
                path = self.root / f'{name}-rays.json'
                original = path.read_bytes()
                path.write_bytes(original + b'\n')
                with self.assertRaisesRegex(ValueError, 'different source comparison'):
                    self.verify()
                path.write_bytes(original)

    def test_comparison_lineage_is_checked_even_with_matching_review_hash(self):
        path = self.root / 'split-rays.json'
        original = path.read_bytes()
        for key in ('assetSha256', 'referenceSha256'):
            with self.subTest(key=key):
                comparison = json.loads(original)
                comparison[key] = 'b' * 64
                write_json(path, comparison)
                self.inventory['maps'][0]['comparisonSha256'] = sha256(path)
                with self.assertRaisesRegex(ValueError, 'source comparison differs'):
                    self.verify()
        path.write_bytes(original)

    def test_review_cannot_drop_duplicate_or_change_an_outlier(self):
        row = self.inventory['maps'][0]
        original = copy.deepcopy(row['retainedOutliers'])
        changes = [[], original * 2, [{**original[0], 'errorMeters': .001}],
                   [{**original[0], 'explanation': ''}]]
        for changed in changes:
            with self.subTest(retained=changed):
                row['retainedOutliers'] = changed
                with self.assertRaisesRegex(ValueError, 'retain every|changed or lacks'):
                    self.verify()
        row['retainedOutliers'] = original

    def test_review_evidence_must_still_match_its_hash(self):
        (self.root / 'split-reviewed-outliers.json').write_bytes(b'changed proof')
        with self.assertRaisesRegex(ValueError, 'review evidence is missing or changed'):
            self.verify()

    def test_per_map_and_all_map_review_statistics_are_preserved(self):
        for document, key in ((self.inventory['maps'][0], 'samePlaneOutliersOver2cm'),
                               (self.inventory['maps'][0], 'samePlaneRays'),
                               (self.inventory, 'retainedOutliersOver2cm')):
            with self.subTest(key=key):
                previous = document[key]
                document[key] = 0
                with self.assertRaisesRegex(ValueError, 'statistics differ|totals differ'):
                    self.verify()
                document[key] = previous

    def test_runtime_implementation_must_still_match(self):
        self.code.write_bytes(b'changed implementation')
        with self.assertRaisesRegex(ValueError, 'Runtime code changed'):
            self.verify()


if __name__ == '__main__':
    unittest.main()
