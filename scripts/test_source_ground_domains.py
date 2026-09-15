import unittest
import numpy as np
import shapely

from compile_icebox_ramp_ground import replace_ground
from audit_all_map_gameplay_levels import planes


class SourceGroundDomainTests(unittest.TestCase):
    def test_local_slope_preserves_outside_interpolation_and_hole(self):
        ground = dict(vertices=[0, 0, 5, 10, 0, 6, 10, 10, 8, 0, 10, 7],
                      triangles=[0, 1, 2, 0, 2, 3])
        domain = shapely.box(2, 2, 8, 8).difference(shapely.box(4, 4, 6, 6))
        updated, _ = replace_ground(ground, [(domain, np.array([.3, .1, 1]))])
        tri = np.array(updated['vertices']).reshape(-1, 3)[np.array(updated['triangles']).reshape(-1, 3)]
        shapes = shapely.polygons(tri[:, :, :2])
        self.assertLess(shapely.union_all(shapes).symmetric_difference(shapely.box(0, 0, 10, 10)).area, 1e-10)
        self.assertAlmostEqual(float(shapely.area(shapes).sum()), 100.)
        for shape, plane in zip(shapes, planes(tri)):
            p = shape.representative_point()
            xy = np.array([p.x, p.y])
            expected = .3 * p.x + .1 * p.y + 1 if domain.covers(p) else .1 * p.x + .2 * p.y + 5
            self.assertAlmostEqual(float(plane[:2] @ xy + plane[2]), expected)


if __name__ == '__main__':
    unittest.main()
