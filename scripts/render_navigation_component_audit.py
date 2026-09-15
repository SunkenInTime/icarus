"""Render disconnected-navigation evidence over the unchanged map artwork."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

import numpy as np
import shapely

from tactical_alignment_receiver import receiver_domain
from audit_navigation_components import native_vertices

SVG = 'http://www.w3.org/2000/svg'
ET.register_namespace('', SVG)


def element(name, attributes):
    return ET.Element(f'{{{SVG}}}{name}', {k: str(v) for k, v in attributes.items()})


def path_data(shape):
    parts = []
    for polygon in shapely.get_parts(shape):
        if polygon.geom_type != 'Polygon':
            continue
        for ring in [polygon.exterior, *polygon.interiors]:
            points = list(ring.coords)
            parts.append('M' + 'L'.join(f'{x:.9f},{y:.9f}' for x, y in points) + 'Z')
    return ''.join(parts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report-directory', type=Path, required=True)
    parser.add_argument('--display-directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    summary = json.loads((args.report_directory / 'summary.json').read_text())
    names = sorted(set(r['map'] for r in summary['rows']))
    files = []
    navigation_directory = args.report_directory.parent / 'baseline-world'
    catalog = json.loads((navigation_directory / 'height_catalog.json').read_text())['maps']
    for name in names:
        report = json.loads((args.report_directory / f'{name}.json').read_text())
        nav_bytes = (navigation_directory / f'{name}_navigation.json.gz').read_bytes()
        if hashlib.sha256(nav_bytes).hexdigest() != report['navigationSha256']:
            raise ValueError('Navigation changed since component audit')
        nav = json.loads(gzip.decompress(nav_bytes))
        nav_vertices = native_vertices(nav['vertices'], nav['coordinateScale'], catalog[name]['uiTransform'])
        data = json.loads(gzip.decompress((args.display_directory / f'{name}.display-warp.json.gz').read_bytes()))
        source = np.array(data['sourceNativeMeters']).reshape(-1, 2)
        target = np.array(data['targetAttackSvg']).reshape(-1, 2)
        triangles = np.array(data['triangles']).reshape(-1, 3)
        cells = shapely.polygons(source[triangles]); tree = shapely.STRtree(cells)
        p = data['projection']; origin = np.array(p['origin']); matrix = np.column_stack((p['axisU'], p['axisV']))
        domain = shapely.union_all(cells)
        def to_svg(shape):
            pieces = []
            for index in tree.query(shape, predicate='intersects'):
                intersection = cells[index].intersection(shape)
                if intersection.area <= 0:
                    continue
                a, b = source[triangles[index]], target[triangles[index]]
                affine = np.column_stack((b[1]-b[0], b[2]-b[0])) @ np.linalg.inv(np.column_stack((a[1]-a[0], a[2]-a[0])))
                pieces.append(shapely.transform(intersection, lambda xy: (xy-a[0]) @ affine.T + b[0]))
            remainder = shape.difference(domain)
            if not remainder.is_empty:
                pieces.append(shapely.transform(remainder, lambda xy: xy @ matrix.T + origin))
            return shapely.union_all(pieces)
        original = ET.parse(f'assets/maps/{name}_map.svg').getroot()
        box = list(map(float, original.get('viewBox').split())); width, height = box[2:]
        receiver = receiver_domain(Path(f'assets/maps/{name}_map.svg'))
        mapped = [(r, to_svg(shapely.from_geojson(json.dumps(r['footprintNativeGeojson']))).intersection(receiver))
                  for r in report['components'] if r['paintedAreaMeters2'] > 1]
        for mode in ['all-priority', 'structural-priority']:
            doc = element('svg', {'viewBox': f'0 -24 {width} {height+24}', 'width': width, 'height': height+24})
            doc.append(element('rect', {'x': 0, 'y': -24, 'width': width, 'height': height+24, 'fill': '#10171e'}))
            title = element('text', {'x': 5, 'y': -15, 'fill': '#ffffff', 'font-size': 8, 'font-family': 'Segoe UI'})
            title.text = f'{name.capitalize()} | disconnected standing navigation'; doc.append(title)
            note = element('text', {'x': 5, 'y': -5, 'fill': '#b8c6d0', 'font-size': 5, 'font-family': 'Segoe UI'})
            note.text = 'Cyan: sampled structural floor. Amber: prop/terrain. Pink: unresolved. Labels are component IDs.'; doc.append(note)
            # Keep root-level SVG inheritance such as fill="none" as well.
            doc.append(copy.deepcopy(original))
            for row, shape in mapped:
                structural = row.get('hasStructuralSourceSample', row['classification'].startswith('source-backed structural'))
                if mode == 'structural-priority' and not structural:
                    continue
                color = '#35ddeb' if structural else '#ffb74d' if row['classification'].startswith('source-backed') else '#ff6297'
                drawn = []
                if row.get('mixedSourceRoles'):
                    for sample in row['samples']:
                        floor = sample['classification'].startswith('source-backed structural')
                        if mode == 'structural-priority' and not floor:
                            continue
                        parent = sample['navParent']
                        piece = to_svg(shapely.Polygon(nav_vertices[nav['polygons'][parent], :2])).intersection(receiver)
                        parent_color = '#35ddeb' if floor else '#ffb74d' if sample['classification'].startswith('source-backed') else '#ff6297'
                        drawn.append((piece, parent_color))
                    shape = shapely.union_all([piece for piece, _ in drawn])
                else:
                    drawn = [(shape, color)]
                for piece, parent_color in drawn:
                    doc.append(element('path', {'d': path_data(piece), 'fill': parent_color, 'fill-opacity': .42,
                                                'fill-rule': 'evenodd', 'stroke': parent_color, 'stroke-width': .5}))
                if not shape.is_empty:
                    point = shape.representative_point()
                    label = element('text', {'x': point.x, 'y': point.y+1.5, 'text-anchor': 'middle',
                                             'font-family': 'Segoe UI', 'font-size': 5, 'font-weight': 700,
                                             'fill': 'white', 'stroke': '#10171e', 'stroke-width': 1.1, 'paint-order': 'stroke'})
                    label.text = str(row['component']); doc.append(label)
            svg = args.output / f'{name}-{mode}.svg'; ET.ElementTree(doc).write(svg, encoding='utf-8', xml_declaration=True)
            files.append(str(svg))
    manifest = args.output / 'files.json'; manifest.write_text(json.dumps(files))
    code = "const fs=require('node:fs');const {Resvg}=require(process.argv[1]);for(const f of JSON.parse(fs.readFileSync(process.argv[2],'utf8'))){fs.writeFileSync(f.replace(/svg$/,'png'),new Resvg(fs.readFileSync(f),{fitTo:{mode:'zoom',value:2.5},font:{loadSystemFonts:true}}).render().asPng());}"
    subprocess.run(['node', '-e', code, str(Path('artifacts/svg-render/node_modules/@resvg/resvg-js').resolve()), str(manifest)], check=True)
    print(f'Rendered {len(files)} unchanged-art component overlays')


if __name__ == '__main__':
    main()
