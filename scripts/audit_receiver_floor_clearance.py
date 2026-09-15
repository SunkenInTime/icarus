"""Check source-floor candidate columns inside the actual SVG receiver.

An upward center ray rejects buried candidate floors and low overhead geometry.
This is not a pawn capsule test, nor an automatic choice between valid layers.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--map', default='split')
    parser.add_argument('--audited-effect-exclusions', type=Path)
    args = parser.parse_args()
    r, out, name = args.revision, args.output, args.map
    out.mkdir(parents=True, exist_ok=False)
    candidate_path = r / 'all-map-nav-source-floor-candidates-v1' / f'{name}.floor-candidates.npz'
    with np.load(candidate_path) as data:
        samples, sample_ids, heights = data['samples'], data['sampleIds'], data['sourceHeights']
        support_ids, pack_faces = data['supportIds'], data['fullHeightPackFaces']
    wp = r / 'display-warps-v1' / f'{name}.display-warp.json.gz'
    w = json.loads(gzip.decompress(wp.read_bytes()))
    matrix = np.column_stack([w['projection']['axisU'], w['projection']['axisV']])
    origin = np.array(w['projection']['origin'])
    before = np.array(w['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    target = np.array(w['targetAttackSvg']).reshape(-1, 2)
    warp = explicit_warp(before, target-before, np.array(w['triangles']).reshape(-1, 3))
    displayed = warp.apply(samples[:, :2] @ matrix.T + origin)
    svg_path = Path(__file__).resolve().parents[1] / 'assets/maps' / f'{name}_map.svg'
    inside = shapely.covers(receiver_domain(svg_path), shapely.points(displayed))
    pack = r / 'full-height-input-v1' / name / f'{name}.height.bin.gz'
    library = r / 'native-tactical-rays-build/Release/tactical_reference_cast.dll'
    model = NativeReferenceModel(pack, library)
    excluded = []
    exclusion_evidence = None
    if args.audited_effect_exclusions:
        exclusion_evidence = json.loads(args.audited_effect_exclusions.read_bytes())
        if exclusion_evidence['map'] != name or exclusion_evidence['fullHeightSourcePackSha256'] != sha(pack):
            raise ValueError('Effect exclusions belong to another source pack')
        for item in exclusion_evidence['evidence']:
            if sha(Path(item['path'])) != item['sha256']:
                raise ValueError('Audited effect source evidence changed')
        excluded = sorted({face for row in exclusion_evidence['rows']
                           if row.get('visibilityDecision') == 'exclude-from-structural-occlusion'
                           for face in row['fullPackFaceIds']})
    status = np.full(len(heights), -1, dtype=np.int8)
    hit_faces = np.full(len(heights), -1, dtype=np.int64)
    hit_z = np.full(len(heights), np.nan)
    cache = {}
    for i in np.flatnonzero(inside[sample_ids]):
        sid, z = int(sample_ids[i]), float(heights[i])
        key = (sid, z)
        if key not in cache:
            feet = np.r_[samples[sid, :2], z]
            cache[key] = model.cast(feet+[0, 0, .0001], feet+[0, 0, 1.75], excluded_faces=excluded)
        hit = cache[key]
        status[i] = 1 if hit is None else 0
        if hit:
            hit_faces[i], hit_z[i] = hit['face'], hit['point'][2]
    valid = status == 1
    count = np.bincount(sample_ids, minlength=len(samples))
    clear_count = np.bincount(sample_ids[valid], minlength=len(samples))
    low, high = np.full(len(samples), np.inf), np.full(len(samples), -np.inf)
    np.minimum.at(low, sample_ids[valid], heights[valid])
    np.maximum.at(high, sample_ids[valid], heights[valid])
    spread = np.zeros(len(samples)); some = clear_count > 0
    spread[some] = high[some]-low[some]
    output = out / 'candidate-columns.npz'
    np.savez_compressed(output, samples=samples, displayedSvg=displayed, insideSvg=inside,
        sampleIds=sample_ids, sourceHeights=heights, supportIds=support_ids,
        fullHeightPackFaces=pack_faces, centerColumnClear=status,
        hitFullHeightPackFaces=hit_faces, hitHeight=hit_z,
        clearMinimumHeight=low, clearMaximumHeight=high)
    report = dict(scope=__doc__, map=name, offeredSamples=len(samples), insideSvgSamples=int(inside.sum()),
        samplesOutsideSvg=int((~inside).sum()), centerRayCount=len(cache),
        insideWithoutNearbySource=int((inside & (count == 0)).sum()),
        insideWithCandidatesButAllColumnsBlocked=int((inside & (count > 0) & (clear_count == 0)).sum()),
        insideWithClearCandidate=int((inside & some).sum()),
        insideWithClearHeightSpreadAbove1mm=int((inside & (spread > .001)).sum()),
        maximumClearHeightSpreadMeters=float(spread.max()),
        inputSha256=sha(candidate_path), displayWarpSha256=sha(wp), svgSha256=sha(svg_path),
        sourcePackSha256=sha(pack), casterSha256=sha(library), outputSha256=sha(output),
        pythonCasterSha256=sha(Path(__file__).with_name('native_reference_cast.py')),
        excludedEffectFullPackFaces=excluded,
        effectExclusionEvidenceSha256=sha(args.audited_effect_exclusions) if exclusion_evidence else None,
        scriptSha256=sha(Path(__file__)), sourceGeometryChanged=False, productionPromotion=False,
        limitations=['Ray begins 0.1 mm above the proposed floor and ends at standing head height 1.75 m.',
            'Only the center column is checked. Headroom around a full pawn remains unverified.',
            'A clear column does not certify source collision or walkability.',
            'Source-height window remains the provisional 15 cm band around original native navigation.',
            'SVG membership limits destinations only. It does not classify obstacles or forbid crossing gaps.'])
    (out/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: v for k, v in report.items() if k not in ['scope', 'limitations']}), flush=True)


if __name__ == '__main__':
    main()
