import unittest
from pathlib import Path
import numpy as np
from native_compact_wall_profiles import NativeProfiles
LIB=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/native-wall-profiles-build/Release/compact_wall_profiles.dll')
class NativeProfileTests(unittest.TestCase):
    def make(self,polygons,masks=(),pieces=None):
        points=[];rings=[]
        for i,polygon in enumerate(polygons):
            for h,ring in enumerate(polygon):rings.append([0,i,int(h>0),len(points),len(ring)]);points.extend(ring)
        m=NativeProfiles(LIB,np.array(points),np.array(rings),np.array(pieces or [[0,0,0,10,0,10]]),np.zeros(len(pieces or [0]),np.int32),np.array(masks).reshape(-1,3,2),np.zeros(len(masks),np.int32));self.addCleanup(m.close);return m
    def cast(self,m,along,z):return m.cast(np.array([[-1,along,z,1,along,z]]),minimum=0,padding=0)
    def test_holes_both_windings_and_exact_boundaries(self):
        outer=[[0,0],[10,0],[10,4],[0,4],[0,0]];hole=[[4,1],[6,1],[6,3],[4,3],[4,1]]
        for sign in [1,-1]:
            m=self.make([[outer[::sign],hole[::sign]]]);self.assertEqual(self.cast(m,2,2)[0][0,0],1);self.assertTrue(np.isinf(self.cast(m,5,2)[0][0,0]));self.assertEqual(self.cast(m,4,2)[0][0,0],1)
    def test_microgap_stays_open(self):
        m=self.make([[[[0,0],[4.999999,0],[4.999999,4],[0,4]]],[[[5.000001,0],[10,0],[10,4],[5.000001,4]]]])
        self.assertTrue(np.isinf(self.cast(m,5,2)[0][0,0]));self.assertEqual(self.cast(m,4.999998,2)[0][0,0],1)
    def test_mask_reference_remains_candidate_not_solid(self):
        m=self.make([[[[0,0],[1,0],[1,1],[0,1]]]],masks=[[[4,1],[6,1],[5,3]]]);a,mask=self.cast(m,5,2);self.assertTrue(np.isinf(a[0,0]));self.assertEqual(mask[0,0],1)
    def test_piecewise_inverse_w_keeps_real_bend(self):
        m=self.make([[[[0,0],[10,0],[10,4],[0,4]]]],pieces=[[0,0,0,5,0,5],[0,5,1,10,5,10]])
        self.assertEqual(self.cast(m,2,2)[0][0,0],1);self.assertAlmostEqual(self.cast(m,7.5,2)[0][0,0],1.5)
    def test_height_interpolates_along_nonhorizontal_ray(self):
        m=self.make([[[[0,0],[10,0],[10,1],[0,1]]]])
        out,_=m.cast(np.array([[-1,2,0,1,2,1],[-1,2,1,1,2,3]]),minimum=0,padding=0)
        self.assertAlmostEqual(out[0,0],np.sqrt(5)/2);self.assertTrue(np.isinf(out[1,0]))
if __name__=='__main__':unittest.main()
