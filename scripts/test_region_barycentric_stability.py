import unittest
import numpy as np
from authored_region_cells import barycentric


class RegionBarycentricStabilityTests(unittest.TestCase):
    def test_translated_skinny_triangle_vertex_is_exact(self):
        tri=np.array([[133.5002387255596,167.4286339258961],[138.45885767652544,168.17729410276942],[138.45885767652544,168.17729724694064]])
        np.testing.assert_allclose(barycentric(tri,tri),np.eye(3),atol=2e-10,rtol=0)
        p=np.array([[136.4723103396207,167.8773639103874],[136.47230886596762,167.87736180335568],[136.5155817518789,167.8838952125046],[136.5155821723879,167.8838971879688]])
        w=barycentric(p,tri)
        self.assertGreaterEqual(w.min(),-1e-8)
        np.testing.assert_allclose(w,barycentric(p-tri[0],tri-tri[0]),atol=0,rtol=0)
        np.testing.assert_allclose(tri[0]+w[:,1:]@(tri[1:]-tri[0]),p,atol=3e-14,rtol=0)
    def test_outside_skinny_triangle_stays_outside(self):
        tri=np.array([[100.,200.],[104.,201.],[104.,201.00001]])
        w=barycentric(np.array([[104.,201.001]]),tri)
        self.assertLess(w.min(),-90)

if __name__=='__main__':unittest.main()
