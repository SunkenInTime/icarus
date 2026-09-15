"""Opt-in certificates distinguish storage-scale residues from real crossings."""
import copy,math,unittest
from fractions import Fraction
import numpy as np
from authored_region_cells import partition_mesh
from region_partition_certificate import SourceCellCertificate,upward_sqrt


def fixture():
    x=100.+1e-6
    source=[[100.,200.],[x,200.],[102.,200.],[100.,202.],[x,202.],[102.,202.]]
    return dict(edge=1,sourceVerticesSvg=source,targetVerticesSvg=source,triangles=[[0,1,4],[0,4,3],[1,2,5],[1,5,4]],sourceContainmentArithmeticPolicy=dict(format='icarus-source-cell-coordinate-certificate-v1',coordinateStorageUlps=1,maximumMappedExtensionErrorSvg=1e-7))


class CoordinateCertificateTests(unittest.TestCase):
    def call(self,offset):
        family=fixture();x=family['sourceVerticesSvg'][1][0];native=np.array([[x-1e-7,200.5,0],[x+offset,200.6,1],[x-1e-7,200.7,0.]])
        cert=SourceCellCertificate(family);part=np.column_stack((native,np.eye(3)));cell,weights=cert.callback(native,np.eye(2),np.zeros(2),7)(part,np.array(family['sourceVerticesSvg']),np.array(family['triangles']),np.array([True,False,False,False]));return cert,cell,weights

    def test_one_coordinate_storage_interval_is_explicitly_certified(self):
        cert,cell,weights=self.call(math.ulp(100.))
        self.assertEqual(cell,0);self.assertLess(weights.min(),-1e-8)
        self.assertEqual(len(cert.records),1);self.assertGreater(cert.records[0]['vertices'][1]['outsideDistanceUpperBoundSvg'],0)
        self.assertLess(cert.records[0]['vertices'][1]['mappedExtensionDifferenceUpperBoundSvg'],1e-12)

    def test_larger_physical_escape_is_rejected(self):
        with self.assertRaisesRegex(AssertionError,'storage interval'):self.call(1e-9)

    def test_rank_one_override_is_not_silently_treated_as_stored_affine_map(self):
        family=fixture();family['declaredRankOneMappings']=[{}]
        with self.assertRaisesRegex(AssertionError,'rank-one'):SourceCellCertificate(family)

    def test_hole_in_domain_is_rejected(self):
        family=fixture();family['triangles']=family['triangles'][:-1]
        with self.assertRaisesRegex(AssertionError,'interior|rectangle'):SourceCellCertificate(family)

    def test_positive_underflow_has_a_finite_conservative_square_root(self):
        value=Fraction(1,10**1000);bound=upward_sqrt(value)
        self.assertGreater(bound,0);self.assertTrue(math.isfinite(bound));self.assertGreaterEqual(Fraction(bound)**2,value)

    def test_default_partition_still_rejects_outside_source_region(self):
        family=fixture();data=np.array([[103.,201.,0,1,0,0],[103.1,201.,0,0,1,0],[103.,201.1,0,0,0,1]])
        with self.assertRaisesRegex(ValueError,'containing cell'):partition_mesh(data,np.array(family['sourceVerticesSvg']),np.array(family['triangles']))

if __name__=='__main__':unittest.main()
