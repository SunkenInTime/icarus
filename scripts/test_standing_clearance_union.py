"""A captured source union must not erase a player-blocking collision region."""
import json
from pathlib import Path
import unittest
import shapely
from build_all_map_gameplay_supports import union_clearance


class ClearanceUnionTest(unittest.TestCase):
    def test_line_contacts_survive_with_area_blockers(self):
        line=shapely.LineString([(2,0),(2,1)])
        result=union_clearance(shapely.box(0,0,1,1),[line,shapely.Point(3,0)])
        self.assertTrue(result.covers(shapely.Point(.5,.5)))
        self.assertTrue(result.covers(shapely.Point(2,.5)))
        self.assertTrue(result.covers(shapely.Point(3,0)))

    def test_breeze_coincident_contacts_preserve_every_blocker(self):
        fixture=json.loads((Path(__file__).parent/'testdata/standing_clearance_union.json').read_text())
        shapes=[shapely.from_wkt(s) for s in fixture['shapes']]
        result=union_clearance(shapely.from_wkt(fixture['obstacles']),shapes)
        self.assertTrue(result.covers(shapely.Point(fixture['point'])))
        for shape in shapes:
            self.assertLess(shape.difference(result.buffer(1e-7)).area,1e-10)


if __name__=='__main__':unittest.main()
