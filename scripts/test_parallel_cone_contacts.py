import gzip
import json
from pathlib import Path
import tempfile
import unittest

from audit_svg_cone_boundaries import run as serial_run
from audit_svg_cone_boundaries_parallel import run, sha


class ParallelContactsTests(unittest.TestCase):
    def test_serial_parallel_resume_and_corruption_with_a_real_contact_fault(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            models = root/'models'
            (models/'test').mkdir(parents=True)
            model = dict(walls=[dict(id='column', fillRule='evenodd',
                rings=[[5, -10, 6, -10, 6, 10, 5, 10]])])
            model_path = models/'test/candidate-attack.json.gz'
            model_path.write_bytes(gzip.compress(json.dumps(model).encode(), mtime=0))
            valid = dict(id='valid', map='test', side='attack', originSvg=[0, 0],
                polygonSvg=[[0, 0], [5, -1], [5, 0], [5, 1]], rangeSvg=10,
                activeWallIds=['column'])
            invalid = dict(valid, id='early-cutoff',
                polygonSvg=[[0, 0], [3, -.6], [3, 0], [3, .6]])
            rows = [valid]*65 + [invalid]
            (root/'cones.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
            exported = dict(emitted=len(rows), conesSha256=sha(root/'cones.jsonl'),
                assetSha256={'assets/maps/test_svg_height_attack.json.gz': sha(model_path)})
            (root/'export-summary.json').write_text(json.dumps(exported))
            serial_run(root, models)
            serial = json.loads((root/'boundary-audit.json').read_bytes())
            parallel = run(root, models, workers=2)
            for key in serial:
                self.assertEqual(serial[key], parallel[key], key)
            self.assertEqual(parallel['flaggedCones'], 1)
            self.assertEqual(parallel['cases'][0]['id'], 'early-cutoff')
            self.assertTrue(all(row['kind'] == 'early-clip' for row in parallel['cases'][0]['issues']))
            resumed = run(root, models, workers=2)
            self.assertEqual(resumed['resumedBatches'], 2)
            self.assertEqual(resumed['cases'], parallel['cases'])
            checkpoint = next((root/'contact-checkpoints').rglob('0.json'))
            record = json.loads(checkpoint.read_bytes())
            record['result']['intervals'] += 1
            checkpoint.write_text(json.dumps(record))
            with self.assertRaises(AssertionError):
                run(root, models, workers=2)


if __name__ == '__main__':
    unittest.main()
