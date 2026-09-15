"""Native-pixel diagnostic views of independently rendered ink and cone alpha."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def run(folder):
    report_bytes = (folder / 'contact-report.json').read_bytes()
    report = json.loads(report_bytes)
    font = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 16)
    small = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 13)
    outputs = []
    for row in report['rasterProfiles']:
        if row['scale'] != 8 or row['id'] not in ('ramp-1-forward', 'annotated-clove'):
            continue
        scale = row['scale']
        span = np.array(row['svgSpan'])
        y = span[0, 1] * scale
        bounds = (int(np.floor(span[:, 0].min() * scale)) - 8,
                  int(np.floor(y)) - 32,
                  int(np.ceil(span[:, 0].max() * scale)) + 8,
                  int(np.ceil(y)) + 33)
        ink_path = folder / f"{row['side']}-{scale}x-ink.png"
        cone_path = folder / f"{row['side']}-{row['id']}-{scale}x-visibility.png"
        ink = np.asarray(Image.open(ink_path).convert('RGBA').crop(bounds))[:, :, 3] / 255.
        cone = np.asarray(Image.open(cone_path).convert('RGBA').crop(bounds))[:, :, 3] / 255.
        ink_rgb = ink[:, :, None] * np.array([178, 124, 64])
        cone_rgb = cone[:, :, None] * np.array([0, 223, 186])
        combined = ink_rgb * (1 - cone[:, :, None]) + cone_rgb
        panels = [ink_rgb, cone_rgb, combined]
        width = max(260, ink.shape[1])
        canvas = Image.new('RGB', (3 * width + 64, ink.shape[0] + 132), '#18181c')
        draw = ImageDraw.Draw(canvas)
        draw.text((16, 8), f"{row['id']} | {row['side']} | native 8 physical px / SVG unit", font=font, fill='white')
        draw.text((16, 32), 'Diagnostic alpha layers. No resize, dilation, or inferred wall fill.', font=small, fill='#cccccc')
        sample = row['profiles'][len(row['profiles']) // 2]
        sample_x = sample['column'] - bounds[0]
        for index, (title, pixels) in enumerate(zip(['Actual authored wall ink', 'Rendered cone coverage', 'Ink + cone coverage'], panels)):
            x = 16 + index * (width + 16)
            draw.text((x, 58), title, font=small, fill='white')
            canvas.paste(Image.fromarray(np.rint(pixels).astype(np.uint8)), (x, 80))
            # Ticks outside the raster identify the measured column without
            # overwriting any source pixel in the contact band.
            draw.line((x + sample_x, 76, x + sample_x, 79), fill='#ff5263')
            draw.line((x + sample_x, 80 + ink.shape[0], x + sample_x, 84 + ink.shape[0]), fill='#ff5263')
        draw.text((16, 94 + ink.shape[0]),
                  f"Marked column {sample['column']}: {sample['blankPixels']} completely uncovered pixels between ink and cone. Crop {bounds}.",
                  font=small, fill='white')
        output = folder / f"{row['side']}-{row['id']}-native8x-contact.png"
        canvas.save(output)
        outputs.append(dict(file=str(output), cropPixels=list(bounds), measuredColumn=sample['column'],
                            blankPixels=sample['blankPixels'], sourceImageScale=8,
                            inkSha256=hashlib.sha256(ink_path.read_bytes()).hexdigest(),
                            coneSha256=hashlib.sha256(cone_path.read_bytes()).hexdigest(),
                            imageSha256=hashlib.sha256(output.read_bytes()).hexdigest()))
    (folder / 'contact-evidence-images.json').write_text(json.dumps(dict(reportSha256=hashlib.sha256(report_bytes).hexdigest(), images=outputs), indent=2) + '\n')
    print('\n'.join(o['file'] for o in outputs))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    run(parser.parse_args().folder)
