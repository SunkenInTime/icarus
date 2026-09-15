"""Actual SVG versus exact source sections, separated by height to expose relief."""
import argparse
import json
import math
from pathlib import Path
import textwrap
import gzip

from PIL import Image, ImageDraw, ImageFont


def font(size):
    return ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', size)


def save(image, target):
    temporary = target.with_suffix('.pending.png')
    image.save(temporary)
    temporary.replace(target)


def priority_records(doc, baseline, sides):
    """Nav admission is a facing check, not proof the facade match is correct."""
    import numpy as np
    from shapely.geometry import Point, Polygon
    from shapely.strtree import STRtree
    name = doc['map']
    catalog = json.loads((baseline / 'height_catalog.json').read_text())['maps'][name]
    nav = json.loads(gzip.decompress((baseline / catalog['navigation']).read_bytes()))
    transform = catalog['uiTransform']
    uv = np.asarray(nav['vertices']).reshape(-1, 3)[:, :2] / nav['coordinateScale']
    native = np.column_stack(((uv[:, 1] - transform['YScalarToAdd']) / (100 * transform['YMultiplier']),
                              -(uv[:, 0] - transform['XScalarToAdd']) / (100 * transform['XMultiplier']), np.ones(len(uv))))
    projection = np.asarray(json.loads((sides / f'{name}.json').read_text())['nativeToAttackSvg'])
    svg = native @ projection.T
    polygons = [Polygon(svg[p]) for i, p in enumerate(nav['polygons']) if nav['walkable'][i]]
    tree = STRtree(polygons)
    selected, excluded, groups = [], [], {}
    for number, record in enumerate(doc['records'], 1):
        admitted = [i for i, f in enumerate(record['boundedFacadeFixtures'])
                    if len(tree.query(Point(f['originSvg']), predicate='intersects'))]
        offset = math.hypot(*record['displacementSvg'])
        reason = 'Pearl requested review' if name == 'pearl' else (
            'flagged, nav-admitted facing origin, offset >=0.25 SVG, supported length >=10 SVG'
            if record['flags'] and admitted and 'walkable-facing-side-unconfirmed' not in record['flags']
            and offset >= .25 and record['supportLengthSvg'] >= 10 else None)
        if reason is None:
            excluded.append(number)
            continue
        key = (record['sourceObject'], record['svgLineId'])
        if key in groups:
            groups[key]['duplicateRecordNumbers'].append(number)
            continue
        evidence = {'selectionReason': reason, 'navAdmittedFixtureIndices': admitted,
                    'offsetSvg': offset, 'supportedLengthSvg': record['supportLengthSvg'], 'duplicateRecordNumbers': []}
        groups[key] = evidence
        selected.append((number, record, evidence))
    return selected, {'total': len(doc['records']), 'selectedClusters': len(selected), 'excludedRecordNumbers': excluded}


def compose(records_folder, artwork_folder, output, baseline=None, sides=None):
    output.mkdir(parents=True, exist_ok=True)
    index = []
    selection = {}
    for source in sorted(records_folder.glob('*.json'), key=lambda p: (p.stem != 'pearl', p.stem)):
        doc = json.loads(source.read_text())
        if not isinstance(doc, dict) or 'records' not in doc:
            continue
        name = doc['map']
        artwork = Image.open(artwork_folder / f'{name}.png').convert('RGB')
        panels = []
        if baseline:
            records, selection[name] = priority_records(doc, baseline, sides)
        else:
            records = [(i, r, {}) for i, r in enumerate(doc['records'], 1)]
        for number, record, evidence in records:
            sections = record['sourceSections']
            points = [p for line in [record['targetLineSvg'], *(s['lineSvg'] for s in sections)] for p in line]
            lo = [min(p[i] for p in points) for i in (0, 1)]
            hi = [max(p[i] for p in points) for i in (0, 1)]
            box = (max(0, math.floor((lo[0] - 10) * 4)), max(0, math.floor((lo[1] - 10) * 4)),
                   min(artwork.width, math.ceil((hi[0] + 10) * 4)), min(artwork.height, math.ceil((hi[1] + 10) * 4)))
            crop = artwork.crop(box)
            zoom = 2 if max(crop.size) < 320 else 1
            crop = crop.resize((crop.width * zoom, crop.height * zoom), Image.Resampling.NEAREST)
            heights = sorted({s['heightMeters'] for s in sections})
            panel_w, panel_h = max(340, crop.width), max(280, crop.height + 35)
            width = max(1100, 300 + panel_w * len(heights))
            obj_lines = textwrap.wrap(record['sourceObject'], width=max(70, int(width / 10)))
            flags = ', '.join(record['flags']) or 'no automated ambiguity flag'
            flag_lines = textwrap.wrap(f"Flags: {flags} | max plane deviation {record['maximumSourcePlaneDeviationSvg']:.3f} SVG units", width=int(width / 10))
            object_y = 80 + len(flag_lines) * 24
            header = object_y + 25 + len(obj_lines) * 24
            image = Image.new('RGB', (width, header + panel_h + 50), '#17171d')
            draw = ImageDraw.Draw(image)
            status = 'FLAGGED' if record['flags'] else 'REVIEW CANDIDATE'
            draw.text((16, 8), f"{name.upper()} {number:02d} / SVG edge {record['svgLineId']} / {status}", font=font(26), fill='white')
            draw.text((16, 46), f"Source cyan; authored edge gold. {4 * zoom} pixels/SVG unit. No warp approved.", font=font(19), fill='#c4c4cd')
            for i, line in enumerate(flag_lines):
                draw.text((16, 76 + i * 24), line, font=font(18), fill='#efb0ca')
            for i, line in enumerate(obj_lines):
                draw.text((16, object_y + i * 24), line, font=font(18), fill='#c4c4cd')
            overview = artwork.copy()
            overview.thumbnail((280, panel_h - 10), Image.Resampling.LANCZOS)
            image.paste(overview, (10, header))
            draw = ImageDraw.Draw(image)
            od = ImageDraw.Draw(image)
            factor = overview.width / artwork.width
            od.rectangle((10 + box[0] * factor, header + box[1] * factor,
                          10 + box[2] * factor, header + box[3] * factor), outline='#ffc454', width=2)
            def line_points(line, x):
                return [(x + (p[0] * 4 - box[0]) * zoom, header + 35 + (p[1] * 4 - box[1]) * zoom) for p in line]
            for i, height in enumerate(heights):
                x = 300 + i * panel_w
                image.paste(crop, (x, header + 35))
                draw = ImageDraw.Draw(image)
                draw.text((x + 8, header + 3), f'World Z {height:.3f} m', font=font(21), fill='white')
                draw.line(line_points(record['targetLineSvg'], x), fill='#ffc454', width=2)
                for section in sections:
                    if section['heightMeters'] == height:
                        draw.line(line_points(section['lineSvg'], x), fill='#4ce6ee', width=2)
            shift = ', '.join(f'{v:.3f}' for v in record['displacementSvg'])
            draw.text((16, image.height - 36), f"Median proposed shift [{shift}] SVG units. Inspect all height panels before accepting a correspondence.", font=font(18), fill='#c4c4cd')
            path = output / f"{name}-{number:02d}-edge-{record['svgLineId']}.png"
            save(image, path)
            panels.append(image)
            index.append({'map': name, 'number': number, 'svgLineId': record['svgLineId'],
                          'sourceObject': record['sourceObject'], 'flags': record['flags'],
                          'eligibleForVisualReview': record['eligibleForVisualReview'], 'image': str(path),
                          'recordFile': str(source), 'sourcePixelCrop': box, 'pixelsPerSvgUnit': 4 * zoom, **evidence})
        page_size = 3 if baseline else 12
        for start in range(0, len(panels), page_size):
            batch = panels[start:start + page_size]
            sheet = Image.new('RGB', (1920, 70 + (len(batch) if baseline else math.ceil(len(batch) / 2)) * 600), '#17171d')
            sd = ImageDraw.Draw(sheet)
            sd.text((16, 10), f'{name.upper()} / exact multi-height source sections / cases {start + 1}-{start + len(batch)}', font=font(28), fill='white')
            for i, panel in enumerate(batch):
                preview = panel.copy()
                preview.thumbnail((1900, 590) if baseline else (950, 590), Image.Resampling.LANCZOS)
                sheet.paste(preview, (10 if baseline else (i % 2) * 960, 70 + (i if baseline else i // 2) * 600))
            save(sheet, output / f'{name}-contact-{start // page_size + 1:02d}.png')
        print(f'{name}: {len(panels)} facade records', flush=True)
    (output / 'index.json').write_text(json.dumps(index, indent=2))
    (output / 'selection.json').write_text(json.dumps(selection, indent=2))
    print(f'Wrote {len(index)} exact multi-height facade panels')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('records', type=Path)
    parser.add_argument('artwork', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--sides', type=Path)
    args = parser.parse_args()
    compose(args.records, args.artwork, args.output, args.baseline, args.sides)
