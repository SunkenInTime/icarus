"""Check that incomplete references cannot pass the material audit."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from pxr import Usd, UsdGeom, UsdShade
from audit_world_materials import audit


class MaterialAuditTests(unittest.TestCase):
    def run_audit(self, directory, with_triangle):
        source = Path(directory) / 'reference.usda'
        stage = Usd.Stage.CreateNew(str(source))
        if with_triangle:
            mesh = UsdGeom.Mesh.Define(stage, '/Unbound')
            mesh.CreatePointsAttr([(0, 0, 0), (1, 0, 0), (0, 1, 0)])
            mesh.CreateFaceVertexCountsAttr([3])
            mesh.CreateFaceVertexIndicesAttr([0, 1, 2])
        stage.GetRootLayer().Save()
        output = Path(directory) / 'audit.json'
        with contextlib.redirect_stdout(io.StringIO()):
            passed = audit(source, output)
        return passed, json.loads(output.read_text())

    def test_empty_reference_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            passed, report = self.run_audit(directory, False)
        self.assertFalse(passed)
        self.assertIn('no-visible-meshes', [i['kind'] for i in report['issues']])
        self.assertFalse(report['gameplayVerified'])

    def test_unbound_geometry_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            passed, report = self.run_audit(directory, True)
        self.assertFalse(passed)
        self.assertIn('unbound-faces', [i['kind'] for i in report['issues']])
        self.assertEqual(report['summary']['visibleMeshPrimsIncludingPrototypes'], 1)

    def test_hdr_texture_is_resolved_without_a_png(self):
        with tempfile.TemporaryDirectory() as directory:
            content = Path(directory) / 'ShooterGame' / 'Content'
            content.mkdir(parents=True)
            source = content / 'reference.usda'
            source.with_suffix('.json').write_text(json.dumps({
                'Parameters': {'BlendMode': 0},
                'Textures': {'Cubemap': '/Game/Reflection.Reflection'},
            }))
            (content / 'Reflection.hdr').write_bytes(b'#?RADIANCE\n')
            stage = Usd.Stage.CreateNew(str(source))
            mesh = UsdGeom.Mesh.Define(stage, '/Triangle')
            mesh.CreatePointsAttr([(0, 0, 0), (1, 0, 0), (0, 1, 0)])
            mesh.CreateFaceVertexCountsAttr([3])
            mesh.CreateFaceVertexIndicesAttr([0, 1, 2])
            material = UsdShade.Material.Define(stage, '/Material')
            UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(material)
            stage.GetRootLayer().Save()
            output = content / 'audit.json'
            with contextlib.redirect_stdout(io.StringIO()):
                passed = audit(source, output)
            report = json.loads(output.read_text())
        self.assertTrue(passed)
        self.assertEqual(report['issues'], [])
        self.assertFalse(report['gameplayVerified'])


if __name__ == '__main__':
    unittest.main()
