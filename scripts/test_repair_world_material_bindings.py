import unittest

import numpy as np

from repair_world_material_bindings import (
    assign_bound_faces, correspondence_error, update_floor_refinement,
)


class BindingRepairTest(unittest.TestCase):
    def test_source_face_order_is_verified_but_corner_winding_can_change(self):
        source = np.array([[[0., 0, 0], [1, 0, 0], [0, 1, 0]],
                           [[5., 5, 0], [6, 5, 0], [5, 6, 0]]])
        self.assertEqual(correspondence_error(source, source[:, [2, 0, 1]]), 0)
        self.assertGreater(correspondence_error(source, source[::-1]), 1)
        collapsed = source.copy()
        collapsed[0, 2] = collapsed[0, 0]
        self.assertGreater(correspondence_error(source, collapsed), .5)

    def test_unbound_faces_keep_fallback_even_when_blender_shares_a_material_slot(self):
        material_ids = np.array([3, 3, 3, 3])
        assign_bound_faces(material_ids, 0,
                           [([0, 2], {'source': 'glass'}), ([1], None)], lambda _: 4)
        self.assertEqual(material_ids.tolist(), [4, 3, 4, 3])
        with self.assertRaises(ValueError):
            assign_bound_faces(material_ids, 0, [([0], None), ([0], None)], lambda _: 4)

    def test_removing_known_translucent_overlay_rechecks_floor_fallback(self):
        triangles = np.array([[[0., 0, 0], [4, 0, 0], [0, 4, 0]],
                              [[0., 0, .1], [1, 0, .1], [0, 1, .1]]])
        materials = [{'category': 'opaque'}, {'category': 'unresolved'},
                     {'category': 'shader-dependent'}]
        baseline = {'refinedFloorHeightsCm': [10., 0.],
                    'checks': [
                        {'vertex': 0, 'sourceZCm': 10., 'refinedZCm': 10.,
                         'accepted': True, 'materialCategory': 'unresolved'},
                        {'vertex': 1, 'sourceZCm': 10., 'refinedZCm': 0.,
                         'accepted': True, 'materialCategory': 'opaque'}],
                    'summary': {'medianNavLiftCm': 10.}}
        refined, proof = update_floor_refinement(
            baseline, {'vertices': [25, -25, 10, 200, -200, 10]}, triangles,
            np.array([0, 1]), np.array([0, 2]), materials)
        self.assertEqual(refined['refinedFloorHeightsCm'], [0., 0.])
        self.assertEqual(proof['potentiallyAffectedVertices'], 1)
        self.assertEqual(proof['finalChangedHeightCount'], 1)
        self.assertEqual(baseline['refinedFloorHeightsCm'], [10., 0.])


if __name__ == '__main__':
    unittest.main()
