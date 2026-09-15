import unittest
from complete_world_floor_alternatives import NativeFallbackReference, complete_reference


class NativeFallbackReferenceTests(unittest.TestCase):
    def fixture(self):
        return {'map': 'bind', 'coordinateScale': 1,
                'vertices': [0, 0, 10, 2, 0, 20, 0, 2, 30, 0, 0, 300, 2, 0, 300, 0, 2, 300],
                'polygons': [[0, 1, 2], [3, 4, 5]], 'triangles': [0, 0, 1, 2, 1, 3, 4, 5],
                'refinedFloorHeightsCm': [0, 10, 20, 290, 290, 290], 'walkable': [True, True],
                'floorMesh': {'coordinateScale': 1, 'vertices': [0, 0, 285, 2, 0, 285, 0, 2, 285],
                              'triangles': [1, 0, 1, 2]}}

    def test_interpolates_refined_fallback_only_where_detail_is_missing(self):
        source = NativeFallbackReference(self.fixture())
        result = source.fallback_at([.5, .5])
        self.assertEqual(list(result), [0])
        self.assertEqual(result[0]['floorHeightCm'], 7.5)
        self.assertEqual(result[0]['nativeBarycentric'], [.5, .25, .25])
        self.assertEqual(source.fallback_at([1.5, 1.5]), {})

    def test_nonwalkable_parent_is_not_an_alternative(self):
        fixture = self.fixture()
        fixture['walkable'][0] = False
        self.assertEqual(NativeFallbackReference(fixture).fallback_at([.5, .5]), {})

    def test_completion_preserves_original_origins_rays_and_statistics(self):
        original = {'origins': [{'id': 3, 'positionMeters': [7, 8, 2.85],
                                'floorAlternatives': [{'parentNavPolygon': 1, 'floorHeightCm': 285}]}],
                    'rays': [{'sample': 3, 'startUv': [.5, .5], 'distance': 4.25}], 'summary': {'errors': 2}}
        result, additions = complete_reference(original, self.fixture())
        self.assertEqual(result['rays'], original['rays'])
        self.assertEqual(result['summary'], original['summary'])
        self.assertEqual(len(original['origins'][0]['floorAlternatives']), 1)
        self.assertEqual(len(result['origins'][0]['floorAlternatives']), 2)
        self.assertEqual(additions[0]['origin'], 3)


if __name__ == '__main__':
    unittest.main()
