import copy
import json
from pathlib import Path
import tempfile
import unittest

from complete_world_floor_alternatives import complete_reference, digest
from verify_world_reference_metadata import verify_floor_completion


class FloorCompletionProofTests(unittest.TestCase):
    def test_verifies_unchanged_rays_and_rejects_false_added_heights(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source, nav_path, output = root/'original.json', root/'nav.json', root/'completed.json'
            navigation = {'map': 'bind', 'coordinateScale': 1, 'vertices': [0, 0, 2, 2, 0, 2, 0, 2, 2],
                          'polygons': [[0, 1, 2]], 'triangles': [0, 0, 1, 2], 'walkable': [True]}
            reference = {'map': 'bind', 'origins': [{'id': 0, 'floorAlternatives': []}],
                         'rays': [{'sample': 0, 'startUv': [.5, .5], 'distance': 4}], 'summary': {'errors': 1}}
            def write(path, value):
                path.write_text(json.dumps(value), encoding='utf-8')
            write(source, reference)
            write(nav_path, navigation)
            write(source.with_suffix('.policies.json'), {})
            write(output.with_suffix('.policies.json'), {})
            annotated, additions = complete_reference(reference, navigation)
            proof_path = root/'proof.json'
            write(proof_path, {'schemaVersion': 1, 'map': 'bind', 'sourceReference': str(source),
                              'navigationFile': str(nav_path), 'sourceReferenceSha256': digest(source),
                              'navigationSha256': digest(nav_path), 'raysAndStatisticsUnchanged': True,
                              'originsChecked': 1, 'additions': additions})
            annotated['floorAlternativeCompletion'] = {'proofFile': proof_path.name, 'proofSha256': digest(proof_path),
                                                       'sourceReferenceSha256': digest(source)}
            write(output, annotated)
            self.assertEqual(len(verify_floor_completion(output, nav_path)), 4)
            for mutation in ('height', 'ray', 'proof', 'navigation'):
                changed = copy.deepcopy(annotated)
                actual_nav = root/'asset-nav.json'
                write(actual_nav, navigation)
                if mutation == 'height':
                    changed['origins'][0]['floorAlternatives'][0]['floorHeightCm'] += 1
                elif mutation == 'ray':
                    changed['rays'][0]['distance'] = 9
                elif mutation == 'proof':
                    changed['floorAlternativeCompletion']['proofSha256'] = 'wrong'
                else:
                    bad_nav = copy.deepcopy(navigation)
                    bad_nav['vertices'][2] = 200
                    write(actual_nav, bad_nav)
                write(output, changed)
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    verify_floor_completion(output, actual_nav)


if __name__ == '__main__':
    unittest.main()
