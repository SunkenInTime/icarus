"""Map-context views of frozen standing contact samples, without wall-role claims."""
import argparse
from collections import Counter, defaultdict
import gzip
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import resvg_py
from svgpathtools import Path as SvgPath, parse_path

from audit_all_map_wall_span_coverage import authored_spans, MAPS

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT / 'tactical-visibility-revision'
COLORS = {
    'positive-offset': '#ff806d',
    'negative-offset': '#65aaff',
    'within-display-band': '#eee0cb',
    'missing-contact': '#d795ff',
    'ambiguous-or-distant': '#dfbd62',
    'nonvertical-contact': '#75808e',
    'curved-span': '#c9cbcf',
    'no-standing-sample': '#424d5b',
}
LABELS = {
    'positive-offset': 'Near-vertical: positive offset >0.1 SVG',
    'negative-offset': 'Near-vertical: negative offset <-0.1 SVG',
    'within-display-band': 'Near-vertical: within +/-0.1 SVG (display bin)',
    'missing-contact': 'No source contact in the bounded probe',
    'ambiguous-or-distant': 'Ambiguous side/origin, distant or invalid contact',
    'nonvertical-contact': 'First source face is not near-vertical',
    'curved-span': 'Curved authored span: separate review',
}
CANDIDATES = {
    'split': ['split-wall-family-normalized-candidate-v13', 'diagonal-wall-candidates-v1/split'],
    'ascent': ['ascent-reviewed-wall-candidate-v1', 'diagonal-wall-candidates-v1/ascent'],
    'icebox': ['icebox-reviewed-wall-candidate-v2'],
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def category(sample, span):
    if span['segmentType'] != 'Line':
        return 'curved-span'
    if sample is None:
        return 'no-standing-sample'
    if sample.get('status') in ('receiver-side-ambiguous', 'probe-outside-display-warp'):
        return 'ambiguous-or-distant'
    if not sample.get('probeStartInsideReceiver', True):
        return 'ambiguous-or-distant'
    if sample.get('status') == 'no-control-contact':
        return 'missing-contact'
    if sample.get('status') != 'contact':
        return 'ambiguous-or-distant'
    if not sample.get('nearVerticalOriginalFace', False):
        return 'nonvertical-contact'
    gap = sample.get('inwardGapSvg')
    if gap is None or not np.isfinite(gap) or abs(gap) > 3 or sample.get('unresolved'):
        return 'ambiguous-or-distant'
    return 'positive-offset' if gap > .1 else 'negative-offset' if gap < -.1 else 'within-display-band'


def excluded_art_inventory(svg_root):
    """Count explicit SVG elements; their appearance does not assign a wall role."""
    primitives = Counter()
    path_styles = defaultdict(lambda: dict(elements=0, subpaths=0))
    included_paths = 0
    for element in svg_root.iter():
        tag = element.tag.rsplit('}', 1)[-1]
        if tag == 'path':
            if element.get('fill', '').lower() == '#271406':
                included_paths += 1
                continue
            key = json.dumps(dict(fill=element.get('fill'), stroke=element.get('stroke'), style=element.get('style')), sort_keys=True)
            row = path_styles[key]
            row['elements'] += 1
            row['subpaths'] += len(parse_path(element.get('d', '')).continuous_subpaths())
        elif tag in ['rect', 'circle', 'ellipse', 'line', 'polyline', 'polygon', 'text', 'image', 'use']:
            primitives[tag] += 1
    return dict(includedExplicitDarkFillPathElements=included_paths,
                excludedPathElements=sum(r['elements'] for r in path_styles.values()),
                excludedPathSubpaths=sum(r['subpaths'] for r in path_styles.values()),
                excludedPathsByExplicitStyle=[dict(**json.loads(k), **v) for k, v in path_styles.items()],
                excludedOtherPrimitiveElements=dict(primitives),
                excludedOtherPrimitiveTotal=sum(primitives.values()),
                scope='Explicit XML element counts, without inferred roles. Other path fills, separate wall strokes, cover/prop rectangles, labels and non-path primitives are outside this dark-fill-outline contact inventory. Inherited styles are not semantically resolved by these counts.')


def candidate_lines(name, summary):
    result, bindings = [], []
    for folder in CANDIDATES.get(name, []):
        path = REV / folder / 'bindings.json'
        data = json.loads(path.read_text())
        assert data['sourcePackSha256'] == summary['sourcePackSha256']
        assert data['displayWarpSha256'] == summary['displayWarpSha256']
        pack = path.parent / f'{name}.height.bin.gz'
        bindings.append(dict(file=str(path), sha256=sha(path), candidatePack=str(pack), candidatePackSha256=sha(pack)))
        for family in data['families']:
            if 'targetFrame' in family:
                frame = family['targetFrame']
                line = np.array(frame['origin']) + np.array(family['targetAlong'])[:, None] * np.array(frame['tangent'])
            else:
                line = np.full((2, 2), family['fixed'], dtype=float)
                line[:, family['axis']] = family['targetAlong']
            result.append(dict(candidate=folder, family=family['edge'], lineAttackSvg=line.tolist(),
                               status='Source-profile correction coverage only; endpoints and adjacent families may remain unresolved.'))
    return result, bindings


def make_side(name, side, out):
    coverage_dir = REV / 'all-map-wall-span-coverage-v1' / name
    summary_path = coverage_dir / 'summary.json'
    summary = json.loads(summary_path.read_text())
    coverage_path = coverage_dir / f'{side}.coverage.json.gz'
    coverage = json.loads(gzip.decompress(coverage_path.read_bytes()))
    art = Path(f'assets/maps/{name}_map{"_defense" if side == "defense" else ""}.svg')
    assert sha(art) == coverage['artSha256'], 'Original artwork changed'
    pack = REV / f'global-ground-complete-v2/{name}/{name}.height.bin.gz'
    warp_path = REV / f'display-warps-v1/{name}.display-warp.json.gz'
    assert sha(pack) == summary['sourcePackSha256']
    assert sha(warp_path) == summary['displayWarpSha256']
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    original = art.read_text()
    svg_root = ET.fromstring(original)
    excluded_art = excluded_art_inventory(svg_root)
    width, height = float(svg_root.get('width')), float(svg_root.get('height'))
    parsed = authored_spans(art)
    assert len(parsed) == len(coverage['spans'])
    by_span = defaultdict(list)
    for sample in coverage['samples']:
        if sample.get('relativeEyeHeightMeters', 1.75) == 1.75:
            by_span[sample['span']].append(sample)
    lines, candidate_bindings = candidate_lines(name, summary)
    underlay = []
    for item in lines:
        line = np.array(item['lineAttackSvg'])
        if side == 'defense':
            line = np.array(warp['attackToDefenseSvg']['origin']) - line
        item['lineSideSvg'] = line.tolist()
        underlay.append(f'<path d="M{line[0,0]},{line[0,1]}L{line[1,0]},{line[1,1]}" fill="none" stroke="#00dfce" stroke-width="4" opacity="0.7"><title>{item["candidate"]}, family {item["family"]}: correction coverage; not whole-corner acceptance</title></path>')
    paths, counts, span_records = [], Counter(), []
    for (parsed_record, segment), record in zip(parsed, coverage['spans']):
        assert parsed_record['span'] == record['span'] and parsed_record['segmentType'] == record['segmentType']
        assert np.allclose(parsed_record['startSvg'], record['startSvg'], atol=1e-10, rtol=0)
        assert np.allclose(parsed_record['endSvg'], record['endSvg'], atol=1e-10, rtol=0)
        rows = sorted(by_span[record['span']], key=lambda x: x['parameter'])
        assert len({r['samplePosition'] for r in rows}) == len(rows)
        bins = []
        for i, row in enumerate(rows):
            key = category(row, record)
            counts[key] += 1
            lo = 0 if i == 0 else (rows[i-1]['parameter'] + row['parameter']) / 2
            hi = 1 if i == len(rows)-1 else (row['parameter'] + rows[i+1]['parameter']) / 2
            if bins and bins[-1]['category'] == key:
                bins[-1]['endParameter'] = hi
                bins[-1]['sampleCount'] += 1
            else:
                bins.append(dict(category=key, startParameter=lo, endParameter=hi, sampleCount=1))
        if not rows:
            bins = [dict(category=category(None, record), startParameter=0, endParameter=1, sampleCount=0)]
        for item in bins:
            key = item['category']
            if item['endParameter'] <= item['startParameter']:
                continue
            shape = SvgPath(segment.cropped(item['startParameter'], item['endParameter'])).d()
            dashed = ' stroke-dasharray="1.2,1.2"' if key == 'curved-span' else ''
            paths.append(f'<path d="{shape}" fill="none" stroke="{COLORS[key]}" stroke-width="1.05"{dashed}><title>Span {record["span"]}, legacy edge {record["legacyStraightEdgeIndex"]}: {key}; {item["sampleCount"]} frozen standing samples</title></path>')
        span_records.append(dict(span=record['span'], legacyStraightEdgeIndex=record['legacyStraightEdgeIndex'],
                                 segmentType=record['segmentType'], implicitFillClosure=record['implicitFillClosure'],
                                 startSvg=record['startSvg'], endSvg=record['endSvg'], bins=bins,
                                 standingSampleCount=len(rows)))
    metadata = dict(map=name, side=side, originalWidth=width, originalHeight=height, originalViewBox=svg_root.get('viewBox'),
                    artFile=str(art.resolve()), artSha256=sha(art), coverageFile=str(coverage_path), coverageSha256=sha(coverage_path),
                    sourcePack=str(pack), sourcePackSha256=sha(pack), sourceGeometrySha256=summary['sourceGeometrySha256'],
                    displayWarpFile=str(warp_path), displayWarpSha256=sha(warp_path),
                    summaryFile=str(summary_path), summarySha256=sha(summary_path),
                    attackToDefenseSvg=warp['attackToDefenseSvg'], candidates=candidate_bindings,
                    correctedCoverage=lines, sampleClassificationCounts=dict(counts), authoredSpanCount=len(parsed),
                    excludedSvgInventory=excluded_art,
                    scope='Only outlines of explicit #271406 dark-fill paths. Interior structural props, cover rectangles and separate wall strokes are not audited here. Frozen standing first contacts at control-relative eye1.75m are diagnostic sample bins, not blocker/opening labels or defect classifications.',
                    limitations=['The +/-0.1SVG band is a display bin, not an accepted accuracy threshold.',
                                 'Colored subsegments use midpoint bins between samples; unsampled interiors are not certified.',
                                 'Cyan marks separately reviewed candidate source profiles. Underlying colors still describe the original frozen control pack, not a candidate rerun.',
                                 'All dark-fill paths, including covered/internal spans, curves, short spans and implicit closures are retained.',
                                 'Candidate packs are isolated alternatives, not a combined production pack. Adjacent returns and floor semantics remain provisional.'], spans=span_records)
    binding = {key: metadata[key] for key in ['map','side','artSha256','sourcePackSha256','sourceGeometrySha256',
                                               'displayWarpSha256','coverageSha256','originalWidth','originalHeight','originalViewBox','candidates','excludedSvgInventory','scope']}
    overlay = '<metadata id="icarus-audit-bindings">' + escape(json.dumps(binding)) + '</metadata><g id="icarus-audit-overlay">' + ''.join(underlay + paths) + '</g>'
    svg = original[:original.rfind('</svg>')] + overlay + original[original.rfind('</svg>'):]
    svg_path = out / f'{name}-{side}-context.svg'
    svg_path.write_text(svg, encoding='utf-8')
    png_path = out / f'{name}-{side}-context-native2x.png'
    png_path.write_bytes(resvg_py.svg_to_bytes(svg_string=svg, zoom=2, background='#101014'))
    with Image.open(png_path) as im:
        assert im.size == (round(width*2), round(height*2))
        panel = Image.new('RGB', (max(im.width, 1120), im.height+245), '#17171d')
        panel.paste(im.convert('RGB'), ((panel.width-im.width)//2, 245))
    draw = ImageDraw.Draw(panel)
    font = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 17)
    small = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 14)
    draw.text((16,10), f'{name.upper()} / {side} | dark-fill outline samples on original SVG | native2x', font=font, fill='white')
    draw.text((16,38), 'Interior cover/props and separate wall strokes are NOT audited here. Colors are probe offsets, not wall roles.', font=small, fill='#ffe0a5')
    for i,(key,label) in enumerate(LABELS.items()):
        x,y=16+(i%2)*550,68+(i//2)*28
        draw.line((x,y+8,x+23,y+8), fill=COLORS[key], width=4)
        draw.text((x+33,y),label,font=small,fill='white')
    draw.line((16,192,40,192),fill='#00dfce',width=8)
    draw.text((49,182),f'Cyan underlay: reviewed candidate profile coverage ({len(lines)} spans). Corners remain a separate check.',font=small,fill='white')
    draw.text((16,215),f'{len(parsed)} dark-fill spans | {sum(counts.values())} standing positions | Excluded: {excluded_art["excludedPathSubpaths"]} other path subpaths, {excluded_art["excludedOtherPrimitiveTotal"]} other primitives',font=small,fill='#bdc4cf')
    review_path=out/f'{name}-{side}-review.png'
    panel.save(review_path)
    metadata['outputs']={str(p):sha(p) for p in [svg_path,png_path,review_path]}
    (out/f'{name}-{side}.json').write_text(json.dumps(metadata,indent=2))
    return dict(map=name,side=side,reviewImage=str(review_path),svg=str(svg_path),authoredSpans=len(parsed),standingSamples=sum(counts.values()),classificationCounts=dict(counts),candidateSpans=len(lines),excludedSvgInventory=excluded_art)


def run(out, maps):
    out.mkdir(parents=True,exist_ok=True)
    records=[]
    for name in maps:
        for side in ['attack','defense']:
            row=make_side(name,side,out)
            records.append(row)
            print(name,side,row['authoredSpans'],row['classificationCounts'],flush=True)
            (out/'index.json').write_text(json.dumps(dict(scope=__doc__,generatorSha256=sha(Path(__file__)),records=records),indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('output',type=Path)
    p.add_argument('--maps',default=','.join(MAPS))
    a=p.parse_args()
    run(a.output,a.maps.split(','))
