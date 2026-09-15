"""Plot authored wall candidates against selected extracted source silhouettes."""
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import PathPatch
from matplotlib.path import Path as PlotPath
import numpy as np
import shapely

from audit_svg_source_height_associations import ROOT, REV


def polygon(ax, shape, color, alpha=1, edge=None):
    for part in shapely.get_parts(shape):
        if part.geom_type != 'Polygon' or part.is_empty:
            continue
        vertices, codes = [], []
        for ring in [part.exterior, *part.interiors]:
            q = np.array(ring.coords)
            vertices.extend(q)
            codes.extend([PlotPath.MOVETO] + [PlotPath.LINETO] * (len(q)-2) + [PlotPath.CLOSEPOLY])
        ax.add_patch(PathPatch(PlotPath(vertices, codes), facecolor=color,
                              edgecolor=edge or color, linewidth=.5, alpha=alpha))


def shape(row):
    q = [np.array(r).reshape(-1, 2) for r in row['rings']]
    return shapely.Polygon(q[0], q[1:])


def render(name, output):
    model = json.loads((REV / f'all-map-svg-footprints-v1/{name}-attack.json').read_text())
    decisions = json.loads((REV / f'all-map-svg-height-candidates-v1/{name}.json').read_text())['walls']
    walls = {w['id']: shape(w) for w in model['walls']}
    receiver = shapely.union_all([shape(w) for w in model['receivers']])
    ink = shapely.union_all(list(walls.values()))
    raw = np.load(ROOT / f'supplemented-v2/world/{name}/geometry.npz')
    points, faces = raw['points'], raw['faces']
    objects = json.loads((ROOT / f'supplemented-v2/world/{name}/geometry.json').read_text())['objects']
    matrix = np.array(json.loads((ROOT / f'tactical-alignment-sides-v1/{name}.json').read_text())['nativeToAttackSvg'])
    cache = {}

    def source(oid):
        if oid not in cache:
            o = objects[oid]
            t = points[faces[o['firstFace']:o['firstFace']+o['faceCount']]].astype(float)
            xy = t[:, :, :2] @ matrix[:, :2].T + matrix[:, 2]
            polys = shapely.polygons(xy)
            cache[oid] = shapely.union_all(polys[shapely.area(polys) > 1e-9])
        return cache[oid]

    output.mkdir(parents=True, exist_ok=True)
    for page in range((len(decisions)+5)//6):
        fig, axes = plt.subplots(3, 2, figsize=(14, 16), facecolor='#161616')
        for ax, row in zip(axes.flat, decisions[page*6:(page+1)*6]):
            target = walls[row['wallId']]
            box = np.array(target.bounds)
            pad = max(6, float(max(box[2:]-box[:2]))*.15)
            bounds = box + np.array([-pad, -pad, pad, pad])
            crop = shapely.box(*bounds)
            ax.set_facecolor('#161616')
            polygon(ax, receiver.intersection(crop), '#33271c')
            polygon(ax, ink.intersection(crop), '#7f6950')
            for oid in row['selectedSourceObjects']:
                polygon(ax, source(oid).intersection(crop), '#36a1c4', .25)
            polygon(ax, target, '#ffaf5b')
            ax.set_xlim(bounds[0], bounds[2]);ax.set_ylim(bounds[3], bounds[1]);ax.set_aspect('equal')
            ax.tick_params(colors='#888888', labelsize=7)
            ids=row['selectedSourceObjects']
            names=[objects[i]['path'].split('/')[1] for i in ids]
            label=' / '.join(names)
            label='\n'.join(label[i:i+85] for i in range(0,min(len(label),255),85))
            top=row['maximumSourceZ'];floor=row['floorElevationMeters']
            ax.set_title(f'{row["wallId"]} | ground {floor:.2f} | proposed top {top if top is None else round(top,2)}\n{label}', color='white', fontsize=8)
        for ax in list(axes.flat)[len(decisions[page*6:(page+1)*6]):]:ax.axis('off')
        fig.suptitle(f'{name.title()} source correspondence, page {page+1}\nOrange: actual SVG wall. Blue: selected source footprint. Candidates, not accepted heights.', color='white',fontsize=13)
        fig.tight_layout(rect=(0,0,1,.95))
        fig.savefig(output/f'{name}-{page:02}.png',dpi=110,facecolor=fig.get_facecolor());plt.close(fig)
    print(name, len(decisions), 'wall plots',flush=True)


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--maps',nargs='+',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    for name in a.maps:render(name,a.out/name)
