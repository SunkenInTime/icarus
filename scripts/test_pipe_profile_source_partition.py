from fractions import Fraction as F
import unittest

from propose_split_pipe_profile_region import split_polygon


def area(poly):
    return abs(sum(a[0]*b[1]-a[1]*b[0]
                   for a,b in zip(poly,poly[1:]+poly[:1])))/2


class PipeSourcePartitionTests(unittest.TestCase):
    def test_exact_area_after_translated_crossing_cuts(self):
        triangle=[(F(234.12715823427),F(210.38670489945)),
                  (F(246.),F(210.38670489945)),(F(235.18),F(228.))]
        parts=[triangle]
        for axis,coordinate in [(0,239.72946733),(1,216.88492141),(0,235.18003569025)]:
            parts=[q for p in parts for q in split_polygon(p,axis,coordinate)]
        self.assertEqual(sum(map(area,parts)),area(triangle))
        self.assertTrue(all(area(p)>0 for p in parts))

    def test_boundary_does_not_duplicate_area(self):
        triangle=[(F(0),F(0)),(F(1),F(0)),(F(0),F(1))]
        self.assertEqual(split_polygon(triangle,0,0.),[triangle])

    def test_shared_edge_intersection_is_order_independent(self):
        triangle=[(F(234.1),F(210.3)),(F(246.2),F(220.7)),(F(237.8),F(228.9))]
        forward=split_polygon(triangle,0,239.72946733)
        reverse=split_polygon(list(reversed(triangle)),0,239.72946733)
        cut=F(239.72946733)
        a={p for poly in forward for p in poly if p[0]==cut}
        b={p for poly in reverse for p in poly if p[0]==cut}
        self.assertEqual(a,b)


if __name__=='__main__':unittest.main()
