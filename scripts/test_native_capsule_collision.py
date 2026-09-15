"""Complete capsule containment and regional influence controls."""
import copy
import unittest
from types import SimpleNamespace
import numpy as np
import shapely
from scipy.spatial import ConvexHull

from native_capsule_collision import capsule_parts, outside_capsules, support
from redundant_capsule_collision import enclosed_capsules


def body(radius=15., length=150.):
    return dict(AggGeom=dict(SphylElems=[dict(Center=dict(X=0.,Y=0.,Z=0.),
        Rotation=dict(Pitch=0.,Yaw=0.,Roll=0.),Radius=radius,Length=length,
        CollisionEnabled='ECollisionEnabled::QueryAndPhysics',RestOffset=0.)]))


def containing_box(x=.4, y=.4, z=2.):
    vertices=np.array([[a,b,c] for a in [-x,x] for b in [-y,y] for c in [-z,z]])
    hull=ConvexHull(vertices)
    return SimpleNamespace(rows=[dict(id='known-box')],equations=[hull.equations],
        tree=shapely.STRtree([shapely.box(-x,-y,x,y)]))


class NativeCapsules(unittest.TestCase):
    def test_local_pitch_quarter_turn_preserves_scaled_dimensions_and_center(self):
        source = body(radius=10., length=20.)
        element = source['AggGeom']['SphylElems'][0]
        element['Center'] = dict(X=1., Y=2., Z=3.)
        element['Rotation']['Pitch'] = 90.
        matrix = np.diag([2., 3., 4., 1.])
        shape = capsule_parts(source, matrix)[0]
        np.testing.assert_allclose(shape['axis'], [-1., 0., 0.])
        np.testing.assert_allclose(shape['centerMeters'], [.02, -.06, .12])
        self.assertAlmostEqual(shape['radiusMeters'], .3)
        self.assertAlmostEqual(shape['segmentHalfLengthMeters'], .5)
        element['Rotation']['Pitch'] = -90.
        np.testing.assert_allclose(capsule_parts(source, matrix)[0]['axis'], [1., 0., 0.])
        element['Rotation']['Pitch'] = 45.
        with self.assertRaises(ValueError): capsule_parts(source, matrix)

    def test_nonuniform_scaling_and_clamps(self):
        matrix=np.diag([2.,3.,4.,1.]);matrix[3,:3]=[100.,200.,300.]
        source=body(radius=10.,length=20.)
        source['AggGeom']['SphylElems'][0]['Center']=dict(X=1.,Y=2.,Z=3.)
        original=copy.deepcopy(source)
        shape=capsule_parts(source,matrix)[0]
        np.testing.assert_allclose(shape['centerMeters'],[1.02,1.94,3.12])
        self.assertAlmostEqual(shape['radiusMeters'],.3)
        self.assertAlmostEqual(shape['segmentHalfLengthMeters'],.5)
        self.assertEqual(source,original)
        clamped=capsule_parts(body(radius=0.,length=0.),np.eye(4))[0]
        self.assertEqual(clamped['radiusMeters'],.001)
        self.assertEqual(clamped['segmentHalfLengthMeters'],.0005)
        with self.assertRaises(ValueError):capsule_parts(source,np.diag([-1.,1.,1.,1.]))

    def test_complete_capsule_fits_where_enclosing_sphere_does_not(self):
        matrix=np.diag([1.,1.0001,1.,1.])
        proof=enclosed_capsules(body(),matrix,containing_box())
        self.assertIsNotNone(proof)
        self.assertEqual(proof['capsules'][0]['boundKind'],'analytic-scaled-capsule')
        self.assertAlmostEqual(proof['capsules'][0]['containingVolumes'][0]['minimumInsetMeters'],.249985)
        # Move the capsule until a curved side protrudes. Its centre remains
        # inside the box, so centre-only or cap-only checks would be wrong.
        matrix[3,0]=30.
        self.assertIsNone(enclosed_capsules(body(),matrix,containing_box()))
        self.assertIsNone(enclosed_capsules(body(),np.eye(4),containing_box(z=.8)))

    def test_support_reaches_actual_curved_boundary(self):
        shape=capsule_parts(body(),np.eye(4))[0]
        random=np.random.default_rng(9)
        directions=random.normal(size=(100,3));directions/=np.linalg.norm(directions,axis=1)[:,None]
        boundary=directions*.15
        boundary[:,2]+=.75*np.sign(directions[:,2])
        np.testing.assert_allclose(support(shape,directions),np.sum(boundary*directions,axis=1),atol=1e-14)

    def test_region_uses_entire_shape_plus_player_radius(self):
        region=shapely.box(0.,0.,1.,1.)
        matrix=np.eye(4);matrix[3,:3]=[200.,50.,0.]
        proof=outside_capsules(body(),matrix,region)
        self.assertIsNotNone(proof)
        self.assertAlmostEqual(proof['capsules'][0]['distanceToRegionMeters'],.85)
        matrix[3,0]=150.
        self.assertIsNone(outside_capsules(body(),matrix,region))
        # A tilted long capsule reaches the region even when its centre does
        # not. The native bounds must include its complete cylinder segment.
        matrix=np.array([[0.,0.,-1.,0.],[0.,1.,0.,0.],[1.,0.,0.,0.],[180.,50.,0.,1.]])
        self.assertIsNone(outside_capsules(body(),matrix,region))


if __name__=='__main__':unittest.main()
