"""Exact analytic capsule clearance and complete standing exclusion controls."""
import copy
import unittest
from types import SimpleNamespace
import numpy as np
import shapely
from scipy.spatial import ConvexHull
from native_capsule_standing import (analytic_capsule_obstacle, blocked_standing_prism,
    blocked_contact_prism, player_center_bounds, enclosed_in_assembly)


def solid(lo, hi, kill=False):
    vertices = np.array([[x,y,z] for x in [lo[0],hi[0]]
        for y in [lo[1],hi[1]] for z in [lo[2],hi[2]]])
    hull = ConvexHull(vertices)
    return SimpleNamespace(rows=[dict(id='independent-solid', kill=kill)],
        equations=[hull.equations], triangles=[vertices[hull.simplices]],
        tree=shapely.STRtree([shapely.box(*lo[:2],*hi[:2])]))


class CapsuleStandingTests(unittest.TestCase):
    def setUp(self):
        self.shape = dict(centerMeters=[0.,0.,0.], axis=[1.,0.,0.],
            radiusMeters=.045, segmentHalfLengthMeters=.075,
            bounds=[[-.12,-.045,-.045],[.12,.045,.045]])

    def test_analytic_clearance_uses_round_body(self):
        domain=shapely.box(-1.,-1.,1.,1.)
        blocked=analytic_capsule_obstacle(self.shape,domain,np.array([0.,0.,-.42]))
        self.assertTrue(blocked.covers(shapely.Point(0.,0.)))
        self.assertFalse(blocked.covers(shapely.Point(.8,0.)))
        self.assertTrue(analytic_capsule_obstacle(self.shape,domain,
            np.array([0.,0.,.045])).is_empty)

    def test_player_center_prism_and_wrong_height_fault(self):
        lo,hi=player_center_bounds(self.shape)
        volumes=solid(lo-.01,hi+.01,kill=True)
        self.assertIsNotNone(blocked_standing_prism(self.shape,volumes))
        moved=copy.deepcopy(self.shape);moved['centerMeters'][2]+=.1
        self.assertIsNone(blocked_standing_prism(moved,volumes))

    def test_complete_contacts_are_buried_even_when_body_is_not(self):
        # Independently derived horizontal-capsule upper contact bounds.
        radius=.045;half=.075;sine=np.sin(np.deg2rad(44));cosine=np.cos(np.deg2rad(44))
        lo=np.array([-half-radius*sine,-radius*sine,radius*cosine])
        hi=np.array([half+radius*sine,radius*sine,radius])
        volumes=solid(lo-.008,hi+.008)
        self.assertIsNotNone(blocked_contact_prism(self.shape,volumes))
        self.assertIsNone(blocked_standing_prism(self.shape,volumes))
        self.assertIsNone(enclosed_in_assembly(self.shape,volumes))
        wrong_height=copy.deepcopy(self.shape);wrong_height['centerMeters'][2]+=.03
        self.assertIsNone(blocked_contact_prism(wrong_height,volumes))

    def test_missing_containing_body_does_not_exclude_a_capsule(self):
        volumes=solid(np.array([2.,2.,2.]),np.array([3.,3.,3.]))
        self.assertIsNone(blocked_contact_prism(self.shape,volumes))
        self.assertIsNone(blocked_standing_prism(self.shape,volumes))
        self.assertIsNone(enclosed_in_assembly(self.shape,volumes))
        volumes=solid(np.array([-.2,-.2,-.2]),np.array([.2,.2,.2]))
        self.assertIsNotNone(enclosed_in_assembly(self.shape,volumes))


if __name__=='__main__':
    unittest.main()
