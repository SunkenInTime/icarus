"""Region partition regressions for shared vertical sheets and active display W."""
import unittest
import json
from pathlib import Path
import numpy as np
from shapely.geometry import Polygon
from shapely.ops import unary_union
from authored_region_cells import region_fragments,barycentric,partition_mesh
from authored_wall_profile_cells import inverse_in_cell
from tactical_alignment_composite import explicit_warp

class RegionTests(unittest.TestCase):
    def test_captured_collapsed_polygon_has_no_overlapping_source_fans(self):
        fixture=json.loads((Path(__file__).parent/'fixtures/collapsed_region_partition.json').read_text())
        data=np.array(fixture['data']);points=np.array(fixture['points']);cells=np.array(fixture['triangles'])
        original=Polygon(data[:,4:6]);parts=partition_mesh(data,points,cells)
        fans=[Polygon(part[[0,j,j+1],4:6]) for part,_ in parts for j in range(1,len(part)-1)]
        self.assertLess(abs(sum(p.area for p in fans)-original.area),1e-12)
        self.assertLess(unary_union(fans).symmetric_difference(original).area,1e-12)
        self.assertLess(sum(p.area for p in fans)-unary_union(fans).area,1e-12)

    def check_triangle(self,xyz,target):
        source=np.array([[0.,0.],[2.,0.],[2.,2.],[0.,2.]])
        cells=np.array([[0,1,2],[0,2,3]])
        family=dict(sourceVerticesSvg=source,targetVerticesSvg=target,triangles=cells)
        display=np.array([[-1.,-1.],[4.,-1.],[4.,4.],[-1.,4.]])
        delta=np.array([[0.,0.],[.2,0.],[.4,.1],[0.,.2]])
        warp=explicit_warp(display,delta,np.array([[0,1,2],[0,2,3]]))
        parts=region_fragments(np.column_stack((xyz,np.eye(3))),family,warp)
        polys=[Polygon(p[:,4:6]).convex_hull for p,_,_ in parts]
        self.assertAlmostEqual(unary_union(polys).area,.5,places=10)
        self.assertAlmostEqual(sum(p.area for p in polys),.5,places=10)
        for part,wcell,rcell in parts:
            original=part[:,3:]@xyz
            expected=barycentric(original[:,:2],source[cells[rcell]])@target[cells[rcell]]
            np.testing.assert_allclose(part[:,:2],expected,atol=1e-10)
            np.testing.assert_allclose(part[:,2],original[:,2],atol=1e-12)
            # The inverse-W position is a separate affine transform; source
            # interpolation weights must not be overwritten by its weights.
            physical=inverse_in_cell(part[:,:2],warp,wcell)
            self.assertTrue(np.isfinite(physical).all())

    def test_vertical_sheet_on_shared_source_edge_is_partitioned_once(self):
        self.check_triangle(np.array([[0.,0.,1.],[2.,2.,1.],[2.,2.,3.]]),np.array([[0.,0.],[2.,0.],[2.3,2.],[0.,2.]]))

    def test_sloped_sheet_crossing_source_and_warp_cells(self):
        self.check_triangle(np.array([[.1,.1,1.],[1.9,.2,2.],[.2,1.9,4.]]),np.array([[0.,0.],[2.,0.],[2.3,2.],[0.,2.]]))

    def test_collapsed_xy_strip_keeps_vertical_height_profile(self):
        self.check_triangle(np.array([[.1,.1,1.],[1.9,.2,2.],[.2,1.9,4.]]),np.array([[0.,0.],[0.,0.],[0.,2.],[0.,2.]]))

    def test_declared_diagonal_rank_one_interpolates_scalar_and_preserves_height(self):
        source=np.array([[212.,194.],[214.,194.],[212.,196.]])
        endpoints=np.array([[212.62,194.501],[222.445,204.602]])
        parameters=np.array([0.,.3,1.])
        target=endpoints[0]+parameters[:,None]*(endpoints[1]-endpoints[0])
        family=dict(sourceVerticesSvg=source,targetVerticesSvg=target,triangles=[[0,1,2]],
            declaredRankOneMappings=[dict(targetEndpointsSvg=endpoints.tolist(),cells=[dict(cell=0,vertexParameters=parameters.tolist())])])
        hull=np.array([[200.,180.],[240.,180.],[240.,220.],[200.,220.]])
        warp=explicit_warp(hull,np.zeros_like(hull),np.array([[0,1,2],[0,2,3]]))
        xyz=np.column_stack((source,[1.,3.,5.]))
        parts=region_fragments(np.column_stack((xyz,np.eye(3))),family,warp)
        for part,_,_ in parts:
            scalar=part[:,3:]@parameters
            expected=endpoints[0]+scalar[:,None]*(endpoints[1]-endpoints[0])
            np.testing.assert_allclose(part[:,:2],expected,atol=1e-12,rtol=0)
            np.testing.assert_allclose(part[:,2],part[:,3:]@xyz[:,2],atol=1e-12,rtol=0)
        family['targetVerticesSvg']=target.copy();family['targetVerticesSvg'][1,0]+=.001
        with self.assertRaisesRegex(ValueError,'differs from stored target'):
            region_fragments(np.column_stack((xyz,np.eye(3))),family,warp)

if __name__=='__main__':unittest.main()
