import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

from audit_native_material_slots import native_section_materials, floor_eligibility_changes


def material(package):
    return {'MaterialInterface': {'ObjectPath': package + '.0'}}


class NativeMaterialAuditTest(unittest.TestCase):
    def test_repeated_native_slots_keep_later_mixed_material_indices(self):
        # The USD exporter compresses [A, B, A, B, C] into [A, B, C].
        # Native section 2 must remain A and section 4 must still reach C.
        slots = [material('/Game/' + name) for name in ['A', 'B', 'A', 'B', 'C']]
        sections = [{'FirstIndex': i * 3, 'NumTriangles': 1, 'MaterialIndex': i} for i in range(5)]
        ids = {'/Game/A': 10, '/Game/B': 11, '/Game/C': 12, '/Game/Override': 13}
        modes = {'/Game/A': 'solid', '/Game/B': 'alpha-test', '/Game/C': 'ignore', '/Game/Override': 'ignore'}
        def resolve(package, _ref):
            return ids[package], {'mode': modes[package], 'certain': True}
        authored = [([i], i) for i in range(5)]
        values, records = native_section_materials(sections, slots, [], authored, 5, resolve)
        self.assertEqual(values.tolist(), [10, 11, 10, 11, 12])
        values, records = native_section_materials(sections, slots,
            [None, None, material('/Game/Override')['MaterialInterface']], authored, 5, resolve)
        self.assertEqual(values.tolist(), [10, 11, 13, 11, 12])
        self.assertEqual(records[2]['policyMode'], 'ignore')

    def test_native_ranges_must_match_actual_source_face_sections(self):
        sections = [{'FirstIndex': 0, 'NumTriangles': 2, 'MaterialIndex': 0}]
        with self.assertRaisesRegex(ValueError, 'face range differs'):
            native_section_materials(sections, [material('/Game/A')], [], [([1, 2], 0)], 3,
                                    lambda _package, _ref: (0, {'mode': 'solid', 'certain': True}))
        with self.assertRaisesRegex(ValueError, 'every source face'):
            native_section_materials(sections, [material('/Game/A')], [], [([0, 1], 0)], 3,
                                    lambda _package, _ref: (0, {'mode': 'solid', 'certain': True}))

    def test_floor_changes_are_limited_to_native_floor_height_window(self):
        with tempfile.TemporaryDirectory() as temporary:
            nav = Path(temporary) / 'nav.json'
            nav.write_text(json.dumps({'vertices': [0, 0, 10, 200, 0, 10, 0, -200, 10],
                                       'triangles': [7, 0, 1, 2]}))
            arrays = {'points': np.array([[0, 0, 0], [2, 0, 0], [0, 2, 0],
                                          [0, 0, 4], [2, 0, 4], [0, 2, 4]], dtype=np.float32),
                      'faces': np.array([[0, 1, 2], [3, 4, 5]]),
                      'material_indices': np.array([1, 1])}
            materials = [{'category': 'masked'}, {'category': 'opaque'}]
            proof = floor_eligibility_changes(arrays, np.array([0, 0]), materials, nav)
            self.assertFalse(proof['floorValuesPreserved'])
            self.assertEqual(len(proof['clippedPieces']), 1)
            self.assertEqual(proof['clippedPieces'][0]['sourceFace'], 0)
            self.assertEqual(proof['clippedPieces'][0]['parentNavPolygon'], 7)
            self.assertTrue(proof['clippedPieces'][0]['becameFloorEligible'])
            arrays['material_indices'] = np.array([0, 1])
            proof = floor_eligibility_changes(arrays, np.array([1, 0]), materials, nav)
            self.assertFalse(proof['clippedPieces'][0]['becameFloorEligible'])


if __name__ == '__main__':
    unittest.main()
