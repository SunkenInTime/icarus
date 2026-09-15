import unittest
from collections import Counter
from propose_connected_contours import component_stem


class ContourFileIdentityTest(unittest.TestCase):
    def test_repeated_subpaths_from_different_elements_do_not_overwrite(self):
        keys = [(1, 0), (1, 1), (5, 0), (8, 0)]
        counts = Counter(component for _, component in keys)
        names = [component_stem(*key, counts) for key in keys]
        self.assertEqual(len(set(names)), len(keys))
        self.assertEqual(names, ['element-1-component-0', 'component-1',
                                 'element-5-component-0', 'element-8-component-0'])

    def test_unique_component_keeps_existing_evidence_filename(self):
        self.assertEqual(component_stem(1, 3, Counter({3: 1})), 'component-3')


if __name__ == '__main__':
    unittest.main()
