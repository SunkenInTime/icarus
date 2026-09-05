"""Plot provisional 3D hits against current Icarus boundaries and low-cover rays."""
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from matplotlib.patches import Rectangle
import numpy as np


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('world')
    parser.add_argument('comparison')
    parser.add_argument('boundaries')
    parser.add_argument('output')
    args = parser.parse_args()
    world, comparison, boundaries = [json.loads(Path(p).read_text())
                                     for p in [args.world, args.comparison, args.boundaries]]
    by_id = {r['id']: r for r in comparison['rays']}
    rows = [r for r in world['rays'] if r['id'] in by_id]
    # Recover the affine projection from the production runner's exact outputs.
    # This only reproduces its current registration; it does not optimize a fit
    # to walls or silently correct any discrepancy.
    inputs = np.array([r['startMeters'][:2] + [1] for r in rows])
    targets = np.array([by_id[r['id']]['start'] for r in rows])
    transform = np.linalg.lstsq(inputs, targets, rcond=None)[0]
    assert np.max(np.abs(inputs @ transform - targets)) < 1e-7
    hits = [r for r in rows if r['blocked'] and not r['originNearSurface']
            and abs(r['normal'][2]) < 0.3 and r['heightAboveFloorMeters'] == 1.5]
    points = np.array([r['hitMeters'][:2] + [1] for r in hits]) @ transform
    bg = '#101720'
    plt.rcParams.update({'font.family': 'DejaVu Sans', 'text.color': '#ecf2f7',
                         'axes.labelcolor': '#bfcbd5', 'xtick.color': '#bfcbd5',
                         'ytick.color': '#bfcbd5'})
    fig, axes = plt.subplots(1, 2, figsize=(16, 9), facecolor=bg,
                              gridspec_kw={'width_ratios': [1.15, 1]})
    for ax in axes:
        ax.set_facecolor(bg)
        for spine in ax.spines.values():
            spine.set_color('#3a4957')
    layer = min(boundaries['sides'][0]['layers'], key=lambda l: abs(l['elevation'] - 500))
    axes[0].add_collection(LineCollection(layer['runtimeSegments'], colors='#e3ad61', linewidths=1))
    axes[0].scatter(points[:, 0], points[:, 1], c='#65d4e9', s=3, alpha=0.48)
    outer = next(g for g in boundaries['sides'][0]['groups'] if g['outer'])['bounds']
    axes[0].set_xlim(outer[0] - 30, outer[2] + 30)
    axes[0].set_ylim(outer[3] + 30, outer[1] - 30)
    axes[0].set_aspect('equal')
    axes[0].axis('off')
    axes[0].set_title('Current map registration\nGold: Icarus boundaries   Cyan: 3D ray hits', loc='left', pad=18)
    c = world['calibration']
    low, high = c[0]['sourceBoundsMeters']
    base = low[2]
    axes[1].add_patch(Rectangle((low[0], 0), high[0]-low[0], high[2]-base,
                               facecolor='#637788', edgecolor='#c4d0d8', alpha=0.6))
    for ray, color in zip(c, ['#f48c76', '#7edbb3', '#6dcde8']):
        a, b = ray['startMeters'], ray['endMeters']
        end = ray['hitMeters'] if ray['blocked'] else b
        axes[1].plot([a[0], end[0]], [a[2]-base, end[2]-base], color=color, linewidth=3)
        axes[1].scatter([end[0]], [end[2]-base], color=color, s=30)
        label = f"{ray['heightAboveCrateBase']:g} m: {'hits crate' if ray['blocked'] else 'passes above'}"
        axes[1].text(a[0], a[2]-base+0.065, label, color=color, fontsize=11)
    axes[1].set_ylim(-0.1, 2.1)
    axes[1].set_xlim(c[0]['startMeters'][0] - 0.1, c[0]['endMeters'][0] + 0.1)
    axes[1].set_aspect('equal')
    axes[1].set_xlabel('Exported world X, metres')
    axes[1].set_ylabel('Height above crate base, metres')
    axes[1].set_title('A real Mid crate, 1.30 m high\nSame horizontal line, three test heights', loc='left', pad=18)
    axes[1].text(0, -0.24, 'Rectangle shows the mesh bounds. Hit distance uses actual triangles.\n'
                'These test heights are not verified standing/crouching camera heights.',
                transform=axes[1].transAxes, fontsize=10, color='#bfcbd5')
    fig.suptitle('Split / Independent geometry reference', x=0.045, ha='left', fontsize=24)
    fig.text(0.045, 0.045, f"{world['summary']['triangles']:,} placed triangles  |  {len(rows):,} diagnostic rays\n"
             'Provisional: exported materials and map registration require verification. This is not an accuracy score.',
             color='#bfcbd5', fontsize=11)
    fig.subplots_adjust(top=0.83, bottom=0.20, left=0.045, right=0.97, wspace=0.16)
    fig.savefig(args.output, dpi=140, facecolor=bg)
    print(args.output)


if __name__ == '__main__':
    main()
