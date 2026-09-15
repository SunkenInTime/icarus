import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from verify_world_runtime import combined_metrics, main, preflight, read_map_names, report_failures


SOURCE = {'map': 'abyss', 'origins': 2, 'rays': 32, 'directions': 16,
          'referenceFingerprints': {'geometrySha256': 'g', 'navigationSha256': 'n'}}
REPORT = {
    'map': 'abyss', 'referenceFingerprints': SOURCE['referenceFingerprints'],
    'validatedAllChunks': True, 'outsideNavigationOrigins': [],
    'differentSelectedPlaneRays': [], 'unexplainedSelectedFloorOrigins': [],
    'differentSelectedFloorOrigins': [], 'differentSelectedFloorDetails': [],
    'origins': 2, 'comparedOrigins': 2,
    'allComparedRays': {'count': 32, 'within2Cm': 32}, 'samePlane3dReferenceRays': {'count': 32, 'within2Cm': 32},
    'outliersAbove2Cm': [], 'planeOutliersAbove2Cm': [],
    'polygonBoundaryAgainstExactRays': {'count': 16, 'maximumMeters': .0097},
    'maximumDefenseDistanceErrorMeters': 1e-13, 'maximumPolygonCenterErrorMeters': 1e-13,
}


class RuntimeRunnerTests(unittest.TestCase):
    def test_discovers_entire_current_map_enum(self):
        maps = read_map_names(Path(__file__).resolve().parents[1])
        self.assertEqual(len(maps), 13)
        self.assertIn('summit', maps)
        self.assertIn('abyss', maps)

    def test_valid_runtime_report_and_proven_stacked_floor(self):
        self.assertEqual(report_failures(REPORT, SOURCE), [])
        alternative = copy.deepcopy(REPORT)
        alternative.update(comparedOrigins=1, differentSelectedFloorOrigins=[1],
                           differentSelectedFloorDetails=[{'origin': 1, 'matchesSourceFloorAlternative': True}])
        alternative['allComparedRays']['count'] = 16
        alternative['allComparedRays']['within2Cm'] = 16
        alternative['samePlane3dReferenceRays']['count'] = 16
        alternative['samePlane3dReferenceRays']['within2Cm'] = 16
        self.assertEqual(report_failures(alternative, SOURCE), [])
        alternative['differentSelectedFloorDetails'][0]['matchesSourceFloorAlternative'] = False
        self.assertTrue(report_failures(alternative, SOURCE))

    def test_rejects_missing_coverage_outside_origins_and_plane_mismatches(self):
        mutations = [
            ('outsideNavigationOrigins', [1]), ('differentSelectedPlaneRays', [{'ray': '0-0'}]),
            ('unexplainedSelectedFloorOrigins', [1]), ('validatedAllChunks', False),
            ('samePlane3dReferenceRays', {'count': 31}), ('comparedOrigins', 0),
            ('polygonBoundaryAgainstExactRays', {'count': 0}),
            ('polygonBoundaryAgainstExactRays', {'count': 16, 'maximumMeters': float('nan')}),
            ('maximumDefenseDistanceErrorMeters', float('nan')),
        ]
        for key, value in mutations:
            with self.subTest(key=key):
                report = copy.deepcopy(REPORT)
                report[key] = value
                self.assertTrue(report_failures(report, SOURCE))

    def test_every_source_outlier_remains_reported_and_totals_are_explicit(self):
        report = copy.deepcopy(REPORT)
        report['allComparedRays']['within2Cm'] = 31
        self.assertTrue(report_failures(report, SOURCE))
        report['outliersAbove2Cm'] = [{'ray': '0-1', 'errorMeters': 1.2}]
        self.assertEqual(report_failures(report, SOURCE), [])
        report['exactHeightRays'] = {'count': 8, 'within2Cm': 8}
        totals = combined_metrics([{'metrics': report}, {'metrics': report}])
        self.assertEqual(totals['origins'], 4)
        self.assertEqual(totals['allComparedRays']['count'], 64)
        self.assertEqual(totals['allComparedRays']['within2Cm'], 62)

    def test_missing_default_map_fails_preflight_without_running_subset(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'lib/const').mkdir(parents=True)
            (root / 'lib/const/maps.dart').write_text('enum MapValue { abyss, split, }')
            with patch('verify_world_runtime.launch') as launch:
                code = main(['--repo', str(root), '--world-directory', str(root),
                             '--reference-directory', str(root), '--output', str(root / 'output')])
            self.assertEqual(code, 1)
            launch.assert_not_called()
            result = json.loads((root / 'output/aggregate.json').read_text())
            self.assertEqual(result['requestedMaps'], ['abyss', 'split'])
            self.assertEqual(len(result['maps']), 2)
            self.assertFalse(result['completeAllMapCoverage'])

    def test_pins_chunk_navigation_and_reference_sources(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def asset(name, body):
                (root / name).write_bytes(body)
                return {'asset': name, 'sha256': hashlib.sha256(body).hexdigest(),
                        'compressedBytes': len(body)}
            chunk = asset('abyss_visibility_000.bin.gz', b'chunk fixture')
            navigation = asset('abyss_navigation.json.gz', b'navigation fixture')
            manifest = {'map': 'abyss', 'format': 'chunked-v1', 'layers': [{}],
                        'source': SOURCE['referenceFingerprints'], 'chunks': [chunk],
                        'navigationAsset': navigation}
            reference = {'map': 'abyss', 'source': SOURCE['referenceFingerprints'],
                         'origins': [{'id': 0}, {'id': 1}], 'sampling': {'directions': 1},
                         'rays': [{'planeReference': {}, 'planeElevationCm': 175}] * 2}
            (root / 'abyss_visibility.manifest.json').write_text(json.dumps(manifest))
            (root / 'abyss.json').write_text(json.dumps(reference))
            result = preflight('abyss', root, root)
            self.assertEqual(len(result['assets']), 4)
            (root / chunk['asset']).write_bytes(b'changed data')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                preflight('abyss', root, root)


if __name__ == '__main__':
    unittest.main()
