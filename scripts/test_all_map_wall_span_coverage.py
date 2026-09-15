import tempfile
from pathlib import Path
import unittest
import numpy as np
from audit_all_map_wall_span_coverage import authored_spans
from tactical_alignment_audit import vector_lines

class SpanTests(unittest.TestCase):
    def test_curves_short_spans_and_implicit_closure_are_inventoried(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'map.svg';path.write_text('<svg><path fill="#271406" d="M0 0 L1 0 Q2 1 3 0 L3 3"/></svg>')
            spans=authored_spans(path)
            self.assertEqual(len(spans),4)
            self.assertEqual(spans[0][0]['lengthSvg'],1)
            self.assertEqual(spans[1][0]['segmentType'],'QuadraticBezier')
            self.assertTrue(spans[-1][0]['implicitFillClosure'])
    def test_legacy_line_indices_match_original_split_helper(self):
        path=Path('assets/maps/split_map.svg');spans=authored_spans(path);legacy=vector_lines(path)
        selected=[row for row,segment in spans if row['legacyStraightEdgeIndex'] is not None]
        self.assertEqual(len(selected),len(legacy))
        for row,line in zip(selected,legacy):
            np.testing.assert_array_equal([row['startSvg'],row['endSvg']],line)
if __name__=='__main__':unittest.main()
