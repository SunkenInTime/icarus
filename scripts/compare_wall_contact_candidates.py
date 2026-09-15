"""Compare independently rasterized wall-contact candidates without resampling."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def combined(folder, row, box):
    ink_file = folder / f"{row['side']}-{row['scale']}x-ink.png"
    cone_file = folder / f"{row['side']}-{row['id']}-{row['scale']}x-visibility.png"
    ink = np.asarray(Image.open(ink_file).convert('RGBA').crop(box))[:, :, 3] / 255.
    cone = np.asarray(Image.open(cone_file).convert('RGBA').crop(box))[:, :, 3] / 255.
    rgb = ink[:, :, None] * np.array([178, 124, 64]) * (1 - cone[:, :, None]) + cone[:, :, None] * np.array([0, 223, 186])
    return Image.fromarray(np.rint(rgb).astype(np.uint8))


def run(baseline, candidate, before_label='Previous candidate', after_label='New candidate', output=None):
    output = candidate if output is None else output
    output.mkdir(parents=True, exist_ok=True)
    before_bytes = (baseline / 'contact-report.json').read_bytes()
    after_bytes = (candidate / 'contact-report.json').read_bytes()
    before, after = json.loads(before_bytes), json.loads(after_bytes)
    key = lambda row: (row['id'], row['side'], row['scale'])
    old = {key(row): row for row in before['rasterProfiles']}
    changes = []
    font = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 15)
    small = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 13)
    for row in after['rasterProfiles']:
        previous = old[key(row)]
        if row['inkSha256'] != previous['inkSha256']:
            raise ValueError('Authored ink changed; comparison requires its own review')
        fields = ('maximumBlankPixels', 'maximumHalfCoverageSeparationPixels',
                  'maximumCoverageDeficitPixels', 'profilesFailingCoverageContact',
                  'profilesWithDisplayedSpill', 'missingInkProfiles', 'missingConeProfiles',
                  'geometricFirstClearInwardSvgRange', 'requiresSeparateWallPlacementReview')
        changes.append(dict(id=row['id'], side=row['side'], scale=row['scale'],
                            before={f: previous.get(f) for f in fields},
                            after={f: row.get(f) for f in fields}))
        if row['scale'] != 8:
            continue
        span = np.array(row['svgSpan']) * 8
        along_axis = int(np.argmax(abs(span[1] - span[0])))
        margin = np.array([32, 32])
        margin[along_axis] = 8
        low = np.floor(span.min(axis=0)).astype(int) - margin
        high = np.ceil(span.max(axis=0)).astype(int) + margin + 1
        box = tuple(int(value) for value in [*low, *high])
        width = max(320, box[2] - box[0])
        height = box[3] - box[1]
        image = Image.new('RGB', (width * 2 + 48, height + 174), '#18181c')
        draw = ImageDraw.Draw(image)
        draw.text((16, 8), f"{row['id']} | {row['side']} | native 8 physical px / SVG unit", font=font, fill='white')
        draw.text((16, 31), 'Diagnostic ink + cone alpha. Same authored span; no resampling or dilation.', font=small, fill='#cccccc')
        for index, (folder, current, title) in enumerate([(baseline, previous, before_label), (candidate, row, after_label)]):
            x = 16 + index * (width + 16)
            draw = ImageDraw.Draw(image)
            draw.text((x, 56), title, font=font, fill='white')
            image.paste(combined(folder, current, box), (x, 80))
            draw = ImageDraw.Draw(image)
            draw.text((x, height + 90), f"Blank: {current['maximumBlankPixels']} px; 50% separation: {current['maximumHalfCoverageSeparationPixels']} px", font=small, fill='white')
            draw.text((x, height + 110), f"Coverage deficit: {current['maximumCoverageDeficitPixels']:.3f} px", font=small, fill='white')
        filename = output / f"{row['side']}-{row['id']}-comparison-native8x.png"
        def finish_labels(canvas, actual_palette):
            # Finish all pastes before drawing labels. Pillow may replace its
            # image core while decoded crops are pasted into a destination.
            labels = ImageDraw.Draw(canvas)
            labels.rectangle((0, 0, canvas.width, 79), fill='#18181c')
            labels.rectangle((0, height + 80, canvas.width, canvas.height), fill='#18181c')
            labels.text((16, 8), f"{row['id']} | {row['side']} | native 8 physical px / SVG unit", font=font, fill='white')
            labels.text((16, 31), 'Actual SVG palette + production cone color/falloff. Native pixels; no resampling.' if actual_palette else
                        'Diagnostic ink + cone alpha. Same authored span; no resampling or dilation.', font=small, fill='#cccccc')
            for index, (current, title) in enumerate([(previous, before_label), (row, after_label)]):
                x = 16 + index * (width + 16)
                labels.text((x, 56), title, font=font, fill='white')
                labels.text((x, height + 90), f"Blank: {current['maximumBlankPixels']} px; 50% separation: {current['maximumHalfCoverageSeparationPixels']} px", font=small, fill='white')
                labels.text((x, height + 110), f"Coverage deficit: {current['maximumCoverageDeficitPixels']:.3f} px", font=small, fill='white')
                lo, hi = current['geometricFirstClearInwardSvgRange']
                labels.text((x, height + 130), f"Mesh stop offset: {lo:+.3f} to {hi:+.3f} SVG", font=small, fill='#cccccc')
                if max(abs(lo), abs(hi)) > .01:
                    labels.text((x, height + 150), 'Wall placement remains unresolved.', font=small, fill='#ffcc82')
        finish_labels(image, False)
        image.save(filename)
        changes[-1].update(evidenceImage=str(filename), evidenceImageSha256=hashlib.sha256(filename.read_bytes()).hexdigest(), cropPixels=list(box))
        appearance = image.copy()
        appearance_draw = ImageDraw.Draw(appearance)
        appearance_draw.rectangle((0, 28, appearance.width, 50), fill='#18181c')
        appearance_draw.text((16, 31), 'Actual SVG palette + production cone color/falloff. Native pixels; no resampling.', font=small, fill='#cccccc')
        overlay_hashes = []
        for index, folder in enumerate((baseline, candidate)):
            overlay_path = folder / f"{row['side']}-{row['id']}-8x-overlay.png"
            appearance.paste(Image.open(overlay_path).convert('RGB').crop(box), (16 + index * (width + 16), 80))
            overlay_hashes.append(hashlib.sha256(overlay_path.read_bytes()).hexdigest())
        appearance_file = output / f"{row['side']}-{row['id']}-appearance-native8x.png"
        finish_labels(appearance, True)
        appearance.save(appearance_file)
        changes[-1].update(appearanceImage=str(appearance_file), appearanceImageSha256=hashlib.sha256(appearance_file.read_bytes()).hexdigest(), overlayImageSha256=overlay_hashes)
    result = dict(baselineFolder=str(baseline), candidateFolder=str(candidate), beforeLabel=before_label, afterLabel=after_label,
                  baselineReportSha256=hashlib.sha256(before_bytes).hexdigest(),
                  candidateReportSha256=hashlib.sha256(after_bytes).hexdigest(), changes=changes,
                  openingsBefore=before['preservedOpenings'], openingsAfter=after['preservedOpenings'])
    (output / 'baseline-comparison.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Compared', len(changes), 'case/side/scales; wrote native 8x evidence images.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--before-label', default='Previous candidate')
    parser.add_argument('--after-label', default='New candidate')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    run(args.baseline, args.candidate, args.before_label, args.after_label, args.output)
