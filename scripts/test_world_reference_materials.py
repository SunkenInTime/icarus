import unittest

from world_reference_materials import MaterialCatalog


def source(path, category='opaque'):
    return {'source': path, 'sourceSha256': 'test-hash', 'category': category,
            'blendMode': 0 if category == 'opaque' else 2, 'missingTextures': []}


class MaterialCatalogTests(unittest.TestCase):
    def test_blend_data_beats_material_name(self):
        catalog = MaterialCatalog({'materials': {
            'a': source('/Exports/Content/Glass.json'),
            'b': source('/Exports/Content/Opaque.json', 'shader-dependent'),
        }})
        self.assertEqual(catalog.resolve('Glass.003')['category'], 'opaque')
        self.assertEqual(catalog.resolve('Opaque')['category'], 'shader-dependent')

    def test_colliding_names_are_unresolved(self):
        catalog = MaterialCatalog({'materials': {
            'a': source('/Exports/Content/A/Wall.json'),
            'b': source('/Exports/Content/B/Wall.json', 'shader-dependent'),
        }})
        self.assertEqual(catalog.resolve('Wall.002')['reason'], 'ambiguous-material-identifier')

    def test_repeated_bindings_to_one_asset_are_not_ambiguous(self):
        record = source('/Exports/Content/Wall.json')
        catalog = MaterialCatalog({'materials': {'a': record, 'b': record}})
        self.assertEqual(catalog.resolve('Wall.001')['category'], 'opaque')
        self.assertEqual(catalog.resolve('Truncated')['category'], 'unresolved')
        self.assertEqual(catalog.resolve(None)['reason'], 'unbound-material')

    def test_unbound_source_faces_keep_mesh_and_instances_uncertain(self):
        catalog = MaterialCatalog({'materials': {}, 'issues': [
            {'kind': 'unbound-subset', 'path': '/Art/Lamp/Instances/Prototypes/Mesh/Section_2'},
            {'kind': 'unbound-subset', 'path': '/Art/Door/StaticMeshComponent0/Section_1'},
        ]})
        self.assertEqual(catalog.unresolved_mesh('Art/Lamp/Instances.032'), '/Art/Lamp/Instances')
        self.assertEqual(catalog.unresolved_mesh('Art/Door/StaticMeshComponent0.123'), '/Art/Door/StaticMeshComponent0')
        self.assertIsNone(catalog.unresolved_mesh('Art/Wall/StaticMeshComponent0.124'))


if __name__ == '__main__':
    unittest.main()
