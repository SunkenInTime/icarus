import json
from pathlib import Path
import unittest

import shapely
from shapely.affinity import affine_transform

from source_geometry_projection import project_source


class ProjectionTests(unittest.TestCase):
    def test_defense_projection_repairs_only_the_rounding_self_touch(self):
        fixture = json.loads((Path(__file__).parent/'testdata/icebox_projection_self_touch.json').read_bytes())
        native = shapely.from_geojson(json.dumps(fixture['nativeGeometry']))
        raw = affine_transform(native, fixture['transform'])
        self.assertTrue(native.is_valid)
        self.assertFalse(raw.is_valid)
        result = project_source(native, fixture['transform'])
        self.assertTrue(result.is_valid)
        self.assertLess(abs(result.area-raw.area), 1e-12)
        self.assertLess(shapely.hausdorff_distance(raw.boundary, result.boundary), 1e-10)
        self.assertTrue(result.intersection(shapely.box(289, 188, 291, 191)).is_valid)

    def test_valid_projection_keeps_its_geometry_bytes(self):
        native = shapely.box(0, 0, 10, 10).difference(shapely.box(2, 2, 3, 3))
        transform = [-1, 0, 0, -1, 387.459, 473]
        self.assertEqual(project_source(native, transform).wkb, affine_transform(native, transform).wkb)
        invalid = shapely.Polygon([(0, 0), (2, 2), (2, 0), (0, 2)])
        with self.assertRaises(AssertionError):
            project_source(invalid, transform)


if __name__ == '__main__':
    unittest.main()
