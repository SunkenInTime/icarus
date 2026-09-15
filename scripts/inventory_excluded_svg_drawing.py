"""Locate artwork excluded from dark-fill coverage without assigning wall roles."""
import argparse
from collections import Counter
import csv
import gzip
import hashlib
import json
import re
from pathlib import Path
from xml.sax.saxutils import escape

import numpy as np
import resvg_py
import shapely
from svgpathtools import Document, parse_path
from svgpathtools.document import CONVERSIONS
from PIL import Image, ImageDraw, ImageFont

from audit_all_map_wall_span_coverage import MAPS, authored_spans
from tactical_alignment_receiver import flatten, receiver_domain

REV = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def review_panels(out):
    index = json.loads((out/'index.json').read_text())
    font = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 17)
    small = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 14)
    for row in index['records']:
        source = Image.open(row['preview']).convert('RGB')
        panel = Image.new('RGB', (max(source.width, 1000), source.height+105), '#17171d')
        panel.paste(source, ((panel.width-source.width)//2, 105))
        draw = ImageDraw.Draw(panel)
        draw.text((16,12),f'{row["map"].upper()} / {row["side"]} | artwork excluded from dark-fill contact inventory',font=font,fill='white')
        draw.text((16,42),'Purple: explicit strokes with most samples inside the dark fill, away from its outlines.',font=small,fill='#d5a6ff')
        draw.text((16,65),'Drawing location only. Cover, wall, decoration and visibility roles remain unresolved.',font=small,fill='#ffe0a5')
        draw.text((16,85),f'{row["excludedSubpathsAndPrimitives"]} excluded pieces in full inventory; {row["highlightedInteriorStrokes"]} highlighted here. Native2x map pixels.',font=small,fill='#c0c5cf')
        path=out/f'{row["map"]}-{row["side"]}-review.png'
        panel.save(path)
        row.update(reviewImage=str(path),reviewImageSha256=sha(path))
    index['generatorSha256']=sha(Path(__file__))
    (out/'index.json').write_text(json.dumps(index,indent=2))


def run_side(name, side, out):
    art = Path(f'assets/maps/{name}_map{"_defense" if side == "defense" else ""}.svg')
    context_path = REV / 'all-map-dark-fill-context-v2' / f'{name}-{side}.json'
    context = json.loads(context_path.read_text())
    assert sha(art) == context['artSha256']
    document = Document(str(art))
    root = document.tree.getroot()
    elements = {id(e): i for i, e in enumerate(root.iter())}
    parents = {id(child): parent for parent in root.iter() for child in parent}
    for element in root.iter():
        if 'transform' in element.attrib:
            values = [float(x) for x in re.findall(r'[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?', element.get('transform'))]
            assert element.tag.endswith('circle') and len(values) == 3 and abs(values[0]) == 180
            assert values[1:] == [float(element.get('cx')), float(element.get('cy'))], 'Only reviewed own-center circle rotations supported'
    receiver = receiver_domain(art)
    lines = []
    for _, segment in authored_spans(art):
        points = flatten(segment)
        lines.append(shapely.LineString([(p.real, p.imag) for p in points]))
    outline = shapely.union_all(lines)
    records, highlighted = [], []
    paths = document.paths()
    rendered_elements = {id(p.element) for p in paths}
    for element in root.iter():
        tag = element.tag.rsplit('}', 1)[-1]
        if tag in CONVERSIONS and id(element) not in rendered_elements:
            path = parse_path(CONVERSIONS[tag](element))
            path.element, path.transform = element, np.eye(3)
            paths.append(path)
    for path in paths:
        element = path.element
        if element.get('fill', '').lower() == '#271406':
            continue
        tag = element.tag.rsplit('}', 1)[-1]
        non_rendered_definition = id(element) not in rendered_elements
        ancestors, ancestor = [], parents.get(id(element))
        while ancestor is not None:
            ancestors.append(ancestor.tag.rsplit('}',1)[-1])
            ancestor = parents.get(id(ancestor))
        if non_rendered_definition:
            assert any(t in ancestors for t in ['defs','mask','clipPath','symbol']), ancestors
        if element.get('transform'):
            cx, cy, radius = (float(element.get(k)) for k in ['cx','cy','r'])
            assert np.allclose(path.bbox(), [cx-radius,cx+radius,cy-radius,cy+radius], atol=1e-9, rtol=0)
        for part_index, part in enumerate(path.continuous_subpaths()):
            positions = []
            for segment in part:
                # This is a drawing-location sample, not a collision oracle.
                count = max(2, int(np.ceil(segment.length()/.5))+1)
                positions.extend(segment.point(t) for t in np.linspace(0, 1, count))
            if not positions:
                continue
            xy = np.array([(p.real, p.imag) for p in positions])
            points = shapely.points(xy)
            distance = shapely.distance(outline, points)
            inside = shapely.covers(receiver, points)
            near = float((distance <= .1).mean())
            interior = float((inside & (distance > .5)).mean())
            location = ('coincident-with-inventoried-outline' if near >= .95 else
                        'mostly-interior-drawing' if interior >= .5 else 'mixed-or-outside-drawing')
            if non_rendered_definition:
                location = 'definition-not-a-standalone-drawing'
            stroke = element.get('stroke')
            explicit_stroke = stroke is not None and stroke.lower() != 'none'
            kind = 'explicit-stroked-drawing' if explicit_stroke else 'filled-or-unspecified-drawing'
            bounds = part.bbox()
            key = f'element-{elements[id(element)]}-part-{part_index}'
            preview = explicit_stroke and interior >= .5 and not non_rendered_definition
            record = dict(id=key, elementIndex=elements[id(element)], subpath=part_index, tag=tag,
                          elementId=element.get('id'), attributes=dict(element.attrib),
                          ancestorTags=ancestors, nonRenderedDefinition=non_rendered_definition,
                          resolvedTransform=path.transform.tolist(),
                          pathSvg=part.d(), boundsSvg=[bounds[0], bounds[2], bounds[1], bounds[3]],
                          closed=part.isclosed(), segmentCount=len(part), drawingLengthSvg=part.length(),
                          drawingKind=kind, locationClass=location, sampledPoints=len(xy),
                          fractionNearIncludedOutline=near, fractionInsideDarkFill=float(inside.mean()),
                          fractionInteriorAwayFromOutline=interior, previewHighlighted=preview,
                          structuralRole='unresolved; an SVG drawing is not proof of collision or visibility blocking')
            records.append(record)
            if preview:
                highlighted.append(f'<path d="{part.d()}" fill="none" stroke="#c994ff" stroke-width="1.1"><title>{key}: sampled interior stroke; structural role unresolved</title></path>')
    expected = context['excludedSvgInventory']
    assert len(records) == expected['excludedPathSubpaths'] + expected['excludedOtherPrimitiveTotal'], (name, side, len(records), expected)
    groups = Counter((r['drawingKind'], r['locationClass']) for r in records)
    summary = dict(map=name, side=side, excludedSubpathsAndPrimitives=len(records),
                   groups=[dict(drawingKind=k[0], locationClass=k[1], count=v) for k, v in sorted(groups.items())],
                   highlightedInteriorStrokes=len(highlighted))
    result = dict(scope=__doc__, map=name, side=side, artFile=str(art.resolve()), artSha256=sha(art),
                  sourceContext=str(context_path), sourceContextSha256=sha(context_path),
                  sourcePackSha256=context['sourcePackSha256'], displayWarpSha256=context['displayWarpSha256'],
                  originalWidth=context['originalWidth'], originalHeight=context['originalHeight'],
                  originalViewBox=context['originalViewBox'], summary=summary,
                  policy=dict(nearOutlineSampleDistanceSvg=.1, interiorAwayDistanceSvg=.5,
                              mostlyInteriorFraction=.5, coincidentFraction=.95,
                              sampleScheme='At least two samples per segment, count ceil(length/0.5)+1, evenly spaced in parameter.',
                              scope='Geometric location only. Includes labels, tinted areas, decorative shapes, outline duplicates and cover/wall candidates. No visibility or collision role is assigned.'),
                  records=records)
    name_side=f'{name}-{side}'
    path=out/f'{name_side}.json.gz'
    path.write_bytes(gzip.compress(json.dumps(result,separators=(',',':')).encode(),mtime=0))
    with (out/f'{name_side}.csv').open('w',newline='') as stream:
        keys=['id','tag','drawingKind','locationClass','boundsSvg','closed','segmentCount','drawingLengthSvg','fractionNearIncludedOutline','fractionInsideDarkFill','fractionInteriorAwayFromOutline','previewHighlighted']
        writer=csv.DictWriter(stream,fieldnames=keys)
        writer.writeheader()
        writer.writerows({k:r[k] for k in keys} for r in records)
    original=art.read_text()
    metadata={k:result[k] for k in ['scope','map','side','artSha256','sourceContextSha256','sourcePackSha256','displayWarpSha256','policy']}
    overlay='<metadata id="icarus-excluded-art-inventory">'+escape(json.dumps(metadata))+'</metadata><g id="icarus-interior-stroke-preview">'+''.join(highlighted)+'</g>'
    svg=original[:original.rfind('</svg>')]+overlay+original[original.rfind('</svg>'):]
    svg_path=out/f'{name_side}-interior-stroke-preview.svg'
    svg_path.write_text(svg)
    png_path=out/f'{name_side}-interior-stroke-preview-native2x.png'
    png_path.write_bytes(resvg_py.svg_to_bytes(svg_string=svg,zoom=2,background='#101014'))
    return {**summary,'inventory':str(path),'inventorySha256':sha(path),'preview':str(png_path),'previewSha256':sha(png_path)}


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('output',type=Path)
    p.add_argument('--maps',default=','.join(MAPS))
    args=p.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    rows=[]
    for name in args.maps.split(','):
        for side in ['attack','defense']:
            row=run_side(name,side,args.output)
            rows.append(row)
            print(name,side,row['excludedSubpathsAndPrimitives'],'excluded drawing pieces,',row['highlightedInteriorStrokes'],'sampled interior strokes',flush=True)
            (args.output/'index.json').write_text(json.dumps(dict(scope=__doc__,generatorSha256=sha(Path(__file__)),records=rows),indent=2))
    review_panels(args.output)
