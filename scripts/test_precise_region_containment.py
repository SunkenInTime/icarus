import copy
import json
from pathlib import Path
import unittest

import numpy as np
from precise_region_containment import certify_vertex_weights, exact_weights, certify_storage_extension, fraction
from verify_region_mapping import declared_mapping


class PreciseRegionContainmentTest(unittest.TestCase):
    def fixtures(self):
        return json.loads((Path(__file__).with_name('fixtures') / 'precise-region-containment.json').read_text())

    def inputs(self, row):
        original = np.asarray([row['originalNativeTriangle']])
        bary = np.asarray([row['sourceBarycentrics']])
        matrix = np.asarray(row['projectionMatrix'])
        origin = np.asarray(row['projectionOrigin'])
        points = (original[:, :1] + np.einsum('nij,njk->nik', bary[:, :, 1:], original[:, 1:] - original[:, :1]))[:, :, :2] @ matrix.T + origin
        construction = dict(originalNativeTriangles=original, sourceBarycentrics=bary,
                            projectionMatrix=matrix, projectionOrigin=origin,
                            sourceParents=[row['sourceParent']], regionCells=[row['regionCell']],
                            inputHashes=row['inputHashes'])
        return points, np.asarray([row['sourceCell']]), construction

    def test_v5_roundoff_passes_from_exact_original_construction(self):
        row = self.fixtures()[1]
        points, cells, construction = self.inputs(row)
        weights, report = certify_vertex_weights(points, cells, construction)
        self.assertLess(report['doubleMinimum'], -1e-8)
        self.assertEqual(len(report['exactFallbacks']), 1)
        record = report['exactFallbacks'][0]
        self.assertAlmostEqual(record['exactMinimum']['decimal'], -4.581924869782371e-9, delta=1e-20)
        self.assertEqual(record['provenanceHashes'], row['inputHashes'])
        # Dense affine interpolation uses certified weights, so it cannot add
        # a new outside sample through absolute-coordinate cancellation.
        probes = np.array([[i, j, 100-i-j] for i in range(101) for j in range(101-i)]) / 100
        self.assertGreaterEqual(np.einsum('ij,njk->nik', probes, weights).min(), -1e-8)

    def test_v4_true_outside_stays_rejected(self):
        points, cells, construction = self.inputs(self.fixtures()[0])
        with self.assertRaisesRegex(AssertionError, 'Exact source construction crosses'):
            certify_vertex_weights(points, cells, construction)

    def test_fallback_requires_matching_source_provenance(self):
        points, cells, construction = self.inputs(self.fixtures()[1])
        with self.assertRaisesRegex(AssertionError, 'source cell'):
            certify_vertex_weights(points, cells)
        altered = copy.deepcopy(construction)
        altered['projectionOrigin'][0] += .01
        with self.assertRaisesRegex(AssertionError, 'does not reproduce'):
            certify_vertex_weights(points, cells, altered)

    def test_interior_stays_on_double_path(self):
        cells = np.array([[[0., 0.], [1., 0.], [0., 1.]]])
        points = np.array([[[.1, .1], [.2, .1], [.1, .2]]])
        weights, report = certify_vertex_weights(points, cells)
        self.assertEqual(report['exactFallbacks'], [])
        np.testing.assert_allclose(weights.sum(2), 1)

    def storage_fixture(self):
        return json.loads((Path(__file__).with_name('fixtures')/'asite-cell803-storage.json').read_text())

    def test_captured_asite_discarded_cell_uses_coordinate_storage(self):
        row=self.storage_fixture();points,cells,construction=self.inputs(row)
        original_points=points.copy();original_bary=construction['sourceBarycentrics'].copy()
        records=[]
        mapped,minimum=declared_mapping(row['family'],points,np.array([0]),construction,records)
        self.assertLess(minimum,-1e-8)
        proof=records[0]['exactFallbacks'][0]['coordinateErrorCertificate']
        self.assertEqual(proof['policy'],'source-and-mapped-one-binary64-XY-storage-interval')
        self.assertAlmostEqual(proof['maximumMappedExtensionErrorSvg'],4.1264109810172815e-16,delta=1e-27)
        np.testing.assert_array_equal(mapped[:,:,1],95.618)
        np.testing.assert_array_equal(points,original_points)
        np.testing.assert_array_equal(construction['sourceBarycentrics'],original_bary)

    def test_real_escape_from_thin_cell_is_rejected(self):
        row=self.storage_fixture()
        # Crossing the diagonal by0.1% of the thin cell remains many storage
        # intervals outside, despite being a small visual coordinate distance.
        with self.assertRaisesRegex(AssertionError,'Source-cell escape exceeds coordinate storage'):
            certify_storage_extension(row['family'],0,[[fraction(.5),fraction(.501),fraction(-.001)]])

    def test_storage_escape_with_large_mapping_extension_is_rejected(self):
        row=self.storage_fixture();family=copy.deepcopy(row['family'])
        weights=exact_weights(row['originalNativeTriangle'],row['sourceBarycentrics'],row['projectionMatrix'],row['projectionOrigin'],row['sourceCell'])
        # Source distance still passes. A large gradient in the discarded
        # weight direction must fail the independent mapped-coordinate bound.
        family.pop('declaredRankOneMappings')
        family['targetVerticesSvg'][2][0]+=1e8
        with self.assertRaisesRegex(AssertionError,'Mapped cell extension exceeds coordinate storage'):
            certify_storage_extension(family,0,weights)

    def test_discarded_region_uses_same_provenance_gate(self):
        row=self.fixtures()[2]
        points,cells,construction=self.inputs(row)
        family=dict(sourceVerticesSvg=cells[0].tolist(),targetVerticesSvg=[[0.,0.],[0.,1.],[0.,2.]],triangles=[[0,1,2]])
        records=[]
        mapped,minimum=declared_mapping(family,points,np.array([0]),construction,records)
        self.assertTrue(np.all(mapped[:,:,0]==0))
        self.assertGreaterEqual(minimum,-1e-8)
        self.assertAlmostEqual(records[0]['exactFallbacks'][0]['exactMinimum']['decimal'],-4.7146411428009025e-9,delta=1e-20)
        bad_points,bad_cells,bad_construction=self.inputs(self.fixtures()[0])
        family['sourceVerticesSvg']=bad_cells[0].tolist()
        with self.assertRaisesRegex(AssertionError,'Exact source construction crosses'):
            declared_mapping(family,bad_points,np.array([0]),bad_construction)


if __name__ == '__main__':
    unittest.main()
