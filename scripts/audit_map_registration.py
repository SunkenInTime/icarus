"""Register native map icons to unchanged SVG fill contours independently of rays."""
import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

import contourpy
import numpy as np
from PIL import Image
from scipy.optimize import least_squares
from scipy.spatial import cKDTree
from shapely import LineString
from svgpathtools import Line, parse_path

QUARTER_TURNS = {'abyss': 1, 'ascent': 1, 'corrode': 1, 'haven': 1, 'icebox': 3, 'split': 1}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rotate(points, turns, size=1024):
    points = np.asarray(points).copy()
    for _ in range(turns % 4):
        points = np.column_stack((size - points[:, 1], points[:, 0]))
    return points


def svg_contours(path):
    root = ET.parse(path).getroot()
    candidates = []
    for element in root.iter():
        # The broad gold paths are outlined strokes converted to filled shapes.
        # Use Icarus's actual dark floor fill, not those wider stroke outlines.
        if element.tag.endswith('path') and element.get('fill', '').lower() == '#271406':
            p = parse_path(element.get('d'))
            box = p.bbox()
            candidates.append(((box[1] - box[0]) * (box[3] - box[2]), p))
    shape = max(candidates, key=lambda p: p[0])[1]
    samples, corners = [], []
    paths = []
    for sub in shape.continuous_subpaths():
        points = []
        for index, segment in enumerate(sub):
            length = segment.length(error=1e-6)
            points.extend(segment.point(t) for t in np.linspace(0, 1, max(2, int(length / .6)), endpoint=False))
            previous = sub[index - 1]
            if isinstance(previous, Line) and isinstance(segment, Line) and previous.length() >= 6 and length >= 6:
                a, b = previous.unit_tangent(1), segment.unit_tangent(0)
                cosine = (a.real * b.real + a.imag * b.imag)
                if abs(cosine) < .8:
                    corners.append((segment.start.real, segment.start.imag))
        xy = np.array([(p.real, p.imag) for p in points])
        samples.extend(xy)
        paths.append(xy)
    return np.asarray(samples), np.asarray(corners), paths, [float(v) for v in root.get('viewBox').split()]


def icon_contours(path, turns):
    image = Image.open(path).convert('RGBA')
    pixels = np.asarray(image)
    if image.size != (1024, 1024):
        raise ValueError('Unexpected native icon frame')
    contours = contourpy.contour_generator(z=pixels[:, :, 3] / 255).lines(.5)
    paths = [rotate(line + .5, turns) for line in contours if len(line) >= 8]
    points = np.concatenate(paths)
    corners = []
    for line in paths:
        simplified = np.asarray(LineString(line).simplify(1.1).coords)
        if np.linalg.norm(simplified[0] - simplified[-1]) < 1e-7:
            simplified = simplified[:-1]
        for i in range(len(simplified)):
            a, b = simplified[i] - simplified[i - 1], simplified[(i + 1) % len(simplified)] - simplified[i]
            if np.linalg.norm(a) < 2 or np.linalg.norm(b) < 2:
                continue
            cosine = np.dot(a, b) / np.linalg.norm(a) / np.linalg.norm(b)
            if abs(cosine) < .95:
                corners.append(simplified[i])
    return points, np.asarray(corners), paths


def select_landmarks(corners, count=18):
    # Choose distributed vector corners without using the native icon fit.
    first = int(np.argmin(corners[:, 0] + corners[:, 1]))
    selected = [first]
    for _ in range(min(count, len(corners)) - 1):
        distance = np.linalg.norm(corners[:, None] - corners[selected][None], axis=2).min(axis=1)
        selected.append(int(np.argmax(distance)))
    return corners[selected]


def fit(svg, native, landmarks, anisotropic=False):
    initial_scale = np.mean((svg.max(axis=0) - svg.min(axis=0)) /
                            (native.max(axis=0) - native.min(axis=0)))
    initial_offset = (svg.max(axis=0) + svg.min(axis=0) -
                      initial_scale * (native.max(axis=0) + native.min(axis=0))) / 2
    # Exclude complete neighborhoods of held-out corners from the fit.
    training = svg[cKDTree(landmarks).query(svg)[0] > 10]
    tree = cKDTree(native)

    def decode(values):
        return (values[:2], values[2:]) if anisotropic else (np.repeat(values[0], 2), values[1:])

    def residual(values):
        scale, offset = decode(values)
        prediction = (training - offset) / scale
        _, ids = tree.query(prediction)
        return ((native[ids] * scale + offset) - training).ravel()

    initial = [initial_scale, initial_scale, *initial_offset] if anisotropic else [initial_scale, *initial_offset]
    result = least_squares(residual, initial, loss='soft_l1', f_scale=.35,
                           max_nfev=200, xtol=1e-11, ftol=1e-11, gtol=1e-11)
    scale, offset = decode(result.x)
    distances = np.linalg.norm(residual(result.x).reshape(-1, 2), axis=1)
    return scale, offset, {'trainingSamples': len(training),
                           'trainingMedianSvg': float(np.median(distances)),
                           'trainingP95Svg': float(np.percentile(distances, 95))}


def audit(name, icon_root, svg_root, world_root, output):
    native, native_corners, native_paths = icon_contours(icon_root / f'{name}.png', QUARTER_TURNS.get(name, 0))
    svg_file = svg_root / f'{name}_map.svg'
    svg, svg_corners, svg_paths, viewbox = svg_contours(svg_file)
    heldout = select_landmarks(svg_corners)
    records = {}
    for kind in ['uniform', 'axis']:
        scale, offset, training = fit(svg, native, heldout, anisotropic=kind == 'axis')
        distances, ids = cKDTree(native_corners * scale + offset).query(heldout)
        landmarks = [{'svg': target.tolist(), 'nativeRotatedPx': native_corners[index].tolist(),
                      'predictedSvg': (native_corners[index] * scale + offset).tolist(),
                      'errorSvg': float(error)} for target, index, error in zip(heldout, ids, distances)]
        records[kind] = {'scaleSvgPerNativePixel': scale.tolist(), 'translationSvg': offset.tolist(),
                         **training, 'heldOutRmsSvg': float(np.sqrt(np.mean(distances ** 2))),
                         'heldOutMaxSvg': float(distances.max()), 'landmarks': landmarks}
    api = next(m for m in json.loads((icon_root / 'api-maps.json').read_text())['data']
               if m['displayName'].lower() == name)
    world = json.loads((world_root / name / 'geometry.json').read_text())
    ui_matches = all(abs(api[k[0].lower() + k[1:]] - v) < 1e-12
                     for k, v in world['uiTransform'].items())
    if not ui_matches:
        raise ValueError(f'Native extracted UIData disagrees with API icon transform for {name}')
    report = {'map': name, 'iconSha256': digest(icon_root / f'{name}.png'),
              'svgSha256': digest(svg_file), 'quarterTurns': QUARTER_TURNS.get(name, 0),
              'viewBox': viewbox, 'uiDataMatchesExtracted': ui_matches, 'fits': records,
              'heldoutPolicy': '18 distributed SVG corners; all contour samples within10 SVG units excluded from fit.'}
    output.mkdir(parents=True, exist_ok=True)
    (output / f'{name}-registration.json').write_text(json.dumps(report, indent=2))
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(1, 2, figsize=(13, 7), layout='constrained')
    for ax, kind in zip(axes, ['uniform', 'axis']):
        result = records[kind]
        scale, offset = np.asarray(result['scaleSvgPerNativePixel']), np.asarray(result['translationSvg'])
        for line in svg_paths:
            ax.plot(line[:, 0], line[:, 1], color='#995a14', linewidth=1.3)
        for line in native_paths:
            transformed = line * scale + offset
            ax.plot(transformed[:, 0], transformed[:, 1], color='#067da1', linewidth=.65, alpha=.8)
        for index, item in enumerate(result['landmarks']):
            ax.plot(*item['svg'], 'o', color='#cc3355', markersize=3)
            ax.plot(*item['predictedSvg'], '+', color='#174f9e', markersize=5)
            ax.annotate(str(index + 1), item['svg'], xytext=(4, 4), textcoords='offset points', fontsize=7)
        ax.set_aspect('equal')
        ax.set_xlim(-8, viewbox[2] + 8)
        ax.set_ylim(viewbox[3] + 8, -8)
        ax.set_title(f'{kind} fit: held-out RMS {result["heldOutRmsSvg"]:.3f} SVG units\n'
                     f'max {result["heldOutMaxSvg"]:.3f}; orange SVG, cyan native icon')
    fig.suptitle(f'{name.title()} independent native-icon registration', fontsize=17)
    fig.savefig(output / f'{name}-registration.png', dpi=170)
    plt.close(fig)
    print(json.dumps({'map': name, **{k: {a: b for a, b in v.items() if a != 'landmarks'}
                                     for k, v in records.items()}}), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--icon-root', type=Path, required=True)
    parser.add_argument('--svg-root', type=Path, default=Path('assets/maps'))
    parser.add_argument('--world-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--maps', nargs='+', required=True)
    args = parser.parse_args()
    for name in args.maps:
        audit(name, args.icon_root, args.svg_root, args.world_root, args.output)


if __name__ == '__main__':
    main()
