"""Frozen source-frontage regression for the independent upper balcony wall."""
import unittest
import numpy as np
import shapely
from declare_split_connected_mid_region import declaration
from authored_region_cells import barycentric


class ConnectedMidDeclarationTests(unittest.TestCase):
    def test_entire_reviewed_167_front_keeps_its_authored_y(self):
        family=declaration();source=np.array(family['sourceVerticesSvg']);target=np.array(family['targetVerticesSvg']);cells=np.array(family['triangles'])
        tree=shapely.STRtree(shapely.polygons(source[cells]))
        # Exact reviewed6947/6966 front envelopes, including the rightmost
        # source section that the unrelated notch blend previously shifted.
        queries=np.array([[x,y] for x in np.linspace(188.57745491366785,205.00804560165957,101)
            for y in [132.3141782526651,132.3367431615614,132.3593080704577]])
        mapped=[]
        for point in queries:
            candidates=tree.query(shapely.Point(point),predicate='intersects');self.assertGreater(len(candidates),0)
            cell=cells[candidates[0]];mapped.append((barycentric(point[None],source[cell])@target[cell])[0])
        mapped=np.array(mapped)
        np.testing.assert_allclose(mapped[:,1],131.769,rtol=0,atol=1e-10)
        self.assertGreater(np.sum(queries[:,0]>201.3463783281243),0)
        self.assertAlmostEqual(mapped[:,0].min(),188.697,places=9)
        self.assertAlmostEqual(mapped[:,0].max(),204.646,places=9)


if __name__=='__main__':unittest.main()
