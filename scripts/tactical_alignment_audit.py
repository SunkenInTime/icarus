"""Diagnose native structural wall registration against unchanged SVG contours.

This writes diagnostics and a candidate transform, never changes runtime data.
Nearest matches are evidence candidates, not permission to turn SVG edges into walls.
"""
import argparse
import gzip
import json
from pathlib import Path
import struct

import numpy as np
from scipy.optimize import least_squares
from scipy.spatial import cKDTree
from svgpathtools import Line
from audit_map_registration import svg_contours, QUARTER_TURNS


def pack(path):
    raw = gzip.decompress(path.read_bytes())
    magic, size = struct.unpack_from('<4sI', raw)
    assert magic == b'IHD1'
    header = json.loads(raw[8:8 + size])
    base = (8 + size + 7) // 8 * 8
    arrays = {name: np.frombuffer(raw, dtype={'float64': '<f8', 'uint32': '<u4', 'int32': '<i4'}[item['dtype']],
                                count=item['count'], offset=base + item['offset']).reshape(item['shape'])
              for name, item in header['arrays'].items()}
    return header, arrays


def projection(meta, registration):
    ui = meta['uiTransform']
    fit = registration['fits']['uniform']
    scale, shift = np.array(fit['scaleSvgPerNativePixel']), np.array(fit['translationSvg'])
    def project(points):
        points = np.asarray(points)
        uv = np.stack((ui['XScalarToAdd'] - points[..., 1] * 100 * ui['XMultiplier'],
                       ui['YScalarToAdd'] + points[..., 0] * 100 * ui['YMultiplier']), axis=-1)
        for _ in range(registration['quarterTurns']):
            uv = np.stack((1 - uv[..., 1], uv[..., 0]), axis=-1)
        return uv * 1024 * scale + shift
    return project


def section(arrays, height, vertical_only=True):
    vertices, faces = arrays['vertices'], arrays['faces']
    z = vertices[faces, 2]
    ids = np.flatnonzero((z.min(1) <= height) & (z.max(1) > height) & (arrays['faceMasks'] == -1))
    xyz = vertices[faces[ids]]
    normal = np.cross(xyz[:, 1] - xyz[:, 0], xyz[:, 2] - xyz[:, 0])
    vertical = np.abs(normal[:, 2]) <= .025 * np.linalg.norm(normal, axis=1) if vertical_only else np.ones(len(xyz), dtype=bool)
    xyz, ids = xyz[vertical], ids[vertical]
    output = np.zeros((len(ids), 2, 2))
    count = np.zeros(len(ids), dtype=int)
    for edge in range(3):
        a, b = xyz[:, edge], xyz[:, (edge + 1) % 3]
        admitted = ((a[:, 2] <= height) & (b[:, 2] > height)) | ((b[:, 2] <= height) & (a[:, 2] > height))
        rows = np.flatnonzero(admitted)
        t = (height - a[rows, 2]) / (b[rows, 2] - a[rows, 2])
        output[rows, count[rows]] = a[rows, :2] + t[:, None] * (b[rows, :2] - a[rows, :2])
        count[rows] += 1
    return output[count == 2], ids[count == 2]


def first_hit(origin, target, lines):
    direction = target - origin
    direction = direction / np.linalg.norm(direction)
    segment = lines[:, 1] - lines[:, 0]
    delta = lines[:, 0] - origin
    determinant = direction[0] * segment[:, 1] - direction[1] * segment[:, 0]
    nonparallel = np.abs(determinant) > 1e-10
    distance = np.full(len(lines), np.inf)
    along = np.zeros(len(lines))
    distance[nonparallel] = (delta[nonparallel, 0] * segment[nonparallel, 1] - delta[nonparallel, 1] * segment[nonparallel, 0]) / determinant[nonparallel]
    along[nonparallel] = (delta[nonparallel, 0] * direction[1] - delta[nonparallel, 1] * direction[0]) / determinant[nonparallel]
    admitted = nonparallel & (distance > 1e-6) & (along >= 0) & (along <= 1)
    distance[~admitted] = np.inf
    index = int(np.argmin(distance))
    hit = origin + direction * distance[index] if np.isfinite(distance[index]) else np.full(2, np.nan)
    return index, float(distance[index]), hit


def vector_lines(svg):
    import xml.etree.ElementTree as ET
    from svgpathtools import parse_path
    lines = []
    for element in ET.parse(svg).getroot().iter():
        if element.tag.endswith('path') and element.get('fill', '').lower() == '#271406':
            for segment in parse_path(element.get('d')):
                if isinstance(segment, Line) and segment.length() >= 2:
                    lines.append([[segment.start.real, segment.start.imag], [segment.end.real, segment.end.imag]])
    return np.array(lines)


def closest(point, lines):
    a, delta = lines[:, 0], lines[:, 1] - lines[:, 0]
    t = np.clip(np.sum((point - a) * delta, axis=1) / np.sum(delta * delta, axis=1), 0, 1)
    positions = a + delta * t[:, None]
    dist = np.linalg.norm(positions - point, axis=1)
    return dist, positions


def candidate_matches(native, svg):
    lengths = np.linalg.norm(native[:, 1] - native[:, 0], axis=1)
    native = native[lengths >= 2]
    # Keep one record per projected segment to avoid duplicate source faces weighting fits.
    _, unique = np.unique(np.round(native.reshape(-1, 4), 4), axis=0, return_index=True)
    native = native[unique]
    targets = []
    for index, line in enumerate(native):
        midpoint = line.mean(0)
        distances, positions = closest(midpoint, svg)
        direction = line[1] - line[0]
        svg_directions = svg[:, 1] - svg[:, 0]
        sine = np.abs(direction[0] * svg_directions[:, 1] - direction[1] * svg_directions[:, 0]) / (np.linalg.norm(direction) * np.linalg.norm(svg_directions, axis=1))
        candidates = np.flatnonzero((distances <= 2) & (sine < np.sin(np.deg2rad(1))))
        if len(candidates) == 0:
            continue
        chosen = candidates[np.argmin(distances[candidates])]
        # Entire support must overlap, so corner-adjacent and crossing walls do not qualify.
        target = svg[chosen]
        axis = (target[1] - target[0]) / np.linalg.norm(target[1] - target[0])
        along = (line - target[0]) @ axis
        if along.min() < -.1 or along.max() > np.linalg.norm(target[1] - target[0]) + .1:
            continue
        targets.append((index, chosen))
    return native, np.array(targets, dtype=int).reshape(-1, 2)


def summary(distances):
    return {'count': len(distances), 'medianSvg': float(np.median(distances)), 'p95Svg': float(np.percentile(distances, 95)), 'rmsSvg': float(np.sqrt(np.mean(distances ** 2))), 'maxSvg': float(np.max(distances))}


def audit(name, root, output, catalog):
    folder = root / 'compact-prototype/all-map-height-scoped-v2' / name
    header, arrays = pack(Path('assets/maps/world') / catalog[name]['pack'])
    registration = json.loads((root / f'registration/results/{name}-registration.json').read_text())
    project = projection(catalog[name], registration)
    svg_file = Path(f'assets/maps/{name}_map.svg')
    svg = vector_lines(svg_file)
    observer = catalog[name]['observerHeightCm'] / 100
    default_height = catalog[name]['defaultFloorElevationCm'] / 100 + observer
    heights = [default_height]
    fixture = None
    if name == 'split':
        fixture = json.loads((root / 'compact-prototype/native-walking-fixtures-v1/split/walking-144hz.json').read_text())
        heights = [fixture['frames'][0]['poses'][i][2] for i in [8, 4, 6]]
    native_sets, diagnostics = [], []
    for height in heights:
        native, ids = section(arrays, height)
        projected = project(native)
        native_sets.append(projected)
        diagnostics.append({'heightMeters': height, 'solidVerticalSections': len(ids)})
    native, matches = candidate_matches(np.concatenate(native_sets), svg)
    mids = native[matches[:, 0]].mean(axis=1)
    targets = svg[matches[:, 1]]
    directions = targets[:, 1] - targets[:, 0]
    normals = np.column_stack((-directions[:, 1], directions[:, 0])) / np.linalg.norm(directions, axis=1)[:, None]
    # Spatial checkerboard split does not reuse every nearby piece as a held-out example.
    heldout = ((np.floor(mids[:, 0] / 30) + np.floor(mids[:, 1] / 30)).astype(int) % 3) == 0
    def residual(values):
        transformed = mids * np.array(values[:2]) + values[2:]
        return np.sum((transformed - targets[:, 0]) * normals, axis=1)
    fit = least_squares(lambda values: residual(values)[~heldout], [1, 1, 0, 0], bounds=([.99, .99, -2, -2], [1.01, 1.01, 2, 2]), loss='soft_l1', f_scale=.25)
    before, after = np.abs(residual([1, 1, 0, 0])), np.abs(residual(fit.x))
    report = {'map': name, 'heights': diagnostics,
              'priorRasterRegistration': {'rmsSvg': registration['fits']['uniform']['heldOutRmsSvg'], 'maxSvg': registration['fits']['uniform']['heldOutMaxSvg']},
              'candidatePolicy': 'solid near-vertical triangle sections only; length>=2SVG; parallel<1deg; distance<=2SVG; complete projected support overlap; diagnostics only, no semantic match guarantee',
              'candidateAxisTransform': {'scale': fit.x[:2].tolist(), 'translationSvg': fit.x[2:].tolist(), 'adopted': False},
              'trainingBefore': summary(before[~heldout]), 'trainingAfter': summary(after[~heldout]),
              'heldoutBefore': summary(before[heldout]), 'heldoutAfter': summary(after[heldout])}
    output.mkdir(parents=True, exist_ok=True)
    if name == 'split':
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        from matplotlib.collections import LineCollection
        areas = [('top-corridor', 8, [240, 315, 73, 106]), ('clove-left-and-upper-edges', 4, [176, 253, 195, 270]), ('iso-lower-geometry', 6, [293, 363, 225, 270])]
        fig, axes = plt.subplots(1, 3, figsize=(16, 6), layout='constrained')
        source_ids = np.load(folder / 'source-correspondence.npz')['sourceFaces']
        selector = {s['map']: s for s in json.loads((root / 'completeness/combined-manifest-release-inputs-v2.json').read_text())}
        metadata = json.loads((Path(selector[name]['combinedWorldFolder']) / 'geometry.json').read_text())
        objects = metadata['objects']
        starts = np.array([o['firstFace'] for o in objects])
        annotated = []
        for ax, (label, query, region), height in zip(axes, areas, heights):
            native, ids = section(arrays, height)
            projected = project(native)
            xmin, xmax, ymin, ymax = region
            in_area = (projected.max(1)[:, 0] >= xmin) & (projected.min(1)[:, 0] <= xmax) & (projected.max(1)[:, 1] >= ymin) & (projected.min(1)[:, 1] <= ymax)
            ax.add_collection(LineCollection(svg, colors='#cf9144', linewidths=2))
            ax.add_collection(LineCollection(projected[in_area], colors='#28a4bc', linewidths=.65, alpha=.7))
            origin = fixture['frames'][0]['positionsSvg'][query]
            ax.plot(*origin, 'o', color='#cc3366', markersize=5)
            ax.set(xlim=(xmin, xmax), ylim=(ymax, ymin), title=f'{label}\nstanding Z {height:.3f}m')
            ax.set_aspect('equal')
            object_ids, counts = np.unique(np.searchsorted(starts, source_ids[ids[in_area]], side='right') - 1, return_counts=True)
            annotated.append({'label': label, 'query': query, 'heightMeters': height, 'originSvg': origin,
                              'objectsInRegion': [{'path': objects[int(i)]['path'], 'sections': int(count)} for i, count in sorted(zip(object_ids, counts), key=lambda item: -item[1])[:20]]})
        report['annotatedRegions'] = annotated
        marked_rays = []
        for label, query, target in [('top-gap', 8, [263, 84]), ('clove-left', 4, [195.7, 223.4]), ('clove-upper', 4, [225.5, 211]), ('iso-phantom', 6, [329, 264])]:
            height = fixture['frames'][0]['poses'][query][2]
            native, ids = section(arrays, height, vertical_only=False)
            projected = project(native)
            origin = np.array(fixture['frames'][0]['positionsSvg'][query])
            index, distance, hit = first_hit(origin, np.array(target), projected)
            _, svg_distance, svg_hit = first_hit(origin, np.array(target), svg)
            source_face = int(source_ids[ids[index]])
            obj = objects[int(np.searchsorted(starts, source_face, side='right') - 1)]
            triangle = arrays['vertices'][arrays['faces'][ids[index]]]
            normal = np.cross(triangle[1] - triangle[0], triangle[2] - triangle[0])
            marked_rays.append({'label': label, 'query': query, 'targetSvgApproximateFromAnnotation': target,
                'originSvgExactFixture': origin.tolist(), 'heightMeters': height,
                'solidSourceFirstHitSvg': hit.tolist(), 'svgFirstContourCrossing': svg_hit.tolist(),
                'sourceDistanceSvg': distance, 'svgContourDistance': svg_distance,
                'sourceMinusSvgDistance': distance - svg_distance, 'sourceFace': source_face,
                'sourceObject': obj['path'], 'sourceTriangleNativeMeters': triangle.tolist(),
                'normalZFraction': float(abs(normal[2]) / np.linalg.norm(normal)),
                'limitation': 'Solid-source diagnostics. Masked sections skipped; annotation target read approximately; first SVG crossing is diagnostic, not assumed opaque.'})
        report['markedRayDiagnostics'] = marked_rays
        fig.suptitle('Split: orange unchanged SVG contour; cyan exact solid near-vertical source wall sections', fontsize=13)
        fig.savefig(output / 'split-native-svg-edges.png', dpi=180)
        plt.close(fig)
    (output / f'{name}.json').write_text(json.dumps(report, indent=2))
    print(json.dumps({'map': name, 'matches': len(matches), 'heldoutBefore': report['heldoutBefore'], 'heldoutAfter': report['heldoutAfter'], 'transform': report['candidateAxisTransform']}), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--maps', nargs='+', default=['split'])
    args = parser.parse_args()
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']
    reports = [audit(name, args.audit_root, args.output, catalog) for name in args.maps]
    (args.output / 'summary.json').write_text(json.dumps(reports, indent=2))


if __name__ == '__main__':
    main()
