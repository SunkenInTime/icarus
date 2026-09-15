"""Render the complete assumed-wall inventory with its measured source sections."""
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
import shapely

from audit_all_map_gameplay_levels import MAPS, read
from compile_reviewed_svg_height_map import polygon
from inventory_assumed_svg_heights import DESTINATION


def render(name, output=DESTINATION):
    directory = output / name
    report = read(directory / 'assumed-height-sections.json')
    inventory = read(directory / 'assumed-height-review.json')['records']
    lookup = {w['wallId']: w for w in inventory}
    model = read(directory / 'before-attack.json.gz')
    shapes = [polygon(w) for w in model['walls']]
    tree = shapely.STRtree(shapes)
    gallery = directory / 'assumed-height-gallery'
    gallery.mkdir(exist_ok=True)
    pages = []
    for start in range(0, len(report['records']), 6):
        rows = report['records'][start:start + 6]
        fig = plt.figure(figsize=(16, 11), constrained_layout=True)
        outer = fig.add_gridspec(3, 2)
        for local, row in enumerate(rows):
            grid = outer[local // 2, local % 2].subgridspec(2, 2, height_ratios=[5, 1])
            plan, profile, description = (fig.add_subplot(grid[0, 0]),
                                          fig.add_subplot(grid[0, 1]),
                                          fig.add_subplot(grid[1, :]))
            description.axis('off')
            wall = lookup[row['wallId']]
            x0, y0, x1, y1 = row['boundsSvg']
            pad = max(4., .12 * max(x1 - x0, y1 - y0))
            clip = shapely.box(x0 - pad, y0 - pad, x1 + pad, y1 + pad)
            outlines = []
            for index in tree.query(clip):
                for part in shapely.get_parts(shapes[index]):
                    if part.geom_type == 'Polygon':
                        outlines.append(np.asarray(part.exterior.coords))
                        outlines.extend(np.asarray(r.coords) for r in part.interiors)
            plan.add_collection(LineCollection(outlines, colors='#b9b1a7', linewidths=.6))
            selected = polygon(wall)
            selected_parts = [p for p in shapely.get_parts(selected) if p.geom_type == 'Polygon']
            selected_lines = [np.asarray(r.coords) for p in selected_parts
                              for r in [p.exterior, *p.interiors]]
            plan.add_collection(LineCollection(selected_lines, colors='#c84a2d', linewidths=1.2))
            plan.set(xlim=(x0 - pad, x1 + pad), ylim=(y1 + pad, y0 - pad), aspect='equal')
            plan.tick_params(labelsize=6)
            plan.set_title(f'{start + local + 1}. {row["wallId"]}', fontsize=8, loc='left')
            eye = row['floorElevationMeters'] + 1.75
            segments = []
            missing = []
            for index, station in enumerate(row['stations']):
                for low, high in station['combinedGeometryBands']:
                    segments.append([[index, low], [index, high]])
                if not station['sourceSections']:
                    missing.append(index)
            profile.add_collection(LineCollection(segments, colors='#476b8e', linewidths=1.8))
            profile.axhline(eye, color='#db542e', linewidth=1, label=f'Old base + eye {eye:.2f} m')
            if missing:
                profile.scatter(missing, np.full(len(missing), eye), marker='x', s=8, c='#d43221')
            profile.set(xlim=(-1, max(1, len(row['stations']))),
                        ylim=(row['floorElevationMeters'] - 1, row['floorElevationMeters'] + 12))
            profile.tick_params(labelsize=6)
            profile.set_title(f'{len(row["stations"])} local sections; {row["withoutSourceSection"]} unmatched', fontsize=8)
            profile.legend(fontsize=6, loc='upper right')
            profile.grid(axis='y', alpha=.15)
            top = row['sourceObjects'][:3]
            text = '\n'.join(f'{o["object"]} {o["path"].split("/")[1]} [{o["stations"]} sections]' for o in top)
            description.text(0, .95, text[:350], fontsize=7, va='top', family='monospace')
        fig.suptitle(f'{name.title()} | assumed walls {start + 1}-{start + len(rows)} of {len(report["records"])}\n'
                     'Orange: selected SVG ink. Blue: measured local source geometry. These are evidence, not accepted heights.', fontsize=11)
        path = gallery / f'page-{start // 6 + 1:02}.png'
        fig.savefig(path, dpi=110)
        plt.close(fig)
        pages.append(dict(file=path.name, wallIds=[r['wallId'] for r in rows]))
    (gallery / 'manifest.json').write_text(json.dumps(pages, indent=2))
    print(name, len(report['records']), 'walls', len(pages), 'pages', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=MAPS)
    parser.add_argument('--output', type=Path, default=DESTINATION)
    args = parser.parse_args()
    for name in args.maps:
        render(name, args.output)
