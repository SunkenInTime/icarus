import unittest
import numpy as np
from verify_region_mapping import declared_mapping, verify_rank_one_declarations


class RankOneRegionTest(unittest.TestCase):
    def fixture(self):
        source = np.array([[212.82763663324, 194.86926596339],
                           [212.82730106784, 194.86926596339],
                           [212.82731162437, 195.19783518323]])
        origin = np.array([212.82730106784453, 194.8692659633886])
        tangent = np.array([.5992987252789285, .8005254760962023])
        length = 13.046919003946789
        parameters = (source-origin) @ tangent / length
        parameters[abs(parameters * length) < 1e-10] = 0
        endpoints = np.array([[212.62, 194.501], [222.445, 204.602]])
        target = endpoints[0] + parameters[:, None] * (endpoints[1] - endpoints[0])
        return dict(sourceVerticesSvg=np.vstack((source, origin, origin+tangent*length)).tolist(),
                    targetVerticesSvg=np.vstack((target, endpoints)).tolist(), triangles=[[0, 1, 2]],
                    declaredRankOneMappings=[dict(targetEndpointVertexIds=[3, 4],
                        targetEndpointsSvg=endpoints.tolist(), sourceOriginSvg=origin.tolist(),
                        sourceTangent=tangent.tolist(), sourceLengthSvg=length,
                        sourceEndpointArithmeticSvg=1e-10,
                        cells=[dict(cell=0, vertexParameters=parameters.tolist())])])

    def test_roundoff_on_declared_line_retains_rank_one_mapping(self):
        family = self.fixture()
        self.assertEqual(len(verify_rank_one_declarations(family)), 1)
        points = np.array(family['sourceVerticesSvg'][:3])[None]
        mapped, _ = declared_mapping(family, points, np.array([0]))
        np.testing.assert_allclose(mapped[0], family['targetVerticesSvg'][:3], atol=3e-14, rtol=0)

    def test_declaration_cannot_hide_real_off_line_target(self):
        family = self.fixture()
        family['targetVerticesSvg'][0][0] += 1e-7
        with self.assertRaisesRegex(AssertionError, 'deviates'):
            verify_rank_one_declarations(family)

    def test_parameter_must_come_from_source(self):
        family = self.fixture()
        family['declaredRankOneMappings'][0]['cells'][0]['vertexParameters'][0] += .001
        with self.assertRaisesRegex(AssertionError, 'parameter'):
            verify_rank_one_declarations(family)


if __name__ == '__main__':
    unittest.main()
