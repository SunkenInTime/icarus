import unittest
import struct
import json
from pathlib import Path
from tempfile import TemporaryDirectory

from gameplay_source_floors import SourceFloors
from native_collision_defaults import resolve_component, resolve_template, resolve_native_mesh_component
from cooked_collision_evidence import empty_simple_shapes, no_simple_collision


class NativePlacementTests(unittest.TestCase):
    def source(self, records):
        source = SourceFloors.__new__(SourceFloors)
        source.name = 'test'
        source.objects = [dict(path='Art/Barrel/Instances.002', firstFace=10, faceCount=8),
                          dict(path='Art/Barrel/Instances.002', firstFace=18, faceCount=8)]
        source.placements = {r['firstFace']: r for r in records}
        return source

    def test_repeated_path_keeps_each_verified_instance(self):
        rows = [dict(path='Art/Barrel/Instances.002', firstFace=10, faceCount=8, sourceInstance=7),
                dict(path='Art/Barrel/Instances.002', firstFace=18, faceCount=8, sourceInstance=8)]
        source = self.source(rows)
        self.assertEqual(source.placement(0)['sourceInstance'], 7)
        self.assertEqual(source.placement(1)['sourceInstance'], 8)

    def test_same_face_offset_from_different_geometry_is_rejected(self):
        for changed in [dict(path='Art/Other/Instances.002'), dict(faceCount=9)]:
            row = dict(path='Art/Barrel/Instances.002', firstFace=10, faceCount=8)
            row.update(changed)
            with self.assertRaisesRegex(ValueError, 'does not match'):
                self.source([row]).placement(0)

    def test_missing_placement_cannot_borrow_another_instance(self):
        source = self.source([dict(path='Art/Barrel/Instances.002', firstFace=18, faceCount=8)])
        self.assertIsNone(source.placement(0))


class NativeDefaultTests(unittest.TestCase):
    actor = dict(Type='StaticMeshActor', Name='Floor', Properties=dict(RootComponent=dict(
        ObjectName="StaticMeshComponent'Art:PersistentLevel.Floor.StaticMeshComponent0'")))

    def component(self, props):
        return dict(Type='StaticMeshComponent', Name='StaticMeshComponent0', Properties=props)

    def test_native_root_uses_mesh_defaults_and_preserves_other_instance_fields(self):
        component = self.component(dict(BodyInstance=dict(MaxAngularVelocity=3599.9)))
        resolved, evidence = resolve_component(component, self.actor)
        self.assertTrue(resolved['Properties']['bUseDefaultCollision'])
        self.assertEqual(resolved['Properties']['BodyInstance']['MaxAngularVelocity'], 3599.9)
        self.assertNotIn('bUseDefaultCollision', component['Properties'])
        self.assertIn('bUseDefaultCollision', evidence['fields'])

    def test_explicit_collision_choice_is_never_replaced(self):
        props = dict(bUseDefaultCollision=False, BodyInstance=dict(CollisionProfileName='NoCollision'))
        resolved, _ = resolve_component(self.component(props), self.actor)
        self.assertEqual(resolved['Properties'], props)

    def test_blueprint_or_nonroot_component_does_not_inherit_native_root_defaults(self):
        for actor in [dict(self.actor, Type='BP_Floor_C'), dict(self.actor, Properties={})]:
            component = self.component({})
            resolved, evidence = resolve_component(component, actor)
            self.assertEqual(resolved, component)
            self.assertIsNone(evidence)


class TemplateTests(unittest.TestCase):
    def test_native_template_defaults_remain_below_instance_collision_overrides(self):
        with TemporaryDirectory() as folder:
            root = Path(folder)
            template = dict(Type='StaticMeshComponent', Class="UScriptClass'StaticMeshComponent'", Name='Mesh')
            (root/'Bush.json').write_text(json.dumps([template]))
            component = dict(Type='StaticMeshComponent', Name='PlacedMesh',
                Template=dict(ObjectPath='/Game/Bush.0', ObjectName="StaticMeshComponent'Bush_C:Mesh'"))
            resolved, evidence = resolve_template(component, [root])
            self.assertFalse(resolved['Properties']['bUseDefaultCollision'])
            self.assertEqual(resolved['Properties']['BodyInstance']['CollisionProfileName'], 'BlockAllDynamic')
            self.assertIn('nativeClassDefaults', evidence[0])
            component['Properties'] = dict(bUseDefaultCollision=True, BodyInstance=dict(CollisionProfileName='NoCollision'))
            resolved, _ = resolve_template(component, [root])
            self.assertEqual(resolved['Properties'], component['Properties'])
            (root/'Bush.json').unlink()
            unresolved, evidence = resolve_template(component, [root])
            self.assertEqual(unresolved, component)
            self.assertFalse(evidence)

    def test_native_ism_class_is_exact_and_does_not_bypass_an_archetype(self):
        component = dict(Type='InstancedStaticMeshComponent', Class="UScriptClass'InstancedStaticMeshComponent'")
        resolved, evidence = resolve_native_mesh_component(component)
        self.assertFalse(resolved['Properties']['bUseDefaultCollision'])
        self.assertEqual(resolved['Properties']['BodyInstance']['CollisionProfileName'], 'BlockAllDynamic')
        for changed in [dict(Class="BlueprintGeneratedClass'CustomISM'"), dict(Template=dict(ObjectPath='/Game/Missing.0'))]:
            unresolved = dict(component, **changed)
            self.assertEqual(resolve_native_mesh_component(unresolved), (unresolved, None))

    def test_hierarchical_instances_keep_native_defaults_below_serialized_fields(self):
        component = dict(Type='HierarchicalInstancedStaticMeshComponent',
            Class="UScriptClass'HierarchicalInstancedStaticMeshComponent'")
        resolved, evidence = resolve_native_mesh_component(component)
        self.assertFalse(resolved['Properties']['bUseDefaultCollision'])
        self.assertEqual(resolved['Properties']['BodyInstance']['CollisionProfileName'], 'BlockAllDynamic')
        self.assertTrue(any('HierarchicalInstancedStaticMesh.cpp#L1923' in s for s in evidence['sources']))
        overridden = dict(component, Properties=dict(bUseDefaultCollision=True,
            BodyInstance=dict(CollisionProfileName='NoCollision')))
        self.assertEqual(resolve_native_mesh_component(overridden)[0]['Properties'], overridden['Properties'])
        for changed in [dict(Class="BlueprintGeneratedClass'CustomHISM'"),
                        dict(Template=dict(ObjectPath='/Game/Missing.0'))]:
            unresolved = dict(component, **changed)
            self.assertEqual(resolve_native_mesh_component(unresolved), (unresolved, None))

    def test_nested_template_keeps_each_override_and_rejects_cycles(self):
        with TemporaryDirectory() as folder:
            root = Path(folder)
            parent = dict(Type='StaticMeshComponent', Name='BaseMesh',
                Properties=dict(BodyInstance=dict(CollisionProfileName='NoCollision', MaxAngularVelocity=100)))
            child = dict(Type='StaticMeshComponent', Name='ChildMesh',
                Template=dict(ObjectPath='/Game/Base.0', ObjectName="StaticMeshComponent'Base_C:BaseMesh'"),
                Properties=dict(BodyInstance=dict(MaxAngularVelocity=200)))
            component = dict(Type='StaticMeshComponent', Name='Mesh',
                Template=dict(ObjectPath='/Game/Child.0', ObjectName="StaticMeshComponent'Child_C:ChildMesh'"),
                Properties=dict(BodyInstance=dict(MaxAngularVelocity=300)))
            (root/'Base.json').write_text(json.dumps([parent]))
            (root/'Child.json').write_text(json.dumps([child]))
            resolved, evidence = resolve_template(component, [root])
            self.assertEqual(resolved['Properties']['BodyInstance'],
                             dict(CollisionProfileName='NoCollision', MaxAngularVelocity=300))
            self.assertEqual([row['name'] for row in evidence], ['BaseMesh', 'ChildMesh'])
            parent['Template'] = component['Template']
            (root/'Base.json').write_text(json.dumps([parent]))
            with self.assertRaisesRegex(ValueError, 'Cyclic'):
                resolve_template(component, [root])
            (root/'Base.json').unlink()
            with self.assertRaisesRegex(ValueError, 'missing'):
                resolve_template(component, [root])

    def test_template_collision_survives_partial_instance_body_override(self):
        with TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'Wind.json').write_text(json.dumps([dict(Type='StaticMeshComponent', Name='Mesh_GEN_VARIABLE',
                Properties=dict(BodyInstance=dict(CollisionProfileName='NoCollision', MaxAngularVelocity=100)))]))
            component = dict(Type='StaticMeshComponent', Name='Mesh',
                Template=dict(ObjectPath='/Game/Wind.0', ObjectName="StaticMeshComponent'Wind_C:Mesh_GEN_VARIABLE'"),
                Properties=dict(BodyInstance=dict(MaxAngularVelocity=3600)))
            resolved, evidence = resolve_template(component, [root])
            self.assertEqual(resolved['Properties']['BodyInstance'],
                dict(CollisionProfileName='NoCollision', MaxAngularVelocity=3600))
            self.assertNotIn('CollisionProfileName', component['Properties']['BodyInstance'])
            self.assertEqual(evidence[0]['objectIndex'], 0)
            component['Properties']['BodyInstance']['CollisionProfileName'] = 'BlockAll'
            self.assertEqual(resolve_template(component, [root])[0]['Properties']['BodyInstance']['CollisionProfileName'], 'BlockAll')
            component['Template']['ObjectName'] = "StaticMeshComponent'Wind_C:Wrong_GEN_VARIABLE'"
            with self.assertRaisesRegex(ValueError, 'identity'):
                resolve_template(component, [root])


class CookedShapeTests(unittest.TestCase):
    def test_absent_index_is_unproven_but_invalid_evidence_still_fails(self):
        with TemporaryDirectory() as folder:
            root = Path(folder)
            export = root/'export'
            mesh = export/'properties'/'Mesh.json'
            mesh.parent.mkdir(parents=True)
            mesh.write_text('[]')
            (export/'collision-configuration.json').write_text(json.dumps([
                dict(lines=['DefaultShapeComplexity=CTF_UseSimpleAndComplex'])]))
            self.assertIsNone(no_simple_collision(root, mesh, {}, [export]))
            index = export/'collision'/'Mesh'/'index.json'
            index.parent.mkdir(parents=True)
            mesh.write_text(json.dumps([dict(Type='BodySetup',Name='Body')]))
            bodies = index.parent/'bodies.json'
            for unproven in [[], [dict(body='WrongBody',formats=[])], [dict(body='Body',formats=['PhysXPC'])]]:
                bodies.write_text(json.dumps(unproven))
                self.assertIsNone(no_simple_collision(root, mesh, {}, [export]))
            bodies.write_text(json.dumps([dict(body='Body',formats=[])]))
            proof = no_simple_collision(root, mesh, {}, [export])
            self.assertIn('bodyInventorySha256', proof)
            self.assertIsNone(no_simple_collision(root, mesh, dict(AggGeom=dict(BoxElems=[{}])), [export]))
            index.write_text('{broken')
            with self.assertRaises(json.JSONDecodeError):
                no_simple_collision(root, mesh, {}, [export])
            index.write_text(json.dumps([dict(format='PhysXPC', file='payload.bin',
                bytes=28, sha256='incorrect')]))
            (index.parent/'payload.bin').write_bytes(struct.pack('<7i', 4, 0, 0, 0, 0, 0, 0))
            with self.assertRaisesRegex(ValueError, 'bytes changed'):
                no_simple_collision(root, mesh, {}, [export])

    def test_complete_empty_collision_payload_rejects_truncation_or_extra_data(self):
        empty = struct.pack('<7i', 4, 0, 0, 0, 0, 0, 0)
        self.assertTrue(empty_simple_shapes(empty))
        for invalid in [empty[:12], empty[:-1], empty+b'\0', struct.pack('<7i', 4, 0, 0, 0, 1, 0, 0)]:
            self.assertFalse(empty_simple_shapes(invalid))

    def test_zero_simple_array_with_triangle_payload(self):
        self.assertTrue(empty_simple_shapes(struct.pack('<iiiiiB', 4, 0, 1, 1, 0, 11)))

    def test_nonempty_or_unknown_format_cannot_establish_missing_simple_shapes(self):
        for header in [(4, 1, 1, 1, 0, 11), (8, 0, 1, 1, 0, 11), (4, 0, 1, 1, 0, 8)]:
            self.assertFalse(empty_simple_shapes(struct.pack('<iiiiiB', *header)))
        with self.assertRaisesRegex(ValueError, 'Truncated'):
            empty_simple_shapes(b'')


if __name__ == '__main__':
    unittest.main()
