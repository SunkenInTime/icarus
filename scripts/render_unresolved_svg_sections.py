"""Inspect unresolved ink against raw source slices at ground and eye height."""
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
import shapely

from audit_all_map_gameplay_levels import ROOT, read
from compile_local_svg_wall_profiles import polygon, unresolved
from resolve_local_svg_wall_profiles import OUTPUT
from svg_review_source import source_world, verified_source_pack


def slice_triangles(tri, height):
    segments = []
    selected = tri[(tri[:, :, 2].min(1) <= height) & (tri[:, :, 2].max(1) >= height)]
    for row in selected:
        hits = []
        for a, b in zip(row, np.roll(row, -1, axis=0)):
            if (a[2] <= height < b[2]) or (b[2] <= height < a[2]):
                hits.append(a[:2] + (height - a[2]) / (b[2] - a[2]) * (b[:2] - a[:2]))
        if len(hits) == 2:
            segments.append(hits)
    return np.asarray(segments)


def render(name):
    directory = OUTPUT / name
    model = read(directory / 'candidate-attack.json.gz')
    unknown = [w for w in model['walls'] if unresolved(w)]
    if not unknown:
        return
    profiles = read(directory / 'local-source-profiles.json')
    samples = [s for w in profiles['records'] for s in w['stations'] if s['status'].startswith('needs')]
    shapes = [polygon(w) for w in model['walls']]
    wall_tree = shapely.STRtree(shapes)
    source = source_world(name)
    metadata = read(source / 'geometry.json')['objects']
    with np.load(source / 'geometry.npz') as data:
        points, faces = data['points'], data['faces']
    retained = verified_source_pack(name)['retained']
    bounds = np.asarray([o['boundsMeters'] for o in metadata])
    tree = shapely.STRtree(shapely.box(bounds[:, 0, 0], bounds[:, 0, 1], bounds[:, 1, 0], bounds[:, 1, 1]))
    matrix = np.asarray(read(ROOT / f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    manifest = []
    for start in range(0, len(unknown), 6):
        fig, axes = plt.subplots(2, 3, figsize=(16, 10), constrained_layout=True)
        for ax, wall in zip(axes.flat, unknown[start:start + 6]):
            shape = polygon(wall)
            center = np.asarray(shape.representative_point().coords[0])
            sample = min(samples, key=lambda s: np.linalg.norm(np.asarray(s['associationSvg']) - center))
            floor = sample['floorElevationMeters']
            x0, y0, x1, y1 = shape.bounds
            pad = 6.
            clip = shapely.box(x0-pad, y0-pad, x1+pad, y1+pad)
            corners = np.array(clip.exterior.coords)
            native = (corners - matrix[:, 2]) @ inverse.T
            native_clip = shapely.box(*native.min(0), *native.max(0))
            nearby = tree.query(native_clip)
            arrays = []
            owners = []
            for oid in nearby:
                obj = metadata[oid]
                ids = np.arange(obj['firstFace'], obj['firstFace']+obj['faceCount'])
                ids = ids[retained[ids]]
                tri = points[faces[ids]].astype(float)
                take = ((tri[:, :, :2].min(1) <= native.max(0)).all(1)
                        & (tri[:, :, :2].max(1) >= native.min(0)).all(1))
                if take.any():
                    arrays.append(tri[take]); owners.append(int(oid))
            tri = np.concatenate(arrays) if arrays else np.empty((0, 3, 3))
            lines = []
            for i in wall_tree.query(clip):
                part = shapes[i].intersection(clip)
                for p in shapely.get_parts(part):
                    if p.geom_type == 'Polygon':
                        lines.extend(np.asarray(r.coords) for r in [p.exterior, *p.interiors])
            ax.add_collection(LineCollection(lines, colors='#999999', linewidths=2.))
            for z, color in [(floor-.1, '#208d72'), (floor+.1, '#3475ad'), (floor+1.75, '#e3a318')]:
                segments = slice_triangles(tri, z)
                if len(segments):
                    segments = segments @ matrix[:, :2].T + matrix[:, 2]
                    ax.add_collection(LineCollection(segments, colors=color, linewidths=.8))
            ax.add_collection(LineCollection([np.asarray(r.coords) for r in [shape.exterior, *shape.interiors]],
                                             colors='#d92736', linewidths=2.))
            ax.scatter(*sample['associationSvg'], c='black', s=14)
            ax.set(xlim=(x0-pad, x1+pad), ylim=(y1+pad, y0-pad), aspect='equal')
            ax.tick_params(labelsize=7)
            ax.set_title(wall['id'] + f'\nfloor {floor:.3f} m', fontsize=8)
            listed = sample.get('sourceObjects', [])
            desc = '\n'.join(f'{i} {metadata[i]["path"].split("/")[-2]}' for i in listed)
            ax.set_xlabel(desc[:400], fontsize=7)
            manifest.append(dict(wallId=wall['id'], sample=sample, sourceObjects=owners,
                                 file=f'unresolved-source-{start//6+1:02}.png'))
        for ax in axes.flat[len(unknown[start:start+6]):]:
            ax.axis('off')
        fig.suptitle(f'{name}: red unresolved ink, gray authored ink; source slices green floor - .1, blue + .1, gold eye')
        fig.savefig(directory / f'unresolved-source-{start//6+1:02}.png', dpi=110)
        plt.close(fig)
    (directory / 'unresolved-source-gallery.json').write_text(json.dumps(manifest, separators=(',', ':')))
    print(name, 'unresolved source crops', len(unknown), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='+')
    for name in parser.parse_args().maps:
        render(name)
