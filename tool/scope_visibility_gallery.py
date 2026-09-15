"""Make visibly scoped copies of a local-chart gallery; retain all raw images."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


def scope(folder, projection_file, bounds):
    fixture = json.loads(projection_file.read_text())
    projection = np.array(fixture['projection']['nativeToSvg'])
    x0, y0, x1, y1 = bounds
    points = np.array([[x0, y0, 1], [x1, y0, 1], [x1, y1, 1], [x0, y1, 1]]) @ projection.T
    manifest_file = folder / 'manifest.json'
    manifest = json.loads(manifest_file.read_text())
    for case in manifest['cases']:
        for state in ['before', 'after']:
            if not case[state]:
                continue
            original = Path(case.get(f'{state}Unscoped', case[state]))
            image = Image.open(original).convert('RGB')
            projected = points.copy() * manifest['physicalPixelsPerSvgUnit']
            if case['side'] == 'defense':
                projected = np.array([image.width, image.height]) - projected
            polygon = [tuple(p) for p in projected]
            mask = Image.new('L', image.size)
            ImageDraw.Draw(mask).polygon(polygon, fill=255)
            dimmed = Image.blend(image, Image.new('RGB', image.size, '#08080d'), .88)
            scoped = Image.composite(image, dimmed, mask)
            ImageDraw.Draw(scoped).polygon(polygon, outline='#eaa0dc', width=2)
            overlay = original.with_name(original.name.replace('-overlay.png', '-local-overlay.png'))
            scoped.save(overlay)
            visibility = Image.open(str(original).replace('-overlay.png', '-visibility.png')).convert('RGBA')
            clipped = Image.new('RGBA', image.size)
            clipped.paste(visibility, mask=mask)
            clipped.save(str(overlay).replace('-overlay.png', '-visibility.png'))
            case[f'{state}Unscoped'] = str(original)
            case[state] = str(overlay)
        case['scopeLabel'] = 'Local chart only; pink outline is the tested region'
        case['scopeNativeXY'] = bounds
        case['category'] = 'Local chart only; outside outline is unverified'
    manifest['scope'] = 'Local native XY rectangle only. Unscoped raw images retained for diagnostics; their extrapolated regions are not certified.'
    manifest_file.write_text(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('projection_fixture', type=Path)
    parser.add_argument('bounds', type=float, nargs=4)
    args = parser.parse_args()
    scope(args.folder, args.projection_fixture, args.bounds)
