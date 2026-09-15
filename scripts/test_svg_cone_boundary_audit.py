import unittest
import numpy as np
import shapely
from audit_svg_cone_boundaries import audit


class BoundaryOracleTests(unittest.TestCase):
    def check(self, polygon, wall_x, active=True):
        shapes=np.array([shapely.box(wall_x,-10,wall_x+.5,10)],dtype=object)
        return audit(dict(originSvg=[0,0],polygonSvg=polygon,rangeSvg=10,
            activeWallIds=['wall'] if active else []),[dict(id='wall')],shapely.STRtree(shapes),shapes)[1]

    def test_detects_early_cut_without_moving_the_wall(self):
        issues=self.check([[0,0],[2,-2],[2,2]],3)
        self.assertEqual(issues[0]['kind'],'early-clip')
        self.assertAlmostEqual(issues[0]['normalGapSvg'],1)

    def test_detects_leaking_past_a_wall(self):
        self.assertEqual(self.check([[0,0],[4,-2],[4,2]],3)[0]['kind'],'wall-leak')

    def test_exact_wall_contact_is_clear(self):
        self.assertEqual(self.check([[0,0],[3,-2],[3,2]],3),[])

    def test_inactive_wall_does_not_validate_an_early_stop(self):
        self.assertIsNone(self.check([[0,0],[3,-2],[3,2]],3,False)[0]['wallId'])

    def test_range_arc_chord_is_not_a_wall_gap(self):
        self.assertEqual(self.check([[0,0],[8,-6],[8,6]],30),[])


if __name__=='__main__': unittest.main()
