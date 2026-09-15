"""Portal lookup must match pointwise source/nav choices between every cut."""
import unittest
import numpy as np
from static_floor_portal import choose, compile_portal


class PortalTests(unittest.TestCase):
    def test_terrain_step_replaces_base_at_native_climb_bound(self):
        portal = [[0, 0], [1, 0]]
        sources = [[0, 0, 0], [.2, 0, .25]]
        rows = compile_portal(portal, np.array([0, 0, 0]), sources, [[0, 0, 0]], terrain=[False, True])
        self.assertEqual(rows[0]['candidates'], [1])
        self.assertAlmostEqual(rows[0]['hi'], .500005)
        self.assertEqual(rows[-1]['candidates'], [0])

    def test_raised_prop_without_base_is_not_ground_transition(self):
        rows = compile_portal([[0, 0], [1, 0]], [0, 0, 0], [[0, 0, .3]], [[0, 0, .3]], raised=[True])
        self.assertEqual(rows, [dict(lo=0., hi=1., candidates=[])])

    def test_random_portal_lookup_matches_pointwise_policy(self):
        rng = np.random.default_rng(581424)
        for case in range(100):
            endpoints = rng.uniform(-2, 2, (2, 2))
            previous = rng.uniform(-.25, .25, 3)
            sources = rng.uniform(-.3, .3, (6, 3))
            nav = rng.uniform(-.3, .3, (3, 3))
            terrain, raised = rng.random(6) < .15, rng.random(6) < .15
            terrain &= ~raised
            rows = compile_portal(endpoints, previous, sources, nav, terrain, raised)
            for t in rng.uniform(0, 1, 1000):
                row = next(row for row in rows if row['lo'] <= t <= row['hi'])
                actual = choose(endpoints[0]+t*(endpoints[1]-endpoints[0]), previous, sources, nav, terrain, raised)
                self.assertEqual(row['candidates'], actual, (case, t, row))


if __name__ == '__main__':
    unittest.main()
