import copy
import unittest
import numpy as np
import shapely

from apply_standing_domain_exclusions import exclude_domains


class StandingExclusionTests(unittest.TestCase):
    def test_region_rounding_does_not_create_a_standing_sliver(self):
        def domain(right):
            shape = shapely.box(0., 0., right, 2.)
            return dict(id='top', sourceCollision='box', sourceFaces=[[0, 0]],
                nativePlane=[0., 0., 13.], nativeGeometry=shapely.geometry.mapping(shape))
        triangles = {'0': np.array([[[0., 0., 13.], [2., 0., 13.], [2., 2., 13.]]])}
        review = dict(decisions=[dict(id='approved', status='approved',
            scope='specified-standing-domain', domain=domain(2.))])
        kept, removed = exclude_domains(dict(domains=[domain(2.+3e-8)]), [], triangles, review)
        self.assertEqual(kept, [])
        self.assertEqual(len(removed), 1)
        # A real extension beyond the source grid must remain selectable.
        kept, _ = exclude_domains(dict(domains=[domain(2.+1e-5)]), [], triangles, review)
        self.assertEqual(len(kept), 1)
        self.assertGreater(shapely.geometry.shape(kept[0]['nativeGeometry']).area, 1e-5)

    def test_exact_domain_keeps_adjacent_and_higher_faces(self):
        def domain(name, face, height=13., shape=None):
            shape = shapely.box(0, 0, 2, 2) if shape is None else shape
            return dict(id=name, sourceObject=2, sourcePath='mesh',
                sourceFaces=[[0, face]], nativePlane=[0., 0., height],
                nativeGeometry=shapely.geometry.mapping(shape), areaSquareMeters=shape.area)
        reviewed = domain('reviewed', 0)
        triangles = {'0': np.array([[[0.,0.,13.], [2.,0.,13.], [2.,2.,13.]]])}
        review = dict(decisions=[dict(id='approved', status='approved',
            scope='specified-standing-domain', domain=reviewed)])
        source = dict(domains=[reviewed, domain('other-face', 1), domain('higher', 2, 50.)])
        original = copy.deepcopy(source)
        kept, removed = exclude_domains(source, [], triangles, review)
        self.assertEqual(kept, source['domains'][1:])
        self.assertEqual([r['domain']['id'] for r in removed], ['reviewed'])
        self.assertEqual(source, original)
        # Region clipping and domain numbering cannot broaden the approval.
        regional = dict(domains=[domain('regional-42', 0, shape=shapely.box(1, 0, 3, 2))])
        kept, removed = exclude_domains(regional, [], triangles, review)
        self.assertTrue(shapely.geometry.shape(kept[0]['nativeGeometry']).equals(shapely.box(2, 0, 3, 2)))
        changed = copy.deepcopy(source)
        changed['domains'][0]['nativePlane'][2] += .01
        with self.assertRaises(AssertionError):
            exclude_domains(changed, [], triangles, review)
        triangles['0'][0, :, 2] += .01
        with self.assertRaises(AssertionError):
            exclude_domains(source, [], triangles, review)

    def test_boundary_clips_only_its_footprint_and_retains_lower_levels(self):
        colliders = [dict(id='ceiling', body=dict(Pawn='Block'))]
        triangles = {'0': np.array([[[0.,0.,13.], [2.,0.,13.], [2.,2.,13.]],
                                   [[0.,0.,13.], [2.,2.,13.], [0.,2.,13.]]])}
        def domain(name, height):
            shape = shapely.box(-1, 0, 3, 2)
            return dict(id=name, sourceObject=2, nativePlane=height,
                nativeGeometry=shapely.geometry.mapping(shape), areaSquareMeters=shape.area)
        source = dict(domains=[domain('lower', [0.,0.,2.]),
                              domain('inside', [0.,0.,20.]),
                              domain('above', [0.,0.,50.]),
                              domain('slope', [1.,0.,12.])])
        review = dict(decisions=[dict(id='boundary', status='approved',
            scope='at-or-above-collision-face-within-footprint', sourceCollision='ceiling',
            sourceFaces=[0,1], nativePlane=[0.,0.,13.])])
        original = copy.deepcopy((source, colliders))
        kept, removed = exclude_domains(source, colliders, triangles, review)
        self.assertEqual((source, colliders), original)
        self.assertEqual(kept[0], source['domains'][0])
        for d in kept[1:3]:
            shape = shapely.geometry.shape(d['nativeGeometry'])
            self.assertAlmostEqual(shape.area, 4.)
            self.assertTrue(shape.covers(shapely.Point(-.5, 1)))
            self.assertFalse(shape.covers(shapely.Point(1, 1)))
        slope = shapely.geometry.shape(kept[3]['nativeGeometry'])
        self.assertTrue(slope.covers(shapely.Point(.5, 1)))
        self.assertFalse(slope.covers(shapely.Point(1.5, 1)))
        self.assertTrue(slope.covers(shapely.Point(2.5, 1)))
        self.assertEqual([r['domain']['id'] for r in removed], ['inside', 'above', 'slope'])

    def test_exact_ceiling_face_exclusion_preserves_other_surfaces_and_colliders(self):
        colliders = [dict(id='ceiling', body=dict(Pawn='Block'))]
        triangles = {'0': np.array([[[0.,0.,27.], [1.,0.,27.], [0.,1.,27.]],
                                   [[0.,0.,1.], [1.,0.,1.], [0.,1.,1.]]])}
        source = dict(domains=[
            dict(id='ceiling-top', sourceCollision='ceiling', sourceFaces=[[0,0]], nativePlane=[0.,0.,27.]),
            dict(id='ceiling-other-face', sourceCollision='ceiling', sourceFaces=[[0,1]], nativePlane=[0.,0.,1.]),
            dict(id='higher-prop', sourceObject=2, nativePlane=[0.,0.,50.])])
        review = dict(decisions=[dict(id='approved', status='approved', scope='specified-collision-faces',
            sourceCollision='ceiling', sourceFaces=[0], nativePlane=[0.,0.,27.])])
        original = copy.deepcopy((source, colliders))
        kept, removed = exclude_domains(source, colliders, triangles, review)
        self.assertEqual([d['id'] for d in kept], ['ceiling-other-face', 'higher-prop'])
        self.assertEqual([r['domain']['id'] for r in removed], ['ceiling-top'])
        self.assertEqual((source, colliders), original)
        triangles['0'][0,:,2] += .1
        with self.assertRaises(AssertionError):
            exclude_domains(source, colliders, triangles, review)


if __name__ == '__main__':
    unittest.main()
