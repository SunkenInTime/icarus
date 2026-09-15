"""Compare canonical marker rotation with registered attack/defense artwork.

This is a coordinate audit. It does not move artwork or saved markers.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np


WORLD = np.array([1000 * 16 / 9, 1000])


def canvas_frame(box):
    left, top, width, height = box
    scale = min(1240 / width, 1000 / height)
    offset = (WORLD - np.array([width, height]) * scale) / 2 - np.array([left, top]) * scale
    return scale, offset


def audit(folder, output):
    rows = []
    for path in sorted(folder.glob('*.display-warp.json.gz')):
        raw = path.read_bytes()
        warp = json.loads(gzip.decompress(raw))
        attack_scale, attack_offset = canvas_frame(warp['attackViewBox'])
        defense_scale, defense_offset = canvas_frame(warp['defenseViewBox'])
        registration = warp['attackToDefenseSvg']
        side_matrix = np.column_stack((registration['axisU'], registration['axisV']))
        np.testing.assert_array_equal(side_matrix, -np.eye(2))
        registration_origin = np.array(registration['origin'])
        left, top, width, height = warp['attackViewBox']
        probes = np.array([[left, top], [left + width, top],
                           [left, top + height], [left + width, top + height]])
        expected = WORLD - (probes * attack_scale + attack_offset)
        actual = (probes @ side_matrix.T + registration_origin) * defense_scale + defense_offset
        mismatch = actual - expected
        # Different viewbox scales would need a full affine correction. Do
        # not report that as a constant translation.
        constant = float(np.ptp(mismatch, axis=0).max()) < 1e-9
        rows.append(dict(map=warp['map'], warpSha256=hashlib.sha256(raw).hexdigest(),
                         artwork=warp['art'], scaleAttack=attack_scale, scaleDefense=defense_scale,
                         constantTranslation=constant,
                         artworkMinusCanonicalMarkerCanvas=mismatch[0].tolist() if constant else None,
                         artworkMinusCanonicalMarkerSvg=(mismatch[0] / defense_scale).tolist() if constant else None,
                         maximumCornerMismatchCanvas=float(np.linalg.norm(mismatch, axis=1).max()),
                         cornerMismatchesCanvas=mismatch.tolist()))
    report = dict(scope=__doc__, scriptSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  productionMutation=False, maps=rows)
    if output.exists():
        raise FileExistsError(output)
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps([dict(map=r['map'], offsetSvg=r['artworkMinusCanonicalMarkerSvg']) for r in rows], indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    audit(args.folder, args.output)
