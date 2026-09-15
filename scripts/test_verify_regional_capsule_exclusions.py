import copy
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import numpy as np
from scipy.spatial import ConvexHull
import shapely

from redundant_capsule_collision import enclosed_capsules, capsule_column_union
from native_capsule_collision import capsule_parts
from verify_regional_capsule_exclusions import verify, verify_column_union, scaled_capsule


class MixedCollisionVerificationTests(unittest.TestCase):
    def test_union_proof_checks_full_prisms_and_rejects_a_seam_gap(self):
        rows, equations, triangles = [], [], {}
        for i, (low, high) in enumerate([(-1., .00001), (0., 1.)]):
            vertices = np.array([[x,y,z] for x in [-1.,1.] for y in [-1.,1.] for z in [low,high]])
            hull = ConvexHull(vertices)
            rows.append(dict(id=str(i), kill=False))
            equations.append(hull.equations)
            triangles[str(i)] = vertices[hull.simplices]
        volumes = SimpleNamespace(rows=rows, equations=equations,
            tree=shapely.STRtree([shapely.box(-1,-1,1,1)]*2))
        element = dict(Center=dict(X=0,Y=0,Z=0), Radius=6,Length=24,
            Rotation=dict(Pitch=90,Yaw=0,Roll=0), CollisionEnabled='ECollisionEnabled::QueryAndPhysics')
        shape = capsule_parts(dict(AggGeom=dict(SphylElems=[element])),np.eye(4))[0]
        proof = capsule_column_union(shape, volumes)
        self.assertIsNotNone(proof)
        measured = scaled_capsule(shape, element)
        verify_column_union(proof, measured, rows, {'0':0,'1':1}, triangles)
        for fault in ['missing', 'gap', 'outside']:
            changed = copy.deepcopy(proof)
            if fault == 'missing': changed['containingVolumes'].pop()
            elif fault == 'gap': changed['containingVolumes'][1]['lowerMeters'] = .001
            else: changed['containingVolumes'][0]['upperMeters'] = .01
            with self.assertRaises(AssertionError):
                verify_column_union(changed, measured, rows, {'0':0,'1':1}, triangles)
        # Separate the actual source bodies: neither their union nor the
        # expanded shape certificate may bridge the resulting gap.
        equations[1] = equations[1].copy()
        bottom = equations[1][:,2] < -.5
        equations[1][bottom,3] += .002
        self.assertIsNone(capsule_column_union(shape, volumes))

    def test_independent_boundary_verification_rejects_omitted_or_changed_shapes(self):
        vertices = np.array([[x,y,z] for x in [-1.,1.] for y in [-1.,1.] for z in [-1.,1.]])
        hull = ConvexHull(vertices)
        collider = dict(id='enclosing-box', kill=False)
        volumes = SimpleNamespace(rows=[collider], equations=[hull.equations],
            tree=shapely.STRtree([shapely.box(-1,-1,1,1)]))
        body = dict(AggGeom=dict(
            SphylElems=[dict(Center=dict(X=5,Y=3,Z=2), Radius=6,Length=24,
                Rotation=dict(Pitch=90,Yaw=0,Roll=0))],
            BoxElems=[dict(Center=dict(X=0,Y=0,Z=0), X=5,Y=5,Z=150,
                Rotation=dict(Pitch=0,Yaw=0,Roll=0))]))
        proof = enclosed_capsules(body,np.eye(4),volumes)
        with TemporaryDirectory() as folder:
            root = Path(folder)
            inventory = dict(inventory=[dict(sourceObject=7,evidence=dict(bodySetup=body))],
                sourceRegion=json.loads(shapely.to_geojson(shapely.box(-1,-1,1,1))))
            (root/'source-inventory.json').write_text(json.dumps(inventory))
            (root/'source-colliders.json').write_text(json.dumps([collider]))
            np.savez_compressed(root/'source-colliders.npz', **{'0':vertices[hull.simplices]})

            def run(candidate):
                (root/'collision-accounting.json').write_text(json.dumps(dict(unresolved=[],
                    redundantCollision={'7':candidate})))
                with patch('builtins.print'):
                    return verify(root)

            self.assertEqual(len(run(proof)['records']),2)
            omitted = copy.deepcopy(proof)
            del omitted['boxes']
            with self.assertRaises(AssertionError):
                run(omitted)
            changed = copy.deepcopy(proof)
            changed['boxes'][0]['verticesMeters'][0][0] += .1
            with self.assertRaises(AssertionError):
                run(changed)
            changed = copy.deepcopy(proof)
            changed['capsules'][0]['radiusMeters'] -= .01
            with self.assertRaises(AssertionError):
                run(changed)


if __name__ == '__main__':
    unittest.main()
