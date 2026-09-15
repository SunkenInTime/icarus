import unittest

from audit_floor_pawn_support import classify_support


class PawnSupportTests(unittest.TestCase):
    body = {'DefaultInstance': {'CollisionProfileName': 'BlockAll'},
            'CollisionTraceFlag': 'ECollisionTraceFlag::CTF_UseComplexAsSimple'}

    def classify(self, properties, body=None, actor=None):
        return classify_support({'Properties': properties}, body or self.body,
                                actor or {})[0]

    def test_omitted_component_defaults_do_not_inherit_a_blocking_mesh(self):
        self.assertEqual(self.classify({}), 'unresolved-component-default')

    def test_explicit_mesh_default_supports_complex_surface(self):
        self.assertEqual(self.classify({'bUseDefaultCollision': True}),
                         'declared-pawn-blocking-complex')

    def test_pawn_ignore_overrides_blockall_profile_and_mesh_support(self):
        self.assertEqual(self.classify({'bUseDefaultCollision': False,
            'BodyInstance': {'CollisionProfileName': 'BlockAll',
                'CollisionResponses': {'ResponseArray': [
                    {'Channel': 'Pawn', 'Response': 'ECR_Ignore'}]}}}),
            'excluded-explicit-pawn-nonblocking')

    def test_no_collision_and_actor_disable_take_precedence(self):
        self.assertEqual(self.classify({'BodyInstance': {
            'CollisionProfileName': 'NoCollision'}}), 'excluded-no-collision')
        self.assertEqual(self.classify({'bUseDefaultCollision': True}, actor={
            'Properties': {'bActorEnableCollision': False}}),
            'excluded-actor-collision-disabled')

    def test_simple_collision_is_not_assumed_to_match_rendered_surface(self):
        self.assertEqual(self.classify({'bUseDefaultCollision': True}, body={
            'DefaultInstance': {'CollisionProfileName': 'BlockAll'},
            'CollisionTraceFlag': 'ECollisionTraceFlag::CTF_UseSimpleAsComplex'}),
            'declared-pawn-blocking-shape-unverified')

    def test_custom_array_restores_omitted_pawn_to_engine_default(self):
        for responses in [[], [{'Channel': 'Visibility', 'Response': 'ECR_Ignore'}]]:
            self.assertEqual(self.classify({'BodyInstance': {
                'CollisionProfileName': 'Custom',
                'CollisionResponses': {'ResponseArray': responses}}}),
                'declared-pawn-blocking-complex')

    def test_block_all_dynamic_preserves_an_explicit_pawn_exclusion(self):
        body = {'CollisionProfileName': 'BlockAllDynamic'}
        self.assertEqual(self.classify({'BodyInstance': body}), 'declared-pawn-blocking-complex')
        body['CollisionResponses'] = {'ResponseArray': [{'Channel': 'Pawn', 'Response': 'ECR_Ignore'}]}
        self.assertEqual(self.classify({'BodyInstance': body}), 'excluded-explicit-pawn-nonblocking')

    def test_custom_explicit_pawn_and_unknown_profile_remain_separate(self):
        body = {'CollisionProfileName': 'Custom', 'CollisionResponses': {
            'ResponseArray': [{'Channel': 'Pawn', 'Response': 'ECR_Overlap'}]}}
        self.assertEqual(self.classify({'BodyInstance': body}),
                         'excluded-explicit-pawn-nonblocking')
        for profile, responses in [('UnknownPreset', {'ResponseArray': []}), ('Custom', {})]:
            self.assertEqual(self.classify({'BodyInstance': {
                'CollisionProfileName': profile, 'CollisionResponses': responses}}),
                'unresolved-pawn-profile')


if __name__ == '__main__':
    unittest.main()
