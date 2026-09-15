"""Open alpha endpoints and point contacts must use exact source fallback."""
from pathlib import Path
import unittest
import numpy as np
from build_local_floor_atlas import support_bvh
from verify_native_floor_atlas import NativeAtlas


class AnalyticContact:
    def __init__(self, opaque):
        self.opaque = opaque

    def cast(self, start, end, min_distance=1e-5, end_padding=1e-5):
        start, end = np.array(start), np.array(end)
        if abs(end[0]-start[0]) < 1e-15:
            return None
        t = -start[0]/(end[0]-start[0])
        length = np.linalg.norm(end-start)
        if not 0 <= t <= 1 or t*length < min_distance or t*length > length-end_padding:
            return None
        point = start+t*(end-start)
        if self.opaque(point[1]):
            return dict(point=point.tolist(),face=123,distanceMeters=float(t*length))
        return None


class ContactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        revision=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
        if not (revision/'native-tactical-rays-build/Release/tactical_floor_atlas.dll').exists():
            raise unittest.SkipTest('Diagnostic native atlas DLL not built')
        cls.atlas=NativeAtlas(revision)

    def cast(self, line, closed, y, opaque):
        triangles=np.array([[[-2.,-2.],[2.,-2.],[2.,2.]],[[-2.,-2.],[2.,2.],[-2.,2.]]])
        polygons=triangles.reshape(-1,2);ranges=np.array([[0,3],[3,3]],dtype=np.int32)
        bounds,nodes,cells=support_bvh(polygons,ranges)
        self.atlas.arrays.update(polygons=polygons,polygonRanges=ranges,planes=np.zeros((2,3)),
            originalTriangles=triangles,sourceFaces=np.array([0,1],dtype=np.int64),terrain=np.zeros(2,dtype=np.uint8),
            segments=np.array([line],dtype=float),segmentRanges=np.array([[0,1],[0,1]],dtype=np.int32),
            segmentFaces=np.array([123],dtype=np.int32),segmentEndpointClosed=np.array([closed],dtype=np.uint8),
            endpointTolerance=np.array([1e-7]),fallback=np.zeros(2,dtype=np.uint8),
            bvhBounds=bounds,bvhNodes=nodes,bvhCells=cells,transitCellGroups=np.full(2,-1,dtype=np.int32))
        return self.atlas.cast(AnalyticContact(opaque),[-1,y,1.75],[1,0],2.)

    def test_open_endpoint_does_not_become_a_wall(self):
        result=self.cast([[0,-1],[0,1]],[1,0],1,lambda y:-1<=y<1)
        self.assertEqual(result['distanceMeters'],2)
        self.assertGreater(result['fallbacks'],0)

    def test_closed_endpoint_and_nearby_interior_remain_opaque(self):
        for y in [-1,1-1e-9]:
            result=self.cast([[0,-1],[0,1]],[1,0],y,lambda value:-1<=value<1)
            self.assertAlmostEqual(result['distanceMeters'],1)
            self.assertGreater(result['fallbacks'],0)

    def test_interior_uses_precomputed_segment(self):
        result=self.cast([[0,-1],[0,1]],[1,0],0,lambda y:-1<=y<1)
        self.assertAlmostEqual(result['distanceMeters'],1)
        self.assertEqual(result['fallbacks'],0)

    def test_isolated_contact_defers_face_plane_semantics_to_source(self):
        for opacity,expected in [(lambda y:y==0,1),(lambda y:False,2)]:
            result=self.cast([[0,0],[0,0]],[1,1],0,opacity)
            self.assertAlmostEqual(result['distanceMeters'],expected)
            self.assertGreater(result['fallbacks'],0)


if __name__=='__main__':
    unittest.main()
