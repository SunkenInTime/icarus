import base64
import json
import tempfile
import unittest
from pathlib import Path

from bake_navigation import bake


def tile(x, points, neighbors, *, area=63):
    vertices = [{'X': p[0], 'Y': p[2], 'Z': p[1]} for p in points]
    return {'Header': {'X': x, 'Y': 0, 'Layer': 0}, 'Vertices': vertices,
            'Polys': [{'Verts': [0, 1, 2, 3, 0, 0], 'VertCount': 4,
                       'Neis': neighbors + [0, 0], 'AreaAndType': area}],
            'DetailMeshes': [{'VertBase': 0, 'TriBase': 0, 'VertCount': 0, 'TriCount': 2}],
            'DetailVertices': [],
            'DetailTris': [base64.b64encode(bytes(t)).decode()
                           for t in [(0, 1, 2, 0), (0, 2, 3, 0)]]}


class NavigationBakeTest(unittest.TestCase):
    def run_bake(self, tiles):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / 'nav.json'
            p.write_text(json.dumps({'meshes': [{
                'navigationDataName': 'RecastNavMesh-BasePawn', 'version': 26,
                'parameters': {'WalkableHeight': 196, 'WalkableRadius': 42,
                               'WalkableClimb': 35}, 'tiles': tiles}]}))
            return bake([p], {'XMultiplier': .001, 'YMultiplier': -.001,
                              'XScalarToAdd': .5, 'YScalarToAdd': .5}, 'fixture')

    def pair(self, height=0):
        return [tile(0, [(0, 0, 0), (100, 0, 0), (100, 100, 0), (0, 100, 0)],
                     [0, 0x8000, 0, 0]),
                tile(1, [(100, 0, height), (200, 0, height),
                         (200, 100, height), (100, 100, height)],
                     [0, 0, 0, 0x8004])]

    def test_matching_native_portals_preserve_step_connectivity(self):
        data = self.run_bake(self.pair(35))
        self.assertEqual(len(data['links']) // 6, 2)
        self.assertEqual(data['components'], [0, 0])
        self.assertEqual(data['source']['agentRadiusCm'], 42)

    def test_stacked_floors_above_native_climb_stay_disconnected(self):
        data = self.run_bake(self.pair(36))
        self.assertEqual(data['links'], [])
        self.assertEqual(data['components'], [0, 1])

    def test_touching_polygons_without_native_portals_do_not_connect(self):
        tiles = self.pair()
        tiles[0]['Polys'][0]['Neis'] = [0] * 6
        data = self.run_bake(tiles)
        self.assertEqual(data['links'], [])

    def test_offmesh_links_and_crouch_polygons_are_not_walking(self):
        tiles = self.pair()
        tiles[1]['Polys'][0]['AreaAndType'] = 127
        data = self.run_bake(tiles)
        self.assertEqual(len(data['polygons']), 1)
        self.assertEqual(data['source']['excludedOffMeshLinks'], 1)
        tiles[1]['Polys'][0]['AreaAndType'] = 2
        data = self.run_bake(tiles)
        self.assertEqual(data['walkable'], [True, False])
        self.assertEqual(data['links'], [])

    def test_recast_coordinates_convert_without_fmodel_mirror(self):
        data = self.run_bake(self.pair())
        self.assertEqual(data['_worldVerticesCm'][3:6], [-100, 0, 0])
        self.assertEqual(data['vertices'][3:6], [500000, 600000, 0])

    def test_conflicting_duplicate_tiles_fail(self):
        tiles = self.pair()
        other = json.loads(json.dumps(tiles[0]))
        other['Vertices'][0]['Y'] = 100
        with self.assertRaisesRegex(ValueError, 'Conflicting tiles'):
            self.run_bake([tiles[0], other])


if __name__ == '__main__':
    unittest.main()
