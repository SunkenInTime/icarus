import copy
import unittest

from verify_region_contact import verify_contact


def region(shift=0., middle=0.):
    return dict(sourceVerticesSvg=[[0, shift], [1, shift], [2, shift],
                                   [0, shift+1], [1, shift+1], [2, shift+1]],
                targetVerticesSvg=[[0, 0], [1, middle], [2, 0], [0, 1], [1, 1], [2, 1]],
                triangles=[[0, 1, 4], [0, 4, 3], [1, 2, 5], [1, 5, 4]])


class RegionContactTest(unittest.TestCase):
    def test_distinct_source_planes_can_share_exact_authored_seam(self):
        result = verify_contact(region(), [[0, 0], [2, 0]], region(.03),
                                [[0, .03], [2, .03]], [[0, 0], [2, 0]])
        self.assertTrue(result['continuousContactVerified'])
        self.assertFalse(result['sourceHeightCoverageVerified'])

    def test_matching_endpoints_cannot_hide_middle_gap(self):
        with self.assertRaisesRegex(AssertionError, 'authored contact'):
            verify_contact(region(), [[0, 0], [2, 0]], region(middle=.002),
                           [[0, 0], [2, 0]], [[0, 0], [2, 0]])

    def test_missing_cell_cannot_hide_seam_gap(self):
        broken = copy.deepcopy(region())
        broken['triangles'] = broken['triangles'][:2]
        with self.assertRaisesRegex(AssertionError, 'escapes region'):
            verify_contact(region(), [[0, 0], [2, 0]], broken,
                           [[0, 0], [2, 0]], [[0, 0], [2, 0]])

    def test_oblique_seam_survives_clipped_coordinate_rounding(self):
        seam = [[.000000001, .13000001], [1.999999999, .63000003]]
        self.assertTrue(verify_contact(region(), seam, region(), seam, seam)
                        ['continuousContactVerified'])


if __name__ == '__main__':
    unittest.main()
