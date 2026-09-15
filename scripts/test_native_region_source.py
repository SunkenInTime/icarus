"""Exact coordinate construction must not grant a source-cell extension policy."""
from fractions import Fraction
import unittest
import numpy as np

from authored_region_cells import barycentric
from exact_source_partition import prove_partition
from finite_region_cells import exact_initial_data,partition_mesh,region_fragments
from native_region_source import native_source_rows
from region_partition_certificate import SourceCellCertificate
from tactical_alignment_composite import explicit_warp


class NativeConstructionTests(unittest.TestCase):
    def setUp(self):
        self.points=np.array([[0.,0.],[1.,0.],[1.,1.],[0.,1.]])
        self.cells=np.array([[0,1,2],[0,2,3]])

    def test_native_projection_is_exact_before_storage(self):
        xyz=np.array([[.1,.2,5.],[.7,.2,5.],[.4,.8,5.]])
        matrix=np.array([[3.7,.2],[-.1,4.1]]);origin=np.array([1e8,-1e8])
        rows=native_source_rows(xyz,matrix,origin)
        self.assertNotEqual(rows[0][0],Fraction(float((xyz[:,:2]@matrix.T+origin)[0,0])))
        data=np.column_stack((xyz[:,:2]@matrix.T+origin,xyz[:,2],np.eye(3)))
        generated=exact_initial_data(data,source_construction=rows)
        self.assertEqual(generated,rows)
        self.assertTrue(all(row[2]==5 for row in generated))

    def test_explicit_construction_matches_legacy_barrier_input(self):
        family=dict(edge=1,sourceVerticesSvg=self.points.tolist(),targetVerticesSvg=self.points.tolist(),triangles=self.cells.tolist(),
            sourceContainmentArithmeticPolicy=dict(format='icarus-source-cell-coordinate-certificate-v1',coordinateStorageUlps=1,maximumMappedExtensionErrorSvg=1e-7))
        xyz=np.array([[.1,.2,0.],[.9,.2,0.],[.4,.9,2.]])
        callback=SourceCellCertificate(family).callback(xyz,np.eye(2),np.zeros(2),17)
        rows=native_source_rows(xyz,np.eye(2),np.zeros(2));self.assertEqual(rows,callback.exact_source_data)
        data=np.column_stack((xyz,np.eye(3)))
        old=partition_mesh(data,self.points,self.cells,containment_certificate=callback,return_weights=True)
        new=partition_mesh(data,self.points,self.cells,source_construction=rows,return_weights=True)
        self.assertEqual(len(old),len(new))
        for a,b in zip(old,new):
            self.assertEqual(a[1],b[1]);np.testing.assert_array_equal(a[0],b[0]);np.testing.assert_array_equal(a[2],b[2])

    def test_construction_does_not_admit_outside_source(self):
        xyz=np.array([[2.,2.,0.],[3.,2.,0.],[2.,3.,1.]])
        rows=native_source_rows(xyz,np.eye(2),np.zeros(2))
        misleading=np.column_stack((xyz-[2,2,0],np.eye(3)))
        with self.assertRaisesRegex(ValueError,'outside'):
            partition_mesh(misleading,self.points,self.cells,source_construction=rows)

    def test_rank_one_exact_w_partition_preserves_source_area_and_line(self):
        native=np.array([[.1,.2,2.],[.9,.2,2.],[.4,.9,4.]])
        data=np.column_stack((native,np.eye(3)))
        target=np.array([[500.,800.],[501.,801.],[501.,801.],[500.,800.]])
        family=dict(sourceVerticesSvg=self.points.tolist(),targetVerticesSvg=target.tolist(),triangles=self.cells.tolist(),
            declaredRankOneMappings=[dict(targetEndpointsSvg=[[500.,800.],[501.,801.]],
                cells=[dict(cell=i,vertexParameters=self.points[cell,0].tolist()) for i,cell in enumerate(self.cells)])])
        wp=np.array([[499.,799.],[502.,799.],[502.,802.],[499.,802.]])
        warp=explicit_warp(wp,np.zeros_like(wp),self.cells)
        parts=region_fragments(data,family,warp,source_construction=native_source_rows(native,np.eye(2),np.zeros(2)))
        bary=[]
        for part,wcell,rcell in parts:
            original=part[:,3:6]@native
            np.testing.assert_allclose(part[:,0]-500,original[:,0],rtol=0,atol=1e-13)
            np.testing.assert_allclose(part[:,1]-800,original[:,0],rtol=0,atol=1e-13)
            np.testing.assert_allclose(part[:,2],original[:,2],rtol=0,atol=1e-13)
            self.assertGreaterEqual(barycentric(part[:,:2],wp[self.cells[wcell]]).min(),-1e-8)
            bary.extend(part[[0,j,j+1],3:6] for j in range(1,len(part)-1))
        self.assertTrue(prove_partition(np.array(bary))['passed'])

    def test_conflicting_provenance_rejected(self):
        native=np.array([[.1,.2,0.],[.9,.2,0.],[.4,.9,2.]])
        rows=native_source_rows(native,np.eye(2),np.zeros(2));data=np.column_stack((native,np.eye(3)))
        class Callback:pass
        callback=Callback();callback.exact_source_data=native_source_rows(native,np.eye(2),np.ones(2))
        with self.assertRaisesRegex(ValueError,'Conflicting'):
            exact_initial_data(data,callback,source_construction=rows)


if __name__=='__main__':unittest.main()
