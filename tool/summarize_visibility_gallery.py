"""Rank fixed-pose visibility changes for review, without calling them errors."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


def summarize(folder):
    manifest = json.loads((folder / 'manifest.json').read_text())
    rows = []
    for case in manifest['cases']:
        if case['after'] is None:
            rows.append({**{k: case[k] for k in ('map', 'side', 'id')},
                         'available': False, 'reason': case['candidateFloorMode']})
            continue
        masks = []
        for key in ('before', 'after'):
            path = case[key].replace('-overlay.png', '-visibility.png')
            masks.append(np.asarray(Image.open(path).getchannel('A')) >= 128)
        before, after = masks
        assert before.shape == after.shape
        a, b = int(before.sum()), int(after.sum())
        lost, gained = int((before & ~after).sum()), int((after & ~before).sum())
        expected, selected = case.get('expectedGroundVariant'), case.get('candidateGroundChart')
        rows.append({**{k: case[k] for k in ('map', 'side', 'id')},
                     'available': True, 'beforePixels': a, 'afterPixels': b,
                     'lostPixels': lost, 'gainedPixels': gained,
                     'lostFractionOfBefore': lost / max(a, 1),
                     'gainedFractionOfBefore': gained / max(a, 1),
                     'expectedGroundVariant': expected, 'candidateGroundChart': selected,
                     'knownVariantMismatch': expected is not None and expected != selected,
                     'floorMode': case['candidateFloorMode']})
    changes = sorted((r for r in rows if r['available']),
                     key=lambda r: r['lostPixels'], reverse=True)
    report = {'scope': 'Pixel differences prioritize inspection. Loss or gain is not a correctness verdict. Actual side registration and intended ramp corrections also change these masks.',
              'alphaThreshold': 128, 'physicalPixelsPerSvgUnit': manifest['physicalPixelsPerSvgUnit'],
              'cases': rows, 'largestLosses': changes[:30]}
    (folder / 'visibility-change-summary.json').write_text(json.dumps(report, indent=2))
    for row in changes[:20]:
        print(f"{row['map']:9} {row['side']:7} {row['id']:38} "
              f"lost {row['lostFractionOfBefore']:6.1%} / {row['lostPixels']:6} px "
              f"gained {row['gainedFractionOfBefore']:6.1%} "
              f"{'KNOWN UPPER VARIANT MISMATCH' if row['knownVariantMismatch'] else ''}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    summarize(parser.parse_args().folder)
