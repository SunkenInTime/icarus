import unittest
from probe_normalized_wall_junctions import select_receiver_side


class ObserverSideTest(unittest.TestCase):
    def test_interior_svg_does_not_choose_a_solid_side(self):
        with self.assertRaisesRegex(ValueError, 'Ambiguous'):
            select_receiver_side([-1, 1])
        self.assertEqual(select_receiver_side([-1, 1], 1), 1)

    def test_contract_cannot_place_observer_outside_receiver(self):
        with self.assertRaisesRegex(ValueError, 'within the SVG'):
            select_receiver_side([-1], 1)
        self.assertEqual(select_receiver_side([-1]), -1)


if __name__ == '__main__':
    unittest.main()
