"""Compare a diagnostic 3D slice with current Icarus clipping at one observer."""
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from matplotlib.patches import Polygon
import numpy as np


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prototype')
    parser.add_argument('output')
    args = parser.parse_args()
    report = json.loads(Path(args.prototype).read_text(encoding='utf-8'))
    preview = report['preview']
    origin = np.array(preview['origin'])
    # This view uses the exact production canvas coordinates from Flutter.
    # Both panels share limits, aspect ratio and the same authored boundaries.
    background = '#101720'
    plt.rcParams.update({'font.family': 'DejaVu Sans', 'text.color': '#e9eef5'})
    fig, axes = plt.subplots(1, 2, figsize=(13, 7), facecolor=background)
    radius = 55
    for ax, key, color, title in zip(axes,
            ['currentPolygon', 'slicePolygon'], ['#f58a78', '#77d9c6'],
            ['Current SVG clipping', 'Prototype from the 3D model']):
        ax.set_facecolor(background)
        ax.add_patch(Polygon(preview[key], facecolor=color, edgecolor=color, alpha=0.27))
        ax.add_collection(LineCollection(preview['runtimeSegments'], colors='#c9a36d', linewidths=1.8))
        ax.scatter(*origin, color='#ffffff', s=35, zorder=5)
        ax.set_xlim(origin[0] - radius, origin[0] + radius)
        ax.set_ylim(origin[1] + radius, origin[1] - radius)
        ax.set_aspect('equal')
        ax.axis('off')
        ax.set_title(title, loc='left', fontsize=17, pad=15)
    axes[1].add_collection(LineCollection(preview['sliceSegments'], colors='#77d9c6', linewidths=0.6, alpha=0.55))
    fig.suptitle('Split B-site crate / Same map size, different sight blockers',
                 x=0.045, ha='left', fontsize=20)
    fig.text(0.045, 0.885, 'Standing-height prototype: floor + 1.75 m. The exact game camera height remains unverified.',
             fontsize=11, color='#bbc8d8')
    fig.text(0.08, 0.19, 'Selected sightline stops at 0.337 m', color='#f58a78', fontsize=13)
    witness = next(r for r in report['rays'] if r['id'] == preview['id'] and r['attack'])
    fig.text(0.555, 0.19, f"Selected sightline reaches the wall at {witness['sliceDistanceMeters']:.3f} m",
             color='#77d9c6', fontsize=13)
    fig.text(0.045, 0.10, 'Gold: unchanged authored boundaries   Green: cross-section of exported triangles   White: observer\n'
             f"{len(report['rays'])} rays checked in both orientations. Largest conversion error: {report['maximumErrorMeters'] * 1000:.3f} mm.\n"
             'This verifies 3D-to-2D conversion, not complete in-game accuracy. Uncertain materials remain in the prototype.',
             fontsize=10.5, color='#bbc8d8', linespacing=1.6)
    fig.subplots_adjust(left=0.045, right=0.96, top=0.81, bottom=0.25, wspace=0.14)
    fig.savefig(args.output, dpi=150, facecolor=background)
    print(args.output)


if __name__ == '__main__':
    main()
