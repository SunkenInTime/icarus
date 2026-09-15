import unittest
from types import SimpleNamespace
import numpy as np
import shapely

from redundant_capsule_collision import enclosed_capsules


class CapsuleContainmentTests(unittest.TestCase):
    def test_rotated_capsule_and_box_must_both_be_fully_contained(self):
        normals = np.r_[np.eye(3), -np.eye(3)]
        volume = SimpleNamespace(rows=[dict(id='box')], equations=[np.c_[normals,-np.ones(6)]],
            tree=shapely.STRtree([shapely.box(-1,-1,1,1)]))
        capsule = dict(Center=dict(X=0,Y=0,Z=0), Radius=5, Length=20,
            Rotation=dict(Pitch=90,Yaw=0,Roll=0))
        box = dict(Center=dict(X=0,Y=0,Z=0), X=10,Y=10,Z=150,
            Rotation=dict(Pitch=0,Yaw=0,Roll=0))
        body = dict(AggGeom=dict(SphylElems=[capsule],BoxElems=[box]))
        proof = enclosed_capsules(body,np.eye(4),volume)
        self.assertEqual(proof['capsules'][0]['boundKind'],'conservative-enclosing-sphere')
        self.assertEqual(len(proof['boxes']),1)
        self.assertAlmostEqual(proof['boxes'][0]['containingVolumes'][0]['minimumInsetMeters'],.25)
        box['Center']['Z'] = 26
        self.assertIsNone(enclosed_capsules(body,np.eye(4),volume))
        box['Center']['Z'] = 0
        capsule['Center']['X'] = 86
        self.assertIsNone(enclosed_capsules(body,np.eye(4),volume))
        capsule['Center']['X'] = 0
        body['AggGeom']['SphereElems'] = [{}]
        self.assertIsNone(enclosed_capsules(body,np.eye(4),volume))
        del body['AggGeom']['SphereElems']
        volume.rows[0]['kill'] = True
        self.assertIsNone(enclosed_capsules(body,np.eye(4),volume))

    def test_nonuniform_outer_bound_rejects_any_exposed_sphere(self):
        normals = np.r_[np.eye(3), -np.eye(3)]
        volume = SimpleNamespace(rows=[dict(id='box')], equations=[np.c_[normals, -np.ones(6)]],
            tree=shapely.STRtree([shapely.box(-1, -1, 1, 1)]))
        capsule = dict(Center=dict(X=0, Y=0, Z=0), Radius=3, Length=10,
            Rotation=dict(Pitch=0, Yaw=0, Roll=0))
        body = dict(AggGeom=dict(SphylElems=[capsule]))
        matrix = np.diag([.99, 1.01, 1., 1.])
        proof = enclosed_capsules(body, matrix, volume)
        self.assertEqual(proof['capsules'][0]['boundKind'], 'conservative-enclosing-sphere')
        self.assertAlmostEqual(proof['capsules'][0]['radiusMeters'], .0813)
        matrix[3, 0] = 94
        self.assertIsNone(enclosed_capsules(body, matrix, volume))
        matrix = np.eye(4)
        matrix[0, 1] = .2
        self.assertIsNone(enclosed_capsules(body, matrix, volume))

    def test_containment_accounts_for_curved_caps_and_rejects_exposed_top(self):
        normals = np.r_[np.eye(3), -np.eye(3)]
        volume = SimpleNamespace(rows=[dict(id='box')], equations=[np.c_[normals, -np.ones(6)]],
            tree=shapely.STRtree([shapely.box(-1, -1, 1, 1)]))
        capsule = dict(Center=dict(X=0, Y=0, Z=0), Radius=30, Length=100,
            Rotation=dict(Pitch=0, Yaw=0, Roll=0))
        body = dict(AggGeom=dict(SphylElems=[capsule]))
        proof = enclosed_capsules(body, np.eye(4), volume)
        self.assertAlmostEqual(proof['capsules'][0]['containingVolumes'][0]['minimumInsetMeters'], .2)
        capsule['Center']['Z'] = 21
        self.assertIsNone(enclosed_capsules(body, np.eye(4), volume))


if __name__ == '__main__':
    unittest.main()
