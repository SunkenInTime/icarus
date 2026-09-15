"""Checkpoint bytes, bindings and overwrite protection survive a round trip."""
import tempfile,unittest
from unittest.mock import patch
from pathlib import Path
import numpy as np
from normalization_checkpoint import save_checkpoint,load_checkpoint,sha


class CheckpointTests(unittest.TestCase):
    def test_exact_array_roundtrip_and_input_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'source';warp=root/'warp';source.write_bytes(b'sealed source');warp.write_bytes(b'sealed warp');out=root/'candidate'
            arrays=dict(triangles=np.arange(18,dtype=np.float64).reshape(2,3,3),parents=np.array([7,12],dtype=np.int64));families=[dict(edge=123,sourceVerticesSvg=[[0.,1.],[2.,3.]])]
            binding=save_checkpoint(out,source,warp,families,arrays,dict(discarded=2),[]);metadata,recovered,rebound=load_checkpoint(binding['metadataFile']);self.assertEqual(binding,rebound)
            for key in arrays:self.assertEqual(arrays[key].dtype,recovered[key].dtype);self.assertEqual(arrays[key].tobytes(),recovered[key].tobytes())
            self.assertEqual(families,metadata['families'])
            self.assertIn('finite_edge_owners.py',metadata['generatorHashes'])
            with patch('normalization_checkpoint.sha',side_effect=lambda p:'changed cache' if Path(p).name=='finite_edge_owners.py' else sha(p)):
                with self.assertRaisesRegex(AssertionError,'finite_edge_owners.py'):
                    load_checkpoint(binding['metadataFile'])
            source.write_bytes(b'changed source')
            with self.assertRaises(AssertionError):load_checkpoint(binding['metadataFile'])

    def test_existing_checkpoint_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'source';source.write_bytes(b'input');out=root/'candidate';args=(out,source,source,[],dict(values=np.array([1.])),{},[])
            save_checkpoint(*args)
            with self.assertRaises(FileExistsError):save_checkpoint(*args)

    def test_object_arrays_are_not_serialized(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'source';source.write_bytes(b'input')
            with self.assertRaises(AssertionError):save_checkpoint(root/'candidate',source,source,[],dict(values=np.array([{}],dtype=object)),{},[])

if __name__=='__main__':unittest.main()
