import unittest
import numpy as np
import shapely
from build_all_physical_standing_surfaces import selected_ground_domains
from build_all_map_gameplay_supports import plane_region


class SelectedGroundTest(unittest.TestCase):
    def test_upper_overlap_is_not_covered_when_runtime_selects_lower(self):
        triangles=np.array([[[0,0,0],[2,0,0],[0,2,0]],
                            [[0,0,5],[3,0,5],[0,3,5]]],dtype=float)
        lower,upper=selected_ground_domains(triangles)
        self.assertTrue(lower.covers(shapely.Point(.5,.5)))
        self.assertFalse(upper.covers(shapely.Point(.5,.5)))
        self.assertTrue(upper.covers(shapely.Point(2.1,.2)))
        self.assertAlmostEqual(lower.area+upper.area,4.5)

    def test_empty_inclined_intersection_is_empty(self):
        self.assertTrue(plane_region(shapely.Polygon(),np.array([1.,0.,0.]),-.015,.015).is_empty)


if __name__=='__main__':unittest.main()
