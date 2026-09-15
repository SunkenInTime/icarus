"""Bounded native projection contracts against frozen source counterexamples."""
import os
from pathlib import Path
import unittest

import numpy as np

from finite_receiver_shadows import Receiver
from native_finite_shadows import NativeFiniteShadows


LIBRARY = Path(os.environ.get('ICARUS_FINITE_SHADOW_DLL',
    'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/native-finite-shadow-build/Release/finite_receiver_shadow_audit.dll'))


@unittest.skipUnless(LIBRARY.exists(), 'Diagnostic native projection DLL not built')
class NativeShadowContracts(unittest.TestCase):
    def test_source_face939238_float32_collapse_requires_fallback(self):
        eye = [52.38207199097103, 44.581586999299226, 5.38850711819371]
        triangle = np.array([[[50.995406990869036, 42.49999609951105, 8.499998092651367],
                              [50.99540699086902, 42.49999609951105, 3.684335708618165],
                              [50.99540699086902, 42.49999609951105, 3.686049089187522]]])
        receiver = Receiver(np.array([[50., 42.05], [48.95, 42.05], [50., 40.]]), np.array([0., 0., 5.6]))
        mesh, fallback = NativeFiniteShadows(LIBRARY).project(eye, triangle, receiver)
        self.assertNotEqual(int(fallback[0]), 0,
                            'The finite source face becomes an unrenderable contact; its identity must remain explicit')
        for tri in mesh:
            a, b = tri[1]-tri[0], tri[2]-tri[0]
            self.assertNotEqual(float(a[0]*b[1]-a[1]*b[0]), 0.,
                                'A collapsed Float32 triangle cannot stand in for contact fallback')


if __name__ == '__main__':
    unittest.main()
