"""Find conservative structural facade correspondences for visual review on all maps.

No correspondence is accepted solely because it is the nearest parallel line.
Candidate evidence includes source object identity, repeated height support,
plane coherence, continuous overlap, and the independently authored/walkable side.
"""
import argparse
import gzip
import json
import re
from collections import defaultdict
from pathlib import Path

import numpy as np
from shapely import Polygon, Point, union_all

from audit_map_registration import svg_contours
from tactical_alignment_audit import pack, projection, section, vector_lines, closest
from tactical_alignment_receiver import receiver_domain


def merged_length(intervals):
    end, total = -np.inf, 0.
    for a, b in sorted(intervals):
        total += max(0., b - max(a, end))
        end = max(end, b)
    return total


def audit(name, root, output):
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps'][name]
    registration = json.loads((root / f'registration/results/{name}-registration.json').read_text())
    project = projection(catalog, registration)
    meta = json.loads((root / f'supplemented-v2/world/{name}/geometry.json').read_text())
    objects = meta['objects']
    starts = np.array([o['firstFace'] for o in objects])
    source_faces = np.load(root / f'compact-prototype/all-map-height-scoped-v2/{name}/source-correspondence.npz')['sourceFaces']
    _, arrays = pack(Path(f'assets/maps/world/{name}.height.bin.gz'))
    svg_file = Path(f'assets/maps/{name}_map.svg')
    lines = vector_lines(svg_file)
    lengths = np.linalg.norm(lines[:, 1] - lines[:, 0], axis=1)
    axes = (lines[:, 1] - lines[:, 0]) / lengths[:, None]
    normals = np.column_stack((-axes[:, 1], axes[:, 0]))
    _, _, paths, box = svg_contours(svg_file)
    svg_domain = receiver_domain(svg_file)
    nav = json.loads(gzip.decompress(Path(f'assets/maps/world/{name}_navigation.json.gz').read_bytes()))
    uv = np.array(nav['vertices']).reshape(-1, 3)[:, :2] / nav['coordinateScale']
    ui = catalog['uiTransform']
    native = np.column_stack(((uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier']),
                              -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])))
    nxy = project(native)
    nav_domain = union_all([Polygon(nxy[p]) for p, walkable in zip(nav['polygons'], nav['walkable']) if walkable])
    heights = [h['heightMeters'] for h in json.loads((root / f'tactical-alignment-v1/{name}.json').read_text())['heights']]
    if len(heights) == 1:
        heights = [heights[0] - .5, heights[0], heights[0] + .5]
    groups = defaultdict(list)
    for level, height in enumerate(heights):
        segments, face_ids = section(arrays, height)
        segments = project(segments)
        seg_lengths = np.linalg.norm(segments[:, 1] - segments[:, 0], axis=1)
        good = seg_lengths >= .5
        segments, face_ids, seg_lengths = segments[good], face_ids[good], seg_lengths[good]
        object_ids = np.searchsorted(starts, source_faces[face_ids], side='right') - 1
        for segment, face, object_id, length in zip(segments, face_ids, object_ids, seg_lengths):
            path = objects[object_id]['path']
            if not re.search('wall|building', path, re.I) or re.search('floor|stair|ramp|foliage|fence|grate|door|glass|window', path, re.I):
                continue
            direction = (segment[1] - segment[0]) / length
            sine = np.abs(direction[0] * axes[:, 1] - direction[1] * axes[:, 0])
            midpoint = segment.mean(0)
            distances, _ = closest(midpoint, lines)
            candidates = np.flatnonzero((sine < np.sin(np.deg2rad(.25))) & (distances < 2) & (lengths >= 8))
            supports = []
            for line_id in candidates:
                along = (segment - lines[line_id, 0]) @ axes[line_id]
                lo, hi = max(0., min(along)), min(lengths[line_id], max(along))
                if hi - lo >= min(.5, length * .75):
                    supports.append((int(line_id), float(lo), float(hi)))
            # Multiple competing authored planes are explicitly ambiguous.
            if len(supports) != 1:
                continue
            line_id, lo, hi = supports[0]
            offset = float((midpoint - lines[line_id, 0]) @ normals[line_id])
            groups[(line_id, int(object_id))].append((level, lo, hi, offset, int(face)))
    records = []
    for (line_id, object_id), rows in groups.items():
        intervals = [(r[1], r[2]) for r in rows]
        coverage = merged_length(intervals)
        offsets = np.array([r[3] for r in rows])
        offset = float(np.median(offsets))
        spread = float(np.max(np.abs(offsets - offset)))
        levels = sorted(set(r[0] for r in rows))
        midpoint = lines[line_id].mean(0)
        normal = normals[line_id]
        art_sides = [svg_domain.contains(Point(midpoint + side * normal * .75)) for side in [-1, 1]]
        nav_sides = [nav_domain.contains(Point(midpoint + side * normal * 2)) for side in [-1, 1]]
        flags = []
        if len(levels) < 2: flags.append('single-height-support')
        if spread > .03: flags.append('multiple-source-planes-or-relief')
        if coverage / lengths[line_id] < .7: flags.append('partial-authored-edge-support')
        if coverage < 8: flags.append('short-support')
        if sum(art_sides) != 1: flags.append('authored-edge-side-ambiguous')
        if art_sides != nav_sides: flags.append('walkable-facing-side-unconfirmed')
        if abs(offset) < .02: flags.append('already-aligned-within0_02SVG')
        source_line = lines[line_id] + offset * normal
        inward = -1 if art_sides[0] else 1
        fixtures = []
        for fraction in [.2, .5, .8]:
            point = lines[line_id, 0] + fraction * (lines[line_id, 1] - lines[line_id, 0])
            fixtures.append({'originSvg': (point + inward * normal * 3).tolist(),
                             'targetSvg': (point - inward * normal * 3).tolist(),
                             'expectedRegisteredHitSvg': point.tolist(), 'heightMeters': heights[levels[0]]})
        records.append({'svgLineId': line_id, 'objectId': object_id, 'sourceObject': objects[object_id]['path'],
            'sourceLineSvg': source_line.tolist(), 'targetLineSvg': lines[line_id].tolist(),
            'displacementSvg': (-offset * normal).tolist(), 'maximumSourcePlaneDeviationSvg': spread,
            'supportLengthSvg': coverage, 'authoredEdgeLengthSvg': float(lengths[line_id]),
            'heightLevels': [heights[i] for i in levels], 'sourcePackedFaces': sorted(set(r[4] for r in rows)),
            'sourceSections': [{'heightMeters': heights[level], 'lineSvg': [
                (lines[line_id, 0] + lo * axes[line_id] + plane * normal).tolist(),
                (lines[line_id, 0] + hi * axes[line_id] + plane * normal).tolist()],
                'packedFace': face} for level, lo, hi, plane, face in rows],
            'flags': flags, 'eligibleForVisualReview': not flags, 'boundedFacadeFixtures': fixtures})
    records.sort(key=lambda r: (len(r['flags']), -r['supportLengthSvg']))
    report = {'map': name, 'adopted': False, 'policy': 'object-provenance + unique-parallel-support + repeated-height + coherent-plane + 70%-edge-overlap + matching-SVG/navigation-interior-side',
              'scope': 'Candidates for source/render review. Selection does not prove semantic correspondence or authorize an automatic warp.',
              'eligible': sum(r['eligibleForVisualReview'] for r in records), 'flagged': sum(bool(r['flags']) for r in records),
              'records': records}
    (output / f'{name}.json').write_text(json.dumps(report, indent=2))
    print(name, report['eligible'], report['flagged'], flush=True)
    return {k: v for k, v in report.items() if k != 'records'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    names = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']
    summary = [audit(name, args.audit_root, args.output) for name in names]
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
