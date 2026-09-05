"""Check that uncertain references cannot become proposed boundary corrections."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from audit_standing_visibility import audit


class StandingAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.world = {
            'map': 'split', 'eyeHeightCandidatesMeters': [1.55, 1.75, 1.95],
            'floorChecks': [{'sample': 0, 'materialCategory': 'opaque', 'hitMeters': [0, 0, 3]}],
            'objects': [{'path': 'Wall'}],
            'rays': [{'id': f'0-{height}-0', 'heightAboveFloorMeters': height,
                      'startMeters': [0, 0, 3 + height], 'endMeters': [25, 0, 3 + height],
                      'normal': [-1, 0, 0], 'originNearSurface': False,
                      'distanceMeters': 3, 'objectIndex': 0, 'materialCategory': 'opaque'}
                     for height in [1.55, 1.75, 1.95]],
        }
        self.comparison = {'rays': [
            {'id': r['id'], 'insideRuntimeFootprint': True,
             'runtimeDistanceMeters': 0.5, 'rawSourceDistanceMeters': 3.1,
             'rawSourceAtFloorDistanceMeters': 3.5} for r in self.world['rays']]}

    def run_audit(self, mismatch=False):
        world_path = self.root / 'world.json'
        world_path.write_text(json.dumps(self.world), encoding='utf-8')
        self.comparison.update(referenceFile=str(world_path), fingerprints={
            str(world_path): 'wrong' if mismatch else hashlib.sha256(world_path.read_bytes()).hexdigest()})
        comparison_path = self.root / 'comparison.json'
        comparison_path.write_text(json.dumps(self.comparison), encoding='utf-8')
        with contextlib.redirect_stdout(io.StringIO()):
            return audit(world_path, comparison_path, self.root / 'result.json')

    def test_stable_opaque_match_is_candidate_only(self):
        result = self.run_audit()
        self.assertEqual(result['summary'], {'raw-eye-layer-candidate': 1})
        self.assertFalse(result['gameplayCertified'])
        self.assertFalse(result['productionEdits'])

    def test_unknown_floor_or_hit_blocks_candidate(self):
        for field in ['floorChecks', 'rays']:
            with self.subTest(field=field):
                self.world[field][0]['materialCategory'] = 'unresolved'
                self.assertEqual(self.run_audit()['summary'], {'uncertain-reference-material-or-no-hit': 1})
                self.world[field][0]['materialCategory'] = 'opaque'

    def test_back_face_and_height_change_block_candidate(self):
        self.world['rays'][0]['normal'] = [1, 0, 0]
        self.assertEqual(self.run_audit()['summary'], {'back-facing-reference': 1})
        self.world['rays'][0]['normal'] = [-1, 0, 0]
        self.world['rays'][0]['distanceMeters'] = 3.2
        self.assertEqual(self.run_audit()['summary'], {'height-sensitive-reference': 1})

    def test_floor_layer_candidate_requires_all_heights_to_match(self):
        for ray in self.comparison['rays']:
            ray.update(rawSourceDistanceMeters=5, rawSourceAtFloorDistanceMeters=3.1)
        self.assertEqual(self.run_audit()['summary'], {'raw-floor-layer-candidate': 1})
        self.comparison['rays'][0]['rawSourceAtFloorDistanceMeters'] = 3.3
        self.assertEqual(self.run_audit()['summary'], {'unexplained-difference': 1})

    def test_stale_comparison_and_incomplete_height_group_fail(self):
        with self.assertRaisesRegex(ValueError, 'different fingerprints'):
            self.run_audit(mismatch=True)
        self.world['rays'].pop()
        with self.assertRaisesRegex(ValueError, 'Incomplete height group'):
            self.run_audit()


if __name__ == '__main__':
    unittest.main()
