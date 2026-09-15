import unittest
from fractions import Fraction
import numpy as np
from exact_receiver_contact import classify
from finite_receiver_shadows import Receiver


class ExactContactTests(unittest.TestCase):
    def setUp(self):
        self.receiver=Receiver(np.array([[0.,-2.],[10.,-2.],[10.,2.],[0.,2.]]),np.array([0.,0.,0.]))

    def test_tall_wall_has_positive_shadow_and_behind_receiver_has_none(self):
        triangle=np.array([[5.,-2.,0.],[5.,2.,0.],[5.,0.,5.]])
        self.assertEqual(classify([1,0,1.75],triangle,self.receiver)['kind'],'exact-positive-area-shadow')
        triangle[:,0]=20
        self.assertEqual(classify([1,0,1.75],triangle,self.receiver)['kind'],'exact-empty-shadow')

    def test_coplanar_receiver_policy_is_not_silently_resolved(self):
        triangle=np.array([[4.,-1.,1.75],[6.,-1.,1.75],[5.,1.,1.75]])
        self.assertIn('needs-2d',classify([1,0,1.75],triangle,self.receiver)['kind'])
        shifted=Receiver(self.receiver.footprint,np.array([0.,0.,1.]))
        result=classify([1,0,1.75],triangle,shifted)
        self.assertEqual(result['filledShadowDimensionUpperBound'],1)

    def test_exact_degenerate_source_and_tiny_valid_source_are_distinct(self):
        triangle=np.array([[5.,0.,0.],[5.,0.,1.],[5.,0.,2.]])
        self.assertEqual(classify([1,0,1.75],triangle,self.receiver)['kind'],'source-segment-distinct-receiver-plane')
        triangle[1,1]=1e-20
        self.assertEqual(classify([1,0,1.75],triangle,self.receiver)['kind'],'exact-positive-area-shadow')

    def test_exact_area_has_square_meter_units(self):
        result=classify([1,0,1.75],[[5,-2,0],[5,2,0],[5,0,5]],self.receiver)
        exact=Fraction(int(result['exactAreaNumerator']),int(result['exactAreaDenominator']))
        self.assertEqual(float(exact),result['areaSquareMeters'])

    def test_coplanar_segment_can_cast_filled_contact_wedge(self):
        result=classify([1,0,1.75],[[5,-1,1.75],[5,0,1.75],[5,1,1.75]],self.receiver)
        self.assertIn('needs-2d',result['kind'])
        self.assertEqual(result['filledShadowDimensionUpperBound'],2)

    def test_origin_contacts_are_explicit_and_collinear_distant_segment_is_bounded(self):
        eye=[1,0,1.75]
        for triangle in [[eye,eye,eye],[[0,0,1.75],eye,[2,0,1.75]]]:
            self.assertIn('needs-origin',classify(eye,triangle,self.receiver)['kind'])
        self.assertEqual(classify(eye,[[5,0,1.75],[6,0,1.75],[7,0,1.75]],self.receiver)['filledShadowDimensionUpperBound'],1)
        self.assertEqual(classify(eye,[[5,0,1.75]]*3,self.receiver)['filledShadowDimensionUpperBound'],1)


if __name__=='__main__':unittest.main()
