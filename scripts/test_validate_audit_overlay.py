import unittest
from pathlib import Path

import numpy as np
from PIL import Image

from validate_audit_overlay import inconsistent_pixels


class OverlayConsistencyTest(unittest.TestCase):
    def test_detects_translucent_leak_and_preserves_artwork(self):
        art = np.array([[[120, 70, 20, 255], [0, 0, 0, 0]]], dtype=np.uint8)
        coverage = np.zeros_like(art)
        correct = np.array([[[120, 70, 20, 255], [16, 16, 20, 255]]], dtype=np.uint8)
        self.assertFalse(inconsistent_pixels(correct, coverage, art).any())
        wrong = correct.copy()
        wrong[0, 1] = [8, 96, 84, 255]
        self.assertEqual(inconsistent_pixels(wrong, coverage, art).tolist(), [[False, True]])
        coverage[0, 1, 3] = 128
        self.assertFalse(inconsistent_pixels(wrong, coverage, art).any())

    def test_rejects_frozen_actual_failure_and_accepts_fresh_replay(self):
        root = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
        old = root / 'ascent-component5-contact-v8'
        fresh = root / 'ascent-opening15-overlay-replay-v1'
        name = 'attack-preserved-opening-15-8x-'
        art = Image.open(old / 'attack-8x-art.png').convert('RGBA').crop((1598, 2097, 1860, 2329))
        coverage = Image.open(old / (name+'visibility-context.png')).convert('RGBA')
        faulty = Image.open(old / (name+'overlay-context.png')).convert('RGBA')
        correct = Image.open(fresh / (name+'overlay-context.png')).convert('RGBA')
        self.assertGreater(int(inconsistent_pixels(faulty, coverage, art).sum()), 11000)
        self.assertEqual(int(inconsistent_pixels(correct, coverage, art).sum()), 0)


if __name__ == '__main__':
    unittest.main()
