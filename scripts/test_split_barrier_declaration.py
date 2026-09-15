"""Reviewed front planes and the physical continuation must retain their joins."""
import unittest
import numpy as np
import shapely
from declare_split_barrier_continuation_region import declaration
from authored_region_cells import barycentric


class BarrierDeclarationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.family=declaration();cls.source=np.array(cls.family['sourceVerticesSvg']);cls.target=np.array(cls.family['targetVerticesSvg']);cls.cells=np.array(cls.family['triangles']);cls.tree=shapely.STRtree(shapely.polygons(cls.source[cls.cells]))

    def mapped(self,points):
        result=[]
        for point in np.asarray(points):
            hits=self.tree.query(shapely.Point(point),predicate='intersects');self.assertGreater(len(hits),0)
            cell=self.cells[hits[0]];result.append((barycentric(point[None],self.source[cell])@self.target[cell])[0])
        return np.array(result)

    def test_horizontal_front_and_mounted_panel_depth_share_authored123(self):
        # The mounted panel ends before the corner's vertical-return region;
        # do not fabricate panel samples beyond its actual source footprint.
        points=np.array([[x,y] for x in np.linspace(310.4113972085,337.3754193583,81) for y in [263.6459897280098,263.6708066535904]]+
            [[x,262.7839744145281] for x in np.linspace(325.83029922910634,336.3646963736125,81)])
        np.testing.assert_allclose(self.mapped(points)[:,1],264.145,rtol=0,atol=1e-8)

    def test_exact_source_corner_joins_map_to_authored_corners(self):
        source=np.array([[294.57318757809855,251.60627602723713],[306.6183448953599,263.6525668098494],[337.91717105408935,263.6525668098494]])
        np.testing.assert_allclose(self.mapped(source),[[294.491,251.917],[306.719,264.145],[338.617,264.145]],rtol=0,atol=1e-8)

    def test_return_and_its_lower_continuation_remain_vertical(self):
        points=np.array([[337.91717105408935,y] for y in np.r_[np.linspace(247.8,263.5,41),np.linspace(263.7,270.,21)]])
        np.testing.assert_allclose(self.mapped(points)[:,0],338.617,rtol=0,atol=1e-8)


if __name__=='__main__':unittest.main()
