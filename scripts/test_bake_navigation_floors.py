import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from bake_navigation_floors import bake, clip_halfplane


class NavigationFloorBakeTest(unittest.TestCase):
    def test_halfplane_clipping_preserves_hard_height_edge(self):
        square = [(0, 0), (2, 0), (2, 2), (0, 2)]
        clipped = clip_halfplane(square, np.array([1, 0, 0]), 1)
        self.assertEqual(set(clipped), {(0, 0), (1, 0), (1, 2), (0, 2)})

    def test_actual_stair_treads_stay_flat_and_do_not_join_roofs(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            points, faces, materials = [], [], []
            for x1, x2, height, material in [(0, 1, 0, 0), (1, 2, .2, 0),
                                             (0, 2, 3, 0), (0, 2, .25, 1)]:
                first = len(points)
                points.extend([(x1, 0, height), (x2, 0, height),
                               (x2, 2, height), (x1, 2, height)])
                faces.extend([(first, first+1, first+2), (first, first+2, first+3)])
                materials.extend([material, material])
            np.savez_compressed(folder / 'geometry.npz', points=np.asarray(points),
                                faces=np.asarray(faces), material_indices=np.asarray(materials))
            metadata = {'geometrySha256': hashlib.sha256((folder / 'geometry.npz').read_bytes()).hexdigest(),
                        'materials': [{'category': 'opaque'}, {'category': 'masked'}],
                        'uiTransform': {'XMultiplier': .001, 'XScalarToAdd': .5,
                                        'YMultiplier': -.001, 'YScalarToAdd': .5}}
            (folder / 'geometry.json').write_text(json.dumps(metadata))
            nav = {'map': 'fixture', 'navigationSha256': 'source-nav',
                   'vertices': [0, 0, 10, 200, 0, 10, 200, -200, 10, 0, -200, 10],
                   'triangles': [0, 0, 1, 2, 0, 0, 2, 3]}
            source = folder / 'source.json'
            source.write_text(json.dumps(nav))
            report = bake(folder, source, folder / 'floor.json')
            data = report['floorMesh']
            vertices = np.asarray(data['vertices']).reshape(-1, 3)
            self.assertEqual(set(vertices[:, 2]), {0, 20})
            for parent, a, b, c in np.asarray(data['triangles']).reshape(-1, 4):
                self.assertEqual(parent, 0)
                self.assertEqual(len(set(vertices[[a, b, c], 2])), 1,
                                 'Stair tread must not interpolate between heights')


if __name__ == '__main__':
    unittest.main()
