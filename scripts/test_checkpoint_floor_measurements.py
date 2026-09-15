import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import numpy as np
import shapely

from audit_icebox_regional_floors import measure_obligation, merge_floor_faces, subtract_clearance
from checkpoint_floor_measurements import checkpointed_measurements


def should_not_run(*args):
    raise AssertionError('A completed measurement was repeated')


def one_failure(item):
    if item[0] == 'bad':
        raise ValueError('source geometry needs repair')
    return dict(row=dict(id=item[0], status='passed'), domains=[])


class CheckpointTests(unittest.TestCase):
    def test_nearly_coincident_floor_faces_keep_their_input_triangle(self):
        fixture = json.loads((Path(__file__).parent/'testdata/icebox_source_union_loss.json').read_bytes())
        faces = [shapely.from_geojson(json.dumps(p)) for p in fixture['polygons']]
        point = shapely.Point(fixture['point'])
        self.assertTrue(any(p.covers(point) for p in faces))
        merged = merge_floor_faces(faces)
        self.assertTrue(merged.covers(point))
        self.assertTrue(merged.is_valid)
        # The output must retain every input face, within the declared grid.
        self.assertTrue(all(p.difference(merged.buffer(1e-7)).area < 1e-8 for p in faces))

    def test_a_failed_job_does_not_discard_other_completed_measurements(self):
        for workers in [1, 2]:
            with tempfile.TemporaryDirectory() as folder:
                with self.assertRaisesRegex(RuntimeError, 'bad'):
                    checkpointed_measurements([('bad',), ('good',)], one_failure, (),
                        folder, 'fixture', workers)
                self.assertTrue((Path(folder)/'fixture/good.json').exists())
                self.assertTrue((Path(folder)/'fixture/bad.error.json').exists())
                self.assertFalse((Path(folder)/'fixture/bad.json').exists())

    def test_rounded_obstacle_cannot_create_a_floor_on_the_audit_boundary(self):
        region = shapely.box(-120.58242210905009, -80.15851758285395,
            31.97660314909577, 72.4005076752906)
        blocked = shapely.set_precision(region, 1e-7)
        self.assertGreater(region.difference(blocked).area, 1e-6)
        self.assertTrue(subtract_clearance(region, blocked).is_empty)

    def test_clearance_ignores_isolated_lines_without_rebuilding_floor_polygons(self):
        region = shapely.GeometryCollection([shapely.box(0, 0, 4, 4),
            shapely.LineString([(10, 0), (10, 1)])])
        blockers = shapely.GeometryCollection([shapely.box(2, 0, 4, 4),
            shapely.Point(20, 20)])
        result = subtract_clearance(region, blockers)
        self.assertAlmostEqual(result.area, 8.)
        self.assertTrue(result.equals(shapely.box(0, 0, 2, 4)))

    def test_parallel_geometry_matches_serial_and_resumes_without_remeasurement(self):
        triangle = np.array([[[0., 0., 0.], [4., 0., 0.], [0., 4., 0.]]])
        row = dict(id='floor', bounds=[[0, 0, 0], [4, 4, 0]],
            unwalkable=False, kill=False, body={})
        volumes = SimpleNamespace(rows=[row], triangles=[triangle], equations=[None],
            tree=shapely.STRtree([shapely.box(0, 0, 4, 4)]))
        state = (volumes, 0, shapely.box(-1, -1, 5, 5), {})
        items = [('mesh-1', dict(sourceObject=1), [0]),
            ('mesh-2', dict(sourceObject=2), [])]
        serial = [measure_obligation(item, *state) for item in items]
        self.assertAlmostEqual(serial[0]['row']['standingAreaSquareMeters'], 8.)
        self.assertEqual(serial[1]['row']['status'], 'no-clear-standing-domain')
        with tempfile.TemporaryDirectory() as folder:
            parallel = checkpointed_measurements(items, measure_obligation, state,
                folder, 'fixture', workers=2)
            self.assertEqual(serial, parallel)
            resumed = checkpointed_measurements(items, should_not_run, (), folder, 'fixture')
            self.assertEqual(serial, resumed)
            path = Path(folder)/'fixture/mesh-1.json'
            record = json.loads(path.read_text())
            record['result']['row']['standingAreaSquareMeters'] = 99
            path.write_text(json.dumps(record))
            with self.assertRaises(AssertionError):
                checkpointed_measurements(items, should_not_run, (), folder, 'fixture')


if __name__ == '__main__':
    unittest.main()
