"""Render source geometry and measured nav progression for role review."""
import argparse
import json
from pathlib import Path
import textwrap
import numpy as np
import shapely
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from PIL import Image, ImageOps, ImageDraw
from probe_source_floor_regressions import load_support


def clip_mesh_xy(triangles, low, high):
    result = []
    for triangle in triangles:
        polygon = list(triangle)
        for axis, threshold, sign in [(0, low[0], 1), (0, high[0], -1), (1, low[1], 1), (1, high[1], -1)]:
            clipped = []
            for start, end in zip(polygon, polygon[1:] + polygon[:1]):
                first, second = (start[axis] - threshold) * sign >= 0, (end[axis] - threshold) * sign >= 0
                if first:
                    clipped.append(start)
                if first != second:
                    fraction = (threshold - start[axis]) / (end[axis] - start[axis])
                    clipped.append(start + fraction * (end - start))
            polygon = clipped
            if not polygon:
                break
        for index in range(1, len(polygon) - 1):
            candidate = np.array([polygon[0], polygon[index], polygon[index + 1]])
            if np.linalg.norm(np.cross(candidate[1] - candidate[0], candidate[2] - candidate[0])) > 1e-15:
                result.append(candidate)
    return np.asarray(result).reshape(-1, 3, 3)


def render(root, name, maximum):
    revision = root / 'tactical-visibility-revision'
    directory = revision / 'competing-floor-assemblies-v3'
    report = json.loads((directory / f'{name}.json').read_text())
    source = load_support(revision, name, True)
    world = next(row for row in json.loads((root / 'completeness/combined-manifest-release-inputs-v2.json').read_text()) if row['map'] == name)
    raw = np.load(Path(world['combinedWorldFolder']) / 'geometry.npz')
    raw_points, raw_faces = raw['points'], raw['faces']
    candidates = [row for row in report['records'] if row.get('terrainReviewQueue', {}).get('priority')]
    chosen = list((candidates or report['records'])[:maximum])
    # Known stair is a positive review control. Props are explicit negative
    # review candidates, not automatically excluded by their labels.
    for row in report['records']:
        if 'AsiteRampToPlatform' in row['objectPath'] and row not in chosen:
            chosen.append(row)
    low = next((row for row in report['records'] if any(part in row['objectPath'].lower() for part in ('crate', 'bench', 'rock')) and row not in chosen), None)
    if low:
        chosen.append(low)
    output = directory / 'visuals'
    output.mkdir(exist_ok=True)
    images = []
    manifest = []
    for number, row in enumerate(chosen):
        ids = np.asarray(row['admittedSupportIndices'])
        triangles = source.points[ids]
        object_data = row['sourceObject']
        mesh_ids = np.arange(object_data['firstFace'], object_data['firstFace'] + object_data['faceCount'])
        mesh = raw_points[raw_faces[mesh_ids]]
        queue = row.get('terrainReviewQueue', {})
        source_only = bool(queue.get('examples'))
        examples = queue['examples'] if source_only else row['examples']
        overlap = shapely.from_geojson(queue['sourceSourceClimbBandFootprint'] if source_only else row['overlapFootprintNativeGeojson'])
        extent = np.array(overlap.bounds)
        center = np.asarray(examples[0]['nativeXY'])
        cropped = np.all((mesh[:, :, :2].max(axis=1) >= center - 4) & (mesh[:, :, :2].min(axis=1) <= center + 4), axis=1)
        crop_mesh = clip_mesh_xy(mesh[cropped], center - 4, center + 4)
        lower_parts = []
        for example in examples:
            a, b = example['upperSupportIndex'], example['lowerSupportIndex']
            footprint = source.polygons[a].intersection(source.polygons[b])
            plane = source.planes[a] - source.planes[b]
            for direction, threshold in [(plane, .05), (-plane, -.35)]:
                normal = direction[:2]
                length = np.linalg.norm(normal)
                if length > 1e-12:
                    boundary = -(direction[2] - threshold) * normal / length ** 2
                    unit = normal / length
                    tangent = np.array([-unit[1], unit[0]])
                    half_plane = shapely.Polygon([boundary - tangent * 1e5, boundary + tangent * 1e5, boundary + tangent * 1e5 + unit * 1e5, boundary - tangent * 1e5 + unit * 1e5])
                    footprint = footprint.intersection(half_plane)
                elif direction[2] < threshold - 1e-10:
                    footprint = shapely.GeometryCollection()
                    break
            footprint = footprint.intersection(shapely.box(*(center - 4), *(center + 4)))
            for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(footprint)):
                xy_part = np.array(piece.exterior.coords)[:3]
                lower_parts.append(np.column_stack((xy_part, xy_part @ source.planes[b, :2] + source.planes[b, 2])))
        lower = np.asarray(lower_parts).reshape(-1, 3, 3)
        figure = plt.figure(figsize=(14, 5), facecolor='#fafafa')
        ax = figure.add_subplot(131)
        values = triangles[:, :, 2].mean(axis=1)
        collection = PolyCollection(triangles[:, :, :2], array=values, cmap='viridis', linewidths=.1, edgecolors='#334155')
        ax.add_collection(collection)
        ax.autoscale_view()
        ax.set_aspect('equal')
        for polygon in shapely.get_parts(overlap):
            if polygon.geom_type == 'Polygon':
                xy = np.array(polygon.exterior.coords)
                ax.plot(xy[:, 0], xy[:, 1], color='#ef4444', linewidth=.8)
        ax.scatter(*center, marker='x', color='#dc2626', s=45)
        ax.set_title('Red = source/source climb-band conflict' if source_only else 'Admitted source floor; red = source/nav conflict', fontsize=9)
        ax.set_xlabel('native X, m'); ax.set_ylabel('native Y, m')
        figure.colorbar(collection, ax=ax, fraction=.04, label='source floor Z, m')
        ax3 = figure.add_subplot(132, projection='3d')
        z = crop_mesh[:, :, 2].mean(axis=1)
        colors = plt.cm.viridis((z - z.min()) / max(float(np.ptp(z)), 1e-6))
        ax3.add_collection3d(Poly3DCollection(crop_mesh, facecolors=colors, edgecolors='#475569', linewidths=.12, alpha=.9))
        ax3.add_collection3d(Poly3DCollection(lower, facecolors='#f87171', edgecolors='#991b1b', linewidths=.4, alpha=.45))
        all_points = np.concatenate([crop_mesh.reshape(-1, 3), lower.reshape(-1, 3)])
        bottom, top = all_points.min(axis=0), all_points.max(axis=0)
        ax3.set_xlim(center[0] - 4, center[0] + 4); ax3.set_ylim(center[1] - 4, center[1] + 4)
        ax3.set_zlim(bottom[2] - .1, max(top[2], bottom[2] + 1))
        ax3.set_box_aspect([8, 8, max(float(top[2] - bottom[2]), 1)])
        ax3.view_init(elev=28, azim=-50)
        ax3.set_title('Full source object; competing source floor red' if source_only else 'Full source object; competing source/nav floor red', fontsize=9)
        ax3.set_xlabel('X'); ax3.set_ylabel('Y'); ax3.set_zlabel('Z, m')
        axp = figure.add_subplot(133)
        samples = row['detailedNavProgressionExamples']
        xy = triangles[:, :, :2].reshape(-1, 2)
        _, _, vt = np.linalg.svd(xy - xy.mean(axis=0), full_matrices=False)
        axis = vt[0]
        along = (triangles[:, :, :2].mean(axis=1) - xy.mean(axis=0)) @ axis
        axp.scatter(along, values, color='#15803d', s=5, alpha=.4, label='admitted source triangles')
        if samples:
            sample_xyz = np.asarray([sample['nativeSourceXYZ'] for sample in samples])
            nav_z = np.asarray([sample['detailedNavHeightMeters'] for sample in samples])
            axp.scatter((sample_xyz[:, :2] - xy.mean(axis=0)) @ axis, nav_z, color='#111827', marker='x', s=50, label='source-refined detailed nav')
        axp.set_title(f"Source-refined nav span {row['detailedNavMatchedHeightSpanMeters']:.2f} m", fontsize=9)
        axp.set_xlabel('distance along assembly principal axis, m'); axp.set_ylabel('floor Z, m')
        axp.grid(alpha=.2); axp.legend(fontsize=7)
        figure.suptitle('\n'.join(textwrap.wrap(f"{name.upper()} | {row['objectPath']} | object {row['sourceObjectIndex']} | UNCLASSIFIED", 130)), fontsize=11, x=.5, y=.99)
        figure.text(.5, .01, f"{len(ids)} admitted faces | overlap upper bound {row['overlapFootprintAreaUpperBoundMeters2']:.2f} m² | max competing gap {row['gapMaximumMeters']:.2f} m | positive-area overlap is not proof of terrain role", ha='center', fontsize=8)
        figure.tight_layout(rect=(0, .035, 1, .92))
        path = output / f'{name}-{number + 1:02d}.png'
        figure.savefig(path, dpi=140)
        plt.close(figure)
        images.append(path)
        manifest.append({'image': str(path), 'objectPath': row['objectPath'], 'sourceObjectIndex': row['sourceObjectIndex'], 'sourceFirstFace': row['sourceObject']['firstFace'], 'priority': row['reviewPriority']})
    thumbnails = []
    for path in images:
        with Image.open(path) as image:
            thumbnails.append(ImageOps.contain(image.convert('RGB'), (1400, 500)))
    sheet = Image.new('RGB', (1400, sum(image.height for image in thumbnails)), '#ffffff')
    y = 0
    for image in thumbnails:
        sheet.paste(image, (0, y)); y += image.height
    sheet.save(output / f'{name}-sheet.png')
    (output / f'{name}-manifest.json').write_text(json.dumps(manifest, indent=2))
    print(name, 'rendered', len(images), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('maps', nargs='+')
    parser.add_argument('--maximum', type=int, default=3)
    args = parser.parse_args()
    for name in args.maps:
        render(Path('E:/IcarusWorldAudit/2026-09-06'), name, args.maximum)
