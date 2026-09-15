"""Independent rejection controls for source coordinate certificates."""
import copy
import math
import json
from pathlib import Path
from fractions import Fraction
import unittest
import numpy as np
from precise_region_containment import certify_vertex_weights
from verify_source_cell_coordinate_certificate import POLICY, certify_coordinate_error, sqrt_upper


def fixture(offset=None):
    x=100.+1e-6
    source=[[100.,200.],[x,200.],[102.,200.],[100.,202.],[x,202.],[102.,202.]]
    family=dict(sourceVerticesSvg=source,targetVerticesSvg=copy.deepcopy(source),
        triangles=[[0,1,4],[0,4,3],[1,2,5],[1,5,4]],sourceContainmentArithmeticPolicy=POLICY.copy())
    native=np.array([[x-1e-7,200.5,0],[x+(math.ulp(x) if offset is None else offset),200.6,1],[x-1e-7,200.7,0.]])
    return family,native


class IndependentCoordinateCertificateTests(unittest.TestCase):
    def test_positive_rational_underflow_has_prompt_upper_bound(self):
        value=Fraction(1,10**400)
        result=sqrt_upper(value)
        self.assertGreater(result,0)
        self.assertGreaterEqual(Fraction.from_float(result)**2,value)

    def test_captured_barrier_residue(self):
        row=json.loads((Path(__file__).with_name('fixtures')/'source-cell-coordinate-certificate.json').read_text())
        weights,proof=certify_coordinate_error(**row)
        self.assertLess(np.min(weights),-1e-8)
        self.assertAlmostEqual(proof['maximumMappedExtensionErrorSvg'],7.618468016389552e-14,delta=1e-25)

    def verify(self,family,native):
        return certify_coordinate_error(family,native,np.eye(3),np.eye(2),np.zeros(2),0)

    def test_storage_residue_has_bounded_extension_without_clamping(self):
        family,native=fixture()
        weights,proof=self.verify(family,native)
        self.assertLess(np.min(weights),-1e-8)
        self.assertGreater(proof['maximumMappedExtensionErrorSvg'],0)
        self.assertLess(proof['maximumMappedExtensionErrorSvg'],1e-12)
        points=native[None,:,:2]
        cells=np.asarray(family['sourceVerticesSvg'])[np.asarray(family['triangles'])[[0]]]
        construction=dict(originalNativeTriangles=native[None],sourceBarycentrics=np.eye(3)[None],
            projectionMatrix=np.eye(2),projectionOrigin=np.zeros(2),sourceParents=[7],regionCells=[0],inputHashes={},family=family)
        actual,report=certify_vertex_weights(points,cells,construction)
        np.testing.assert_array_equal(actual[0],weights)
        self.assertEqual(report['coordinateCertifiedFragments'],1)
        del construction['family']
        with self.assertRaisesRegex(AssertionError,'Exact source construction crosses'):
            certify_vertex_weights(points,cells,construction)

    def test_real_crossing_rejected(self):
        with self.assertRaisesRegex(AssertionError,'storage interval'):
            self.verify(*fixture(1e-9))

    def test_missing_policy_rejected(self):
        family,native=fixture();del family['sourceContainmentArithmeticPolicy']
        with self.assertRaisesRegex(AssertionError,'policy'):self.verify(family,native)

    def test_rank_one_override_rejected(self):
        family,native=fixture();family['declaredRankOneMappings']=[{}]
        with self.assertRaisesRegex(AssertionError,'rank-one'):self.verify(family,native)

    def test_domain_hole_rejected(self):
        family,native=fixture();family['triangles'].pop()
        with self.assertRaisesRegex(AssertionError,'internal|rectangle'):self.verify(family,native)

    def test_amplified_residue_rejected(self):
        family,native=fixture();family['targetVerticesSvg'][1][0]+=1e12
        with self.assertRaisesRegex(AssertionError,'authored-position budget'):self.verify(family,native)


if __name__=='__main__':unittest.main()
