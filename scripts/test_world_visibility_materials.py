import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np
from PIL import Image

from world_visibility_materials import (AlphaSamplingError, build_policy, clip_alpha_segment,
                                        _axis_pixel_ranges, _pixel)


GRAPH = '''#usda 1.0
def Material "Material"
{
 token outputs:surface.connect = </Material/PBR.outputs:surface>
 def Shader "PBR"
 {
  uniform token info:id = "UsdPreviewSurface"
  float inputs:opacity.connect = </Material/Mask.outputs:a>
  float inputs:opacityThreshold = 0.333
  token outputs:surface
 }
 def Shader "Mask"
 {
  uniform token info:id = "UsdUVTexture"
  asset inputs:file = @./Texture.png@
  float2 inputs:st.connect = </Material/UV.outputs:result>
  float outputs:a
 }
 def Shader "UV"
 {
  uniform token info:id = "UsdPrimvarReader_float2"
  token inputs:varname = "st"
  float2 outputs:result
 }
}
'''


class MaterialPolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'Exports/ShooterGame/Content/Test/Material.json'
        self.source.parent.mkdir(parents=True)
        self.texture = self.source.with_name('Texture.png')
        Image.new('RGBA', (2, 2), (255, 255, 255, 255)).save(self.texture)
        self.source.with_suffix('.usda').write_text(GRAPH)
        self.meta = self.root / 'properties/ShooterGame/Content/Test/Texture.json'
        self.meta.parent.mkdir(parents=True)
        self.meta.write_text(json.dumps([{'Type': 'Texture2D', 'Name': 'Texture', 'Properties': {}}]))

    def record(self, blend=1, overrides=None):
        self.source.write_text(json.dumps({'Parameters': {'BlendMode': blend,
                             'Properties': {'BasePropertyOverrides': overrides or {}}}}))
        return {'source': str(self.source), 'sourceSha256': hashlib.sha256(self.source.read_bytes()).hexdigest(),
                'category': 'opaque' if blend == 0 else 'masked', 'blendMode': blend}

    def policy(self, blend=1, overrides=None):
        return build_policy(self.record(blend, overrides), texture_properties_root=self.root / 'properties')

    def test_opaque_is_solid_even_when_name_mentions_glass(self):
        record = self.record(0)
        record['blenderName'] = 'TransparentGlass'
        self.texture.unlink()
        policy = build_policy(record)
        self.assertEqual(policy['mode'], 'solid')
        self.assertTrue(policy['certain'])

    def test_known_nonopaque_blends_are_ignored_but_unknown_stays_solid(self):
        for blend in [2, 3, 4, 5]:
            self.assertEqual(self.policy(blend)['mode'], 'ignore')
        self.assertFalse(self.policy(99)['certain'])
        self.assertEqual(self.policy(99)['mode'], 'solid')

    def test_alpha_composite_does_not_create_an_opaque_wall_without_usd_opacity(self):
        record = self.record(5)
        self.texture.unlink()
        Path(record['source']).with_suffix('.usda').unlink()
        policy = build_policy(record)
        self.assertEqual(policy['mode'], 'ignore')
        self.assertTrue(policy['certain'])
        self.assertEqual(policy['reason'], 'source-alpha-composite-blend')

    def test_explicit_source_threshold_beats_exporter_fixed_threshold(self):
        policy = self.policy(overrides={'bOverride_OpacityMaskClipValue': True, 'OpacityMaskClipValue': .1})
        self.assertEqual(policy['mode'], 'alpha-test')
        self.assertEqual(policy['threshold'], .1)
        self.assertEqual(policy['usdThreshold'], .333)
        self.assertIn('source-threshold-corrects-exported-preview-threshold', policy['flags'])
        self.assertTrue(policy['certain'])

    def test_inactive_source_override_is_not_used(self):
        policy = self.policy(overrides={'bOverride_OpacityMaskClipValue': False, 'OpacityMaskClipValue': .05})
        self.assertEqual(policy['threshold'], .333)

    def test_explicit_texture_clamp_and_absent_wrap_default(self):
        self.meta.write_text(json.dumps([{'Type': 'Texture2D', 'Name': 'Texture',
                                        'Properties': {'AddressY': 'TextureAddress::TA_Clamp'}}]))
        policy = self.policy()
        self.assertEqual((policy['wrapS'], policy['wrapT']), ('repeat', 'clamp'))
        self.assertIn('TA_Wrap-default', policy['wrapSources']['S'])
        self.assertEqual(policy['wrapSources']['T'], 'source-texture.AddressY')

    def test_missing_texture_properties_keeps_wrap_assumption_visible(self):
        policy = build_policy(self.record())
        self.assertEqual(policy['mode'], 'alpha-test')
        self.assertFalse(policy['certain'])
        self.assertIn('unverified-game-texture-wrapS', policy['flags'])

    def test_missing_texture_or_wrong_graph_never_removes_a_wall(self):
        self.source.with_suffix('.usda').write_text(GRAPH.replace('Mask.outputs:a', 'Mask.outputs:r'))
        policy = self.policy()
        self.assertEqual(policy['mode'], 'solid')
        self.assertFalse(policy['certain'])
        self.source.with_suffix('.usda').write_text(GRAPH)
        self.texture.unlink()
        self.assertEqual(self.policy()['reason'], 'missing-alpha-texture')

    def test_hash_mismatch_and_unresolved_binding_stay_solid(self):
        record = self.record()
        self.source.write_text('{}')
        self.assertEqual(build_policy(record)['reason'], 'source-hash-mismatch')
        self.assertEqual(build_policy({'category': 'unresolved', 'reason': 'ambiguous-material-identifier'})['mode'], 'solid')

    def alpha_policy(self, values, threshold=.5, wrap='clamp'):
        img = Image.new('RGBA', (2, 2))
        img.putdata([(255, 255, 255, alpha) for alpha in values])
        img.save(self.texture)
        policy = self.policy(overrides={'bOverride_OpacityMaskClipValue': True, 'OpacityMaskClipValue': threshold})
        policy['wrapS'] = policy['wrapT'] = wrap
        return policy

    def test_bilinear_crossing_uses_lower_left_uv_origin(self):
        policy = self.alpha_policy([0, 0, 0, 255])
        intervals = clip_alpha_segment(policy, [.25, .25], [.75, .25])
        self.assertEqual(len(intervals), 1)
        self.assertAlmostEqual(intervals[0][0], .5)
        self.assertAlmostEqual(intervals[0][1], 1)
        self.assertEqual(clip_alpha_segment(policy, [.25, .75], [.75, .75]), [])

    def test_bilinear_quadratic_crossing_is_solved_within_texel_cell(self):
        policy = self.alpha_policy([0, 255, 0, 0], threshold=.25)
        intervals = clip_alpha_segment(policy, [.25, .25], [.75, .75])
        self.assertAlmostEqual(intervals[0][0], .5)
        self.assertAlmostEqual(intervals[0][1], 1)

    def test_repeat_and_clamp_produce_different_outside_tile_results(self):
        policy = self.alpha_policy([0, 0, 0, 255], wrap='repeat')
        self.assertEqual(clip_alpha_segment(policy, [1.25, .25], [1.25, .25]), [])
        policy['wrapS'] = 'clamp'
        self.assertEqual(clip_alpha_segment(policy, [1.25, .25], [1.25, .25]), [(0.0, 1.0)])

    def test_cell_budget_and_changed_alpha_fail_explicitly(self):
        policy = self.alpha_policy([0, 0, 0, 255])
        with self.assertRaisesRegex(AlphaSamplingError, 'cell-budget'):
            clip_alpha_segment(policy, [0, 0], [100, 100], max_cells=10)
        policy['alphaTextureSha256'] = 'bad-hash'
        with self.assertRaisesRegex(AlphaSamplingError, 'hash-mismatch'):
            clip_alpha_segment(policy, [0, 0], [1, 1])

    def test_uniform_footprint_keeps_neighboring_transparent_texel(self):
        # The segment is in an opaque texel's UV area, but the bilinear
        # footprint reaches the transparent neighbor before its geometric edge.
        policy = self.alpha_policy([0, 255, 0, 255], threshold=.75)
        result = clip_alpha_segment(policy, [.5, .25], [.75, .25])
        self.assertAlmostEqual(result[0][0], .5)
        self.assertAlmostEqual(result[0][1], 1)

    def test_wrapped_footprint_does_not_skip_alpha_seam(self):
        policy = self.alpha_policy([0, 255, 0, 255], wrap='repeat')
        result = clip_alpha_segment(policy, [.75, .25], [1.25, .25])
        self.assertAlmostEqual(result[0][0], 0)
        self.assertAlmostEqual(result[0][1], .5)

    def test_black_border_and_negative_alpha_scale(self):
        policy = self.alpha_policy([255, 255, 255, 255], threshold=.75, wrap='black')
        result = clip_alpha_segment(policy, [-.25, .5], [.25, .5])
        self.assertAlmostEqual(result[0][0], .75)
        self.assertAlmostEqual(result[0][1], 1)
        policy = self.alpha_policy([0, 255, 0, 255])
        policy.update(alphaScale=-1, alphaBias=1)
        result = clip_alpha_segment(policy, [.25, .25], [.75, .25])
        self.assertAlmostEqual(result[0][0], 0)
        self.assertAlmostEqual(result[0][1], .5)

    def test_texel_footprint_ranges_match_independent_enumeration(self):
        rng = np.random.default_rng(20260906)
        for size in [1, 2, 7, 32]:
            for wrap in ['repeat', 'clamp', 'mirror', 'black']:
                for start, end in rng.uniform(-3, 4, (50, 2)):
                    ranges, black = _axis_pixel_ranges(start, end-start, size, wrap)
                    actual = {p for lo, hi in ranges for p in range(lo, hi)}
                    a, b = sorted((start*size-.5, end*size-.5))
                    expected = {_pixel(p, size, wrap) for p in range(int(np.floor(a)), int(np.floor(b))+2)}
                    self.assertEqual(actual, expected - {None})
                    self.assertEqual(black, None in expected)


if __name__ == '__main__':
    unittest.main()
