"""Native-pixel corner comparisons, with diagnostic labels and bound inputs."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def run(before, after, fixtures, before_label='V7 diagnostic', after_label='V9 diagnostic', transitions_only=False):
    manifests = [json.loads((p / 'manifest.json').read_text()) for p in (before, after)]
    warp = json.loads(gzip.decompress(Path(manifests[1]['displayWarpFile']).read_bytes()))
    cases = {x['id']: x for x in json.loads(fixtures.read_text())['cases']}
    old = {(x['id'], x['side']): x for x in manifests[0]['cases']}
    records = []
    font = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 14)
    for row in manifests[1]['cases']:
        if transitions_only and not row['id'].endswith('transition'):
            continue
        prior = old[row['id'], row['side']]
        assert row['query'] == prior['query'], 'Physical query must remain frozen'
        assert row['svgSha256'] == prior['svgSha256']
        target = np.array(cases[row['id']]['targetSvg'])
        if row['side'] == 'defense':
            target = np.array(warp['attackToDefenseSvg']['origin']) - target
        center = np.floor(target * 8).astype(int)
        box = [int(center[0]-112), int(center[1]-88), int(center[0]+112), int(center[1]+88)]
        image = Image.new('RGB', (496, 280), '#18181c')
        sources = []
        for index, folder in enumerate((before, after)):
            path = folder / f"{row['side']}-{row['id']}-8x-overlay.png"
            image.paste(Image.open(path).convert('RGB').crop(box), (16 + 240*index, 65))
            sources.append(dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        draw = ImageDraw.Draw(image)
        draw.text((16, 8), f"{row['id']} | {row['side']} | native 8 px/SVG", font=font, fill='white')
        draw.text((16, 37), before_label, font=font, fill='white')
        draw.text((256, 37), after_label, font=font, fill='white')
        draw.text((16, 246), 'Corner and adjacent return review pending. No resampling.', font=font, fill='#ffcc82')
        path = after / f"{row['side']}-{row['id']}-corner-native8x.png"
        image.save(path)
        records.append(dict(id=row['id'], side=row['side'], targetSvg=target.tolist(), cropPixels=box,
                            sources=sources, image=str(path), imageSha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                            sourceQuery=row['query']))
    (after / 'corner-comparisons.json').write_text(json.dumps(dict(scope=__doc__, records=records), indent=2))
    print(f'Wrote {len(records)} native corner comparisons')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('fixtures', type=Path)
    parser.add_argument('--before-label', default='V7 diagnostic')
    parser.add_argument('--after-label', default='V9 diagnostic')
    parser.add_argument('--transitions-only', action='store_true')
    args = parser.parse_args()
    run(args.before, args.after, args.fixtures, args.before_label, args.after_label, args.transitions_only)
