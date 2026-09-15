"""A sloped floor must permit tangent feet without losing ceiling clearance."""
import unittest
import numpy as np
import shapely
from scipy.spatial import ConvexHull
from gameplay_standing_volumes import StandingVolumes, capsule_mesh_distance,walkable_slope_angle,collision_parts
from build_all_map_gameplay_supports import convex_capsule_obstacle,standing_obstacles
from build_all_physical_standing_surfaces import top_planes,standing_face_domain
from standing_complex_clearance import complex_capsule_obstacle


def fixture(ceiling=False,unwalkable=False,slope=.5,ceiling_elevation=1.97):
 v=StandingVolumes.__new__(StandingVolumes);v.rows=[];v.triangles=[];v.equations=[]
 boxes=[np.array([[x,y,z+slope*x] for x in [-2.,2.] for y in [-2.,2.] for z in [-1.,0.]])]
 if ceiling:boxes.append(np.array([[x,y,z] for x in [-2.,2.] for y in [-2.,2.] for z in [ceiling_elevation,ceiling_elevation+.23]]))
 for i,points in enumerate(boxes):
  hull=ConvexHull(points);bounds=[points.min(0).tolist(),points.max(0).tolist()]
  v.rows.append(dict(id=str(i),bounds=bounds,kill=False,unwalkable=unwalkable and i==0))
  triangles=points[hull.simplices]
  normals=np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0])
  flip=np.einsum('ij,ij->i',normals,hull.equations[:,:3])<0
  triangles[flip]=triangles[flip][:,[0,2,1]]
  v.triangles.append(triangles);v.equations.append(hull.equations)
 v.bounds=np.array([r['bounds'] for r in v.rows]);v.tree=shapely.STRtree([shapely.box(-2,-2,2,2) for _ in boxes])
 return v


class StandingContactTest(unittest.TestCase):
 def test_adjacent_collider_can_supply_the_actual_standing_contact(self):
  v=fixture(ceiling=True,ceiling_elevation=.79);xy=np.array([1.95,0.])
  contact=v.standing_contact(0,xy,.975,np.array([.5,0.,0.]))
  self.assertEqual(contact['collision'],'1')
  self.assertAlmostEqual(contact['capsuleFloorMeters'],1.02)
  self.assertEqual(v.exclusions(xy,.975,capsule_floor_override=contact['capsuleFloorMeters']),[])

 def test_a_clear_platform_above_unwalkable_collision_is_not_rejected(self):
  v=fixture(unwalkable=True,slope=0.)
  self.assertEqual(v.exclusions(np.zeros(2),.05),[])

 def test_rounded_feet_can_rest_on_the_crest_of_a_finite_ramp(self):
  v=fixture();xy=np.array([1.95,0.]);plane=np.array([.5,0.,0.])
  contact=v.standing_contact(0,xy,.975,plane)
  self.assertIsNotNone(contact)
  self.assertEqual(contact['contactKind'],'edge')
  self.assertAlmostEqual(capsule_mesh_distance(v.triangles[0],xy,contact['capsuleFloorMeters']),.42)
  self.assertEqual(v.exclusions(xy,.975,capsule_floor_override=contact['capsuleFloorMeters']),[])

 def test_finite_ramp_domain_requires_real_capsule_contact(self):
  v=fixture();plane=np.array([.5,0.,0.])
  group=top_planes(v.triangles[0],v.equations[0],44.)
  faces=next(ids for key,ids in group.items() if abs(key[2])<1e-8)
  domain=standing_face_domain(v.triangles[0],faces,plane)
  for x,standing in [(1.95,False),(-2.1,True)]:
   xy=np.array([x,0.]);floor=.5*x+.42*(np.sqrt(1.25)-1)
   self.assertEqual(domain.covers(shapely.Point(xy)),standing)
   distance=capsule_mesh_distance(v.triangles[0],xy,floor)
   if standing:self.assertAlmostEqual(distance,.42)
   else:self.assertGreater(distance,.425)

 def test_complex_ramp_uses_rounded_feet_at_its_local_plane(self):
  v=fixture();v.equations=[None]
  domain=shapely.box(-1,-1,1,1)
  self.assertTrue(complex_capsule_obstacle(v,0,domain,np.array([.5,0.,0.])).is_empty)

 def test_complex_ceiling_still_blocks_a_capsule(self):
  v=fixture(ceiling=True);v.equations=[None,None]
  result=complex_capsule_obstacle(v,1,shapely.box(-1,-1,1,1),np.array([.5,0.,0.]))
  self.assertTrue(result.covers(shapely.Point(0,0)))

 def test_unwalkable_contact_uses_local_ramp_height(self):
  v=fixture(unwalkable=True,slope=.5)
  blocked=standing_obstacles(v,shapely.box(-1,-1,1,1),-.5,floor_plane=np.array([.5,0.,0.]))
  self.assertTrue(blocked.covers(shapely.Point(0,0)))
  self.assertTrue(blocked.covers(shapely.Point(.8,0)))
  higher=standing_obstacles(v,shapely.box(-1,-1,1,1),-.3,floor_plane=np.array([.5,0.,.2]))
  self.assertFalse(higher.covers(shapely.Point(.8,0)))

 def test_complex_surface_four_millimetres_above_feet_is_not_ignored(self):
  v=fixture(slope=0.);v.equations=[None]
  blocked=standing_obstacles(v,shapely.box(-1,-1,1,1),-.0045)
  self.assertTrue(blocked.covers(shapely.Point(0,0)))

 def test_complex_closed_body_does_not_offer_its_underside(self):
  v=fixture(slope=0.)
  planes=top_planes(v.triangles[0],None,44.)
  self.assertEqual(len(planes),1)
  self.assertAlmostEqual(next(iter(planes))[2],0.)

 def test_closed_convex_complex_ramp_keeps_its_exact_boundary(self):
  triangles=fixture().triangles[0]
  result=collision_parts({'CollisionTraceFlag':'CTF_UseComplexAsSimple'},triangles,np.eye(4))
  self.assertIsNotNone(result[0][1])
  self.assertTrue(np.array_equal(np.unique(triangles.reshape(-1,3),axis=0),np.unique(result[0][0].reshape(-1,3),axis=0)))

 def test_open_complex_floor_is_never_filled_with_a_convex_hull(self):
  triangles=fixture().triangles[0][:-1]
  result=collision_parts({'CollisionTraceFlag':'CTF_UseComplexAsSimple'},triangles,np.eye(4))
  self.assertIsNone(result[0][1])

 def test_valid_forty_degree_ramp_is_not_rejected_as_body_penetration(self):
  v=fixture(slope=np.tan(np.deg2rad(40)))
  self.assertEqual(v.exclusions(np.zeros(2),0.),[])
  self.assertAlmostEqual(v.capsule_floor(np.zeros(2),0.),.42*(1/np.cos(np.deg2rad(40))-1))

 def test_omitted_zero_angle_does_not_break_an_increase_override(self):
  self.assertEqual(walkable_slope_angle({'body':{'WalkableSlopeOverride':{'WalkableSlopeBehavior':'WalkableSlope_Increase'}}}),44.)

 def test_rounded_feet_rest_tangent_to_the_ramp(self):
  v=fixture();xy=np.array([0.,0.])
  self.assertLess(capsule_mesh_distance(v.triangles[0],xy,0.,.42,1.96),.405)
  lifted=v.capsule_floor(xy,0.)
  self.assertAlmostEqual(lifted,.42*(np.sqrt(1.25)-1))
  self.assertAlmostEqual(capsule_mesh_distance(v.triangles[0],xy,lifted,.42,1.96),.42)
  self.assertEqual(v.exclusions(xy,0.),[])

 def test_lifting_onto_the_ramp_still_checks_the_ceiling(self):
  failures=fixture(ceiling=True).exclusions(np.array([0.,0.]),0.)
  self.assertEqual([r['volume'] for r in failures],['1'])

 def test_unwalkable_ramps_stay_excluded(self):
  failures=fixture(unwalkable=True).exclusions(np.array([0.,0.]),0.)
  self.assertEqual([r['reason'] for r in failures],['explicit-unwalkable-contact'])

 def test_plane_clearance_preserves_tangent_ramp_and_rejects_low_ceiling(self):
  domain=shapely.box(-1,-1,1,1);plane=np.array([.5,0.,0.])
  self.assertTrue(convex_capsule_obstacle(fixture(),0,domain,plane).is_empty)
  self.assertTrue(convex_capsule_obstacle(fixture(ceiling=True),1,domain,plane).covers(shapely.Point(0,0)))

 def test_rounded_feet_clear_low_edge_but_not_a_taller_step(self):
  domain=shapely.box(-1,-1,1,1);plane=np.zeros(3)
  for height,blocked in [(.01,False),(.3,True)]:
   v=fixture();vertices=np.array([[x,y,z] for x in [.35,1.] for y in [-1.,1.] for z in [-1.,height]])
   hull=ConvexHull(vertices);v.triangles=[vertices[hull.simplices]];v.equations=[hull.equations]
   shape=convex_capsule_obstacle(v,0,domain,plane)
   self.assertEqual(shape.covers(shapely.Point(0,0)),blocked)


if __name__=='__main__':unittest.main()
