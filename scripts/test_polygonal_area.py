import unittest
from pathlib import Path

import shapely

from polygonal_area import polygonal


class PolygonalAreaTests(unittest.TestCase):
    def test_measured_icebox_landing_is_not_rebuilt_by_polygon_extraction(self):
        # A zero-distance buffer drops this valid measured landing almost
        # entirely in GEOS 3.13. Extracting polygon members must preserve it.
        shape = shapely.from_geojson((Path(__file__).parent/'testdata/icebox_landing_polygon.json').read_text())
        self.assertTrue(shape.is_valid)
        result = polygonal(shape)
        self.assertEqual(result.wkb, shape.wkb)
        self.assertAlmostEqual(result.area, 865.3708469811354, places=7)

    def test_nested_polygon_members_and_holes_are_retained_without_overlay(self):
        ring = shapely.box(0, 0, 4, 4).difference(shapely.box(1, 1, 2, 2))
        separate = shapely.box(10, 10, 11, 11)
        shape = shapely.GeometryCollection([ring,
            shapely.GeometryCollection([shapely.MultiPolygon([separate]), shapely.LineString([(0, 0), (1, 1)])]),
            shapely.Point(20, 20)])
        result = polygonal(shape)
        self.assertEqual(result.area, 16)
        self.assertEqual([part.wkb for part in result.geoms], [ring.wkb, separate.wkb])
        self.assertEqual(polygonal(result).wkb, result.wkb)


if __name__ == '__main__':
    unittest.main()
