import unittest
import numpy as np
from gameplay_standing_volumes import collision_parts, capsule_mesh_distance, vertical_contacts, inside_closed_mesh


def box_body(center=(0,0,0),size=(200,200,200)):
    return dict(AggGeom=dict(BoxElems=[dict(Center=dict(zip('XYZ',center)),Rotation=dict(Pitch=0,Yaw=0,Roll=0),**dict(zip('XYZ',size)))]))


class CollisionTests(unittest.TestCase):
    def test_flat_box_uses_engine_minimum_after_placement_scale(self):
        matrix = np.diag([2., 3., 4., 1.])
        tri, _ = collision_parts(box_body(size=(100, 100, 0)), None, matrix)[0]
        np.testing.assert_allclose(tri.reshape(-1, 3).min(0), [-1, -1.5, -1e-6])
        np.testing.assert_allclose(tri.reshape(-1, 3).max(0), [1, 1.5, 1e-6])

    def test_serialized_box_transform_and_contact(self):
        matrix=np.eye(4);matrix[3,:3]=[300,400,500]
        tri,equations=collision_parts(box_body((0,100,0)),None,matrix)[0]
        np.testing.assert_allclose(tri.reshape(-1,3).min(0),[2,2,4])
        np.testing.assert_allclose(tri.reshape(-1,3).max(0),[4,4,6])
        z,valid=vertical_contacts(tri,np.array([3,3]))
        self.assertAlmostEqual(z[valid].max(),6)
        self.assertAlmostEqual(capsule_mesh_distance(tri,np.array([3,3]),6),.42)

    def test_capsule_side_and_overhead_contact(self):
        tri,_=collision_parts(box_body(),None,np.eye(4))[0]
        self.assertAlmostEqual(capsule_mesh_distance(tri,np.array([1.5,0]),0),.5)
        self.assertAlmostEqual(capsule_mesh_distance(tri,np.array([1.3,0]),0),.3)
        self.assertAlmostEqual(capsule_mesh_distance(tri,np.array([0,0]),-3.0),.46)

    def test_complex_mesh_is_not_replaced_by_hull(self):
        left,_=collision_parts(box_body((-200,0,0)),None,np.eye(4))[0]
        right,_=collision_parts(box_body((200,0,0)),None,np.eye(4))[0]
        original=np.concatenate([left,right])
        actual,equations=collision_parts(dict(CollisionTraceFlag='ECollisionTraceFlag::CTF_UseComplexAsSimple'),original,np.eye(4))[0]
        self.assertIsNone(equations)
        np.testing.assert_array_equal(actual,original)
        self.assertAlmostEqual(capsule_mesh_distance(actual,np.array([0,0]),0),1)


if __name__=='__main__':unittest.main()
