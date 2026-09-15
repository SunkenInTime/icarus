"""Native cone source fallbacks preserve masked and opaque source contacts."""
from pathlib import Path
import ctypes
import unittest
import numpy as np
from build_local_floor_atlas import support_bvh
from test_audit_tactical_target_rays import scene,wall
from verify_native_floor_atlas import NativeAtlas
from verify_native_floor_cone import NativeCone

class NativeConeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        revision=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
        cls.atlas=NativeAtlas(revision)
    def model(self,opacity=None,coincident_opaque=False):
        source=scene(wall(0,8)+(wall(0,8) if coincident_opaque else []))
        if opacity is not None:
            source.arrays['faceMasks'][:2]=[0,1]
            source.arrays['maskedMaterials']=np.array([0,0]);source.arrays['maskedUvs']=np.zeros((2,3,2))
            source.materials={0:dict(texture=0,wrapS='clamp',wrapT='clamp',threshold=.5)};source.textures=[np.array([[opacity]])]
        triangles=np.array([[[-2.,-2.],[2.,-2.],[2.,2.]],[[-2.,-2.],[2.,2.],[-2.,2.]]]);polygons=triangles.reshape(-1,2);ranges=np.array([[0,3],[3,3]],dtype=np.int32)
        bounds,nodes,cells=support_bvh(polygons,ranges)
        self.atlas.arrays.update(polygons=polygons,polygonRanges=ranges,planes=np.zeros((2,3)),originalTriangles=triangles,
            sourceFaces=np.array([0,1],dtype=np.int64),terrain=np.zeros(2,dtype=np.uint8),segments=np.empty((0,2,2)),segmentRanges=np.zeros((2,2),dtype=np.int32),
            segmentFaces=np.empty(0,dtype=np.int32),segmentEndpointClosed=np.empty((0,2),dtype=np.uint8),endpointTolerance=np.empty(0),fallback=np.ones(2,dtype=np.uint8),
            bvhBounds=bounds,bvhNodes=nodes,bvhCells=cells,transitCellGroups=np.full(2,-1,dtype=np.int32))
        return source
    def test_opaque_fallback_stays_inside_native_cone(self):
        source=self.model();cone=NativeCone(self.atlas,source)
        try:result=cone.cone([-1,0,1.75],2,np.array([-.4,0,.4]))
        finally:cone.close()
        np.testing.assert_allclose(result['mesh'][:,1],1/np.cos(result['mesh'][:,0]),atol=1e-12,rtol=0)
        self.assertEqual(result['alphaCallbacks'],0)
    def test_masked_source_calls_exact_sampler(self):
        for opacity in [0.,1.]:
            source=self.model(opacity);cone=NativeCone(self.atlas,source)
            try:result=cone.cone([-1,0,1.75],2,np.array([-.4,0,.4]))
            finally:cone.close()
            expected=2 if opacity==0 else 1/np.cos(result['mesh'][:,0])
            np.testing.assert_allclose(result['mesh'][:,1],expected,atol=1e-12,rtol=0)
            self.assertGreater(result['alphaCallbacks'],0)
    def test_transparent_face_preserves_coincident_opaque_wall(self):
        source=self.model(0.,True);cone=NativeCone(self.atlas,source)
        try:result=cone.cone([-1,0,1.75],2,np.array([-.4,0,.4]))
        finally:cone.close()
        np.testing.assert_allclose(result['mesh'][:,1],1/np.cos(result['mesh'][:,0]),atol=1e-12,rtol=0)
        self.assertGreater(result['alphaCallbacks'],0)
    def test_angular_gate_preserves_wrap_inside_and_vertex_tangent_queries(self):
        source=self.model();cone=NativeCone(self.atlas,source)
        toggle=self.atlas.dll.set_floor_angular_rejection;toggle.argtypes=[ctypes.c_int]
        tangent=np.arctan2(2,3)
        seeds_list=[np.array([-.4,0,.4]),np.array([np.pi-.4,np.pi,np.pi+.4]),np.array([tangent-1e-12,tangent,tangent+1e-12])]
        try:
            for seeds in seeds_list:
                toggle(0);control=cone.cone([-1,0,1.75],2,seeds)
                toggle(1);candidate=cone.cone([-1,0,1.75],2,seeds)
                self.assertEqual(control['queries'],candidate['queries'])
                np.testing.assert_array_equal(control['mesh'],candidate['mesh'])
        finally:toggle(0);cone.close()
if __name__=='__main__':unittest.main()
