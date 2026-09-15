"""Piece subdivision must not create gaps in a continuous affine source ray."""
import unittest
import numpy as np
from source_floor_piece_cast import cast_floor_piece
from test_audit_tactical_target_rays import scene, wall


class PieceTests(unittest.TestCase):
    def test_submicrometre_piece_keeps_internal_wall(self):
        source=scene(wall(5,8))
        hit=cast_floor_piece(source,[0,0],[1,0],10,[0,0,0],5-2e-7,5+2e-7)
        self.assertIsNotNone(hit)
        self.assertEqual(hit['distanceMeters'],5)

    def test_internal_end_is_closed_but_final_guard_is_preserved(self):
        source=scene(wall(5,8))
        self.assertIsNotNone(cast_floor_piece(source,[0,0],[1,0],10,[0,0,0],0,5))
        self.assertIsNotNone(cast_floor_piece(source,[0,0],[1,0],10,[0,0,0],5,10))
        self.assertIsNone(cast_floor_piece(source,[0,0],[1,0],5,[0,0,0],0,5))

    def test_shifted_sloped_line_is_invariant_to_tiny_subdivision(self):
        triangles=np.array(wall(25,8));triangles[:,:,1]+=38
        source=scene(triangles); origin=np.array([20.,38.]); direction=np.array([1.,0.]);plane=np.array([.2,0.,-4.])
        whole=cast_floor_piece(source,origin,direction,10,plane,0,10)
        for offset in [-1e-8,0,1e-8]:
            cut=5+offset
            hits=[cast_floor_piece(source,origin,direction,10,plane,a,b) for a,b in [(0,cut-1e-7),(cut-1e-7,cut+1e-7),(cut+1e-7,10)]]
            found=[h for h in hits if h]
            self.assertTrue(found)
            np.testing.assert_allclose(found[0]['point'],whole['point'],rtol=0,atol=1e-12)

if __name__=='__main__':unittest.main()
