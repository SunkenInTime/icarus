import unittest
import numpy as np
import sys
from fractions import Fraction
from exact_source_partition import prove_partition,encoded,decimal_integer


def bary(xy):
    p=np.array(xy,dtype=float);return np.concatenate((1-p.sum(2,keepdims=True),p),axis=2)


class PartitionTests(unittest.TestCase):
    def test_large_exact_integer_proof_serializes_without_global_limit_change(self):
        limit=sys.get_int_max_str_digits()
        value=Fraction(10**5000+1,10**5000-1)
        row=encoded(value)
        def decode(text):
            result=0
            for start in range(0,len(text),9):
                chunk=text[start:start+9]
                result=result*10**len(chunk)+int(chunk)
            return result
        self.assertEqual(decode(row['numerator']),value.numerator)
        self.assertEqual(decode(row['denominator']),value.denominator)
        self.assertEqual(decimal_integer(-value.numerator),'-'+row['numerator'])
        self.assertEqual(sys.get_int_max_str_digits(),limit)

    def setUp(self):
        self.p=bary([[[0,0],[.5,0],[0,.5]],[[.5,0],[1,0],[.5,.5]],[[0,.5],[.5,.5],[0,1]],[[.5,0],[.5,.5],[0,.5]]])
    def test_exact_partition(self):
        r=prove_partition(self.p);self.assertTrue(r['passed']);self.assertEqual(r['missingAreaUpperBound']['numerator'],'0');self.assertEqual(r['pairwiseOverlapUpperBound']['numerator'],'0')
    def test_finite_hole(self):self.assertFalse(prove_partition(self.p[:-1])['passed'])
    def test_finite_overlap(self):self.assertFalse(prove_partition(np.concatenate((self.p,self.p[-1:])))['passed'])
    def test_outside_source(self):
        p=self.p.copy();p[0,0]=[1.001,-.001,0];self.assertFalse(prove_partition(p)['passed'])
    def test_tiny_residue_is_reported(self):
        p=self.p.copy();p[0,1,1]=np.nextafter(.5,0);p[0,1,0]=1-p[0,1,1]
        r=prove_partition(p);self.assertTrue(r['passed']);self.assertNotEqual(r['missingAreaUpperBound']['numerator'],'0')
    def test_zero_area_contacts_are_order_invariant(self):
        contacts=bary([[[.1,.1],[.1,.1],[.1,.1]],[[.1,.1],[.2,.2],[.3,.3]]])
        for p in [np.concatenate((contacts,self.p)),np.concatenate((self.p,contacts))]:
            r=prove_partition(p);self.assertTrue(r['passed'])
            self.assertEqual(r['pairwiseOverlapUpperBound']['numerator'],'0')

    def test_spatial_index_preserves_exact_overlap_and_hole_proof(self):
        pieces=[]
        for i in range(80):
            pieces.append([[0.,0.],[(i+1)/80,1-(i+1)/80],[i/80,1-i/80]])
        triangles=bary(pieces)
        for value in [triangles,np.concatenate((triangles,triangles[30:31])),triangles[1:]]:
            self.assertEqual(prove_partition(value),prove_partition(value,spatial_index=False))

    def test_spatial_index_outward_rounding_keeps_subfloat_overlap(self):
        from exact_source_partition import candidate_pairs
        center=Fraction(1,2);epsilon=Fraction(1,10**100)
        boxes=[(Fraction(i+2),Fraction(0),Fraction(i+3),Fraction(1)) for i in range(64)]
        boxes.extend([(center-epsilon,Fraction(0),center+epsilon,Fraction(1)),(center,Fraction(0),center+2*epsilon,Fraction(1))])
        self.assertIn((65,64),set(candidate_pairs(boxes)))


if __name__=='__main__':unittest.main()
