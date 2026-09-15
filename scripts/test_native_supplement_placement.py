import copy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from native_supplement_placement import supplement_placement


class SupplementIdentityTests(unittest.TestCase):
    def test_recorded_instances_resolve_separately_and_reject_changed_sources(self):
        with TemporaryDirectory() as folder:
            root = Path(folder)
            relative = Path('ShooterGame/Content/Maps/Test/Test_Lighting.json')
            source = root/'components'/relative
            native = root/'properties'/relative
            source.parent.mkdir(parents=True)
            native.parent.mkdir(parents=True)
            mesh = dict(ObjectPath='/Game/Props/Lamp.2')
            record = dict(exportIndex=1, name='Instances', path='Test.Lamp.Instances', mesh=mesh, template=None)
            source.write_text(json.dumps([record]))
            native.write_text(json.dumps([
                dict(Name='Lamp'),
                dict(Name='Instances', Outer=dict(ObjectPath='/Game/Maps/Test/Test_Lighting.0'),
                     Properties=dict(StaticMesh=mesh))]))
            def digest(path):
                return hashlib.sha256(Path(path).read_bytes()).hexdigest()
            def verify(path, expected):
                if digest(path) != expected:
                    raise ValueError('Changed source hash')
            def read(path):
                return json.loads(Path(path).read_bytes())
            (root/'extraction-audit.json').write_text(json.dumps(dict(properties=[
                dict(packagePath=relative.with_suffix('.umap').as_posix(), errors=0, sha256=digest(native))])))
            prototype = '/Test/Lamp/Instances/Prototypes/Mesh'
            obj = dict(nativeResolvedComponent=dict(record, source=str(source), sourceSha256=digest(source)),
                sourceActorEvidence=[dict(name='Lamp')], sourceInstanceIndex=0,
                primPath=prototype, path=prototype+'/Instance_0', firstFace=20, faceCount=12,
                sourceLevel='Test.usda', sourceWorldTransform=[
                    [1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])
            first = supplement_placement(obj, read, verify)
            second = supplement_placement(dict(obj, sourceInstanceIndex=1,
                path=prototype+'/Instance_1', firstFace=32), read, verify)
            self.assertEqual((first['sourceInstance'], second['sourceInstance']), (0, 1))
            self.assertEqual((first['firstFace'], second['firstFace']), (20, 32))
            self.assertEqual(first['sourceUsd'], 'Test.usda')
            wrong_actor = copy.deepcopy(obj)
            wrong_actor['sourceActorEvidence'][0]['name'] = 'OtherLamp'
            with self.assertRaisesRegex(ValueError, 'different source actor'):
                supplement_placement(wrong_actor, read, verify)
            with self.assertRaisesRegex(ValueError, 'instance identity'):
                supplement_placement(dict(obj, sourceInstanceIndex=1), read, verify)
            template = dict(ObjectPath='/Game/Props/LampTemplate.0',
                ObjectName="StaticMeshComponent'LampTemplate_C:Mesh'")
            template_path = root/'templates/Props/LampTemplate.json'
            template_path.parent.mkdir(parents=True)
            template_path.write_text(json.dumps([dict(Type='StaticMeshComponent', Name='Mesh',
                Properties=dict(StaticMesh=mesh))]))
            record['template'] = template
            source.write_text(json.dumps([record]))
            level = read(native)
            level[1].update(Type='StaticMeshComponent', Template=template, Properties={})
            native.write_text(json.dumps(level))
            (root/'extraction-audit.json').write_text(json.dumps(dict(properties=[
                dict(packagePath=relative.with_suffix('.umap').as_posix(), errors=0, sha256=digest(native))])))
            obj['nativeResolvedComponent'] = dict(record, source=str(source), sourceSha256=digest(source))
            with self.assertRaisesRegex(ValueError, 'native mesh differs'):
                supplement_placement(obj, read, verify)
            inherited = supplement_placement(obj, read, verify, [root/'templates'])
            self.assertEqual(inherited['nativeMesh'], '/Game/Props/Lamp')
            self.assertEqual(inherited['supplementIdentity']['templateEvidence'][0]['sha256'], digest(template_path))
            template_path.write_text(json.dumps([dict(Type='StaticMeshComponent', Name='Mesh',
                Properties=dict(StaticMesh=dict(ObjectPath='/Game/Props/Wrong.0')))]))
            with self.assertRaisesRegex(ValueError, 'native mesh differs'):
                supplement_placement(obj, read, verify, [root/'templates'])
            source.write_text('[]')
            with self.assertRaisesRegex(ValueError, 'Changed source hash'):
                supplement_placement(obj, read, verify)


if __name__ == '__main__':
    unittest.main()
