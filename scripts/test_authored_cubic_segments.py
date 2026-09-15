import unittest
import numpy as np
from authored_cubic_segments import cubic_segments


class CubicSegmentsTest(unittest.TestCase):
    def test_split204_preserves_curve_and_shared_endpoints(self):
        points = np.array([[40.3722,186.527], [40.3722,186.952],
                           [65.1816,186.704], [77.5863,186.527]])
        rows = cubic_segments(points)
        self.assertGreater(len(rows), 1)
        self.assertEqual(rows[0]['startSvg'], points[0].tolist())
        self.assertEqual(rows[-1]['endSvg'], points[-1].tolist())
        for a, b in zip(rows[:-1], rows[1:]):
            self.assertEqual(a['endSvg'], b['startSvg'])
            self.assertEqual(a['t1'], b['t0'])
        for row in rows:
            self.assertLessEqual(row['controlHullDistanceBoundSvg'], 1e-5)
            t = np.linspace(row['t0'], row['t1'], 101)[:, None]
            curve = (1-t)**3*points[0]+3*(1-t)**2*t*points[1]+3*(1-t)*t*t*points[2]+t**3*points[3]
            start, end = np.array(row['startSvg']), np.array(row['endSvg'])
            delta = end-start
            u = np.clip((curve-start)@delta/(delta@delta),0,1)
            distance = np.linalg.norm(curve-start-u[:,None]*delta,axis=1)
            self.assertLessEqual(distance.max(), row['controlHullDistanceBoundSvg']+1e-12)

    def test_straight_edge_needs_no_artificial_detail(self):
        self.assertEqual(len(cubic_segments([[0,0],[1,0],[2,0],[3,0]])),1)

    def test_closed_cubic_is_not_mistaken_for_zero_length(self):
        self.assertGreater(len(cubic_segments([[0,0],[1,1],[-1,1],[0,0]],.001)),2)


if __name__ == '__main__':
    unittest.main()
