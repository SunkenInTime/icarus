"""Finite clipping retains source area on shared edges and point images once."""
import unittest
import json
from fractions import Fraction
from pathlib import Path
import numpy as np
from finite_region_cells import partition_mesh
from exact_source_partition import prove_partition


class FiniteCellTests(unittest.TestCase):
    def setUp(self):
        self.points=np.array([[0.,0.],[1.,0.],[1.,1.],[0.,1.]])
        self.cells=np.array([[0,1,2],[0,2,3]])

    def proof(self,parts):
        bary=[]
        for data,cell in parts:
            bary.extend(data[[0,j,j+1],3:6] for j in range(1,len(data)-1))
        result=prove_partition(np.array(bary));self.assertTrue(result['passed'],result);return result

    def test_triangle_crossing_diagonal_is_split_once(self):
        data=np.column_stack(([[.1,.2,0],[.9,.2,0],[.4,.9,0]],np.eye(3)));parts=partition_mesh(data,self.points,self.cells)
        self.assertEqual(len(parts),2);self.proof(parts)

    def test_vertical_face_on_shared_edge_retains_positive_source_area_once(self):
        data=np.column_stack(([[.2,.2,0],[.8,.8,0],[.5,.5,2]],np.eye(3)));parts=partition_mesh(data,self.points,self.cells)
        self.assertEqual(len(parts),1);self.assertEqual(parts[0][1],0);self.proof(parts)

    def test_point_projection_retains_original_source_area_once(self):
        data=np.column_stack(([[.5,.5,0],[.5,.5,1],[.5,.5,2]],np.eye(3)));parts=partition_mesh(data,self.points,self.cells)
        self.assertEqual(len(parts),1);self.proof(parts)

    def test_corner_projection_retains_original_source_area_once(self):
        data=np.column_stack(([[0.,0.,0],[0.,0.,1],[0.,0.,2]],np.eye(3)));parts=partition_mesh(data,self.points,self.cells)
        self.assertEqual(len(parts),1);self.proof(parts)

    def test_vertical_face_crossing_cells_preserves_full_source_partition(self):
        data=np.column_stack(([[.2,.7,0],[.8,.7,0],[.5,.7,2]],np.eye(3)));parts=partition_mesh(data,self.points,self.cells)
        self.assertEqual(len(parts),2);self.proof(parts)

    def test_shared_edge_chain_and_reversed_cell_order_keep_area_and_mapping(self):
        points=np.array([[x,y] for y in [0.,1.,2.] for x in [0.,.5,1.]])
        cells=[]
        for row in range(2):
            for column in range(2):
                a=row*3+column;cells.extend([[a,a+1,a+4],[a,a+4,a+3]])
        cells=np.array(cells);data=np.column_stack(([[.5,.2,0],[.5,1.8,0],[.5,1.3,2]],np.eye(3)));target=points*np.array([2.,.5])+[3.,-4.]
        for arranged in [cells,cells[::-1,::-1]]:
            parts=partition_mesh(data,points,arranged,return_weights=True);self.proof([(p,c) for p,c,w in parts])
            for part,cell,weights in parts:
                expected=(part[:,3:6]@data[:,:2])*[2.,.5]+[3.,-4.]
                np.testing.assert_allclose(weights@target[arranged[cell]],expected,rtol=0,atol=1e-12)

    def test_line_contact_is_retained_as_explicit_degenerate_triangle(self):
        data=np.column_stack(([[1.,.2,0],[2.,.2,0],[1.,.8,2]],np.eye(3)));parts=partition_mesh(data,self.points,self.cells)
        self.assertTrue(parts)
        bary=np.concatenate([p[:,3:6] for p,c in parts]);self.assertTrue(np.any(np.all(bary==[1.,0.,0.],axis=1)));self.assertTrue(np.any(np.all(bary==[0.,0.,1.],axis=1)))
        for part,cell in parts:self.assertGreaterEqual(len(part),3)

    def test_point_contact_is_retained_once_with_repeated_endpoint(self):
        data=np.column_stack(([[1.,1.,0],[2.,1.,0],[1.,2.,2]],np.eye(3)));parts=partition_mesh(data,self.points,self.cells)
        self.assertEqual(len(parts),1);np.testing.assert_array_equal(parts[0][0][:,3:6],np.tile([1.,0.,0.],(3,1)))

    def test_precise_thin_cell_retains_exact_boundary_weights(self):
        fixture=json.loads(Path(__file__).with_name('fixtures').joinpath('finite-thin-cell-1260.json').read_text())
        data=np.array(fixture['data']);points=np.array(fixture['sourceCell']);cells=np.array([[0,1,2]])
        construction=[[Fraction(value) for value in row] for row in fixture['sourceConstruction']]
        # The old rounded-coordinate inverse reports a negative weight even
        # though exact clipping places these vertices on the finite cell.
        with self.assertRaisesRegex(ValueError,'no containing cell'):
            partition_mesh(data,points,cells)
        result=partition_mesh(data,points,cells,source_construction=construction,return_weights=True,return_exact=True)
        self.assertEqual(len(result),1)
        part,cell,weights,exact_part,exact_weights=result[0]
        np.testing.assert_array_equal(weights,np.array([[float(v) for v in row] for row in exact_weights]))
        self.assertGreaterEqual(weights.min(),0)
        self.assertEqual(int((weights==0).sum()),4)
        np.testing.assert_allclose(weights@points,part[:,:2],atol=1e-13,rtol=0)

    def test_precise_rows_do_not_admit_a_disjoint_triangle(self):
        data=np.column_stack(([[2.,2.,0],[3.,2.,0],[2.,3.,0]],np.eye(3)))
        exact=[[Fraction(float(value)) for value in row] for row in data]
        with self.assertRaisesRegex(ValueError,'outside its declared region'):
            partition_mesh(data,self.points,self.cells,exact_rows=exact,return_weights=True)

if __name__=='__main__':unittest.main()
