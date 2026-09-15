import unittest

from verify_region_contacts_exact import exact_line_intervals,exact_wall_gate


class ExactContactTests(unittest.TestCase):
    def family(self):
        return dict(sourceVerticesSvg=[[0,0],[1,0],[1,1],[0,1]],targetVerticesSvg=[[0,4],[1,4],[1,4],[0,4]],triangles=[[0,1,2],[0,2,3]])

    def test_complete_collapsed_contact(self):
        result=exact_wall_gate(self.family(),[[0,.5],[1,.5]],[[0,4],[1,4]])
        self.assertEqual(result['maximumNormalErrorSvg'],0)
        self.assertEqual(result['mappedAlongRangeSvg'],[0,1])

    def test_shared_diagonal_is_covered(self):
        rows=exact_line_intervals(self.family(),[[0,0],[1,1]])
        self.assertEqual(len(rows),2)

    def test_sub_pixel_gap_is_not_hidden(self):
        gap=2**-45
        family=dict(sourceVerticesSvg=[[0,0],[.5,0],[.5,1],[0,1],[.5+gap,0],[1,0],[1,1],[.5+gap,1]],
            targetVerticesSvg=[[0,0],[.5,0],[.5,1],[0,1],[.5+gap,0],[1,0],[1,1],[.5+gap,1]],triangles=[[0,1,2],[0,2,3],[4,5,6],[4,6,7]])
        with self.assertRaisesRegex(AssertionError,'Uncovered exact source interval'):
            exact_line_intervals(family,[[0,.5],[1,.5]])

    def test_wrong_wall_coordinate_fails(self):
        with self.assertRaisesRegex(AssertionError,'not on the authored wall'):
            exact_wall_gate(self.family(),[[0,.5],[1,.5]],[[0,4.001],[1,4.001]])


if __name__=='__main__':unittest.main()
