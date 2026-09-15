"""Show near-vertical prop faces against independent native Recast floor."""
import json
from pathlib import Path
import numpy as np
import shapely
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection


def main():
    root = Path('E:/IcarusWorldAudit/2026-09-06')
    directory = root / 'tactical-visibility-revision/steep-floor-support-audit-v1'
    out = directory / 'examples'; out.mkdir(exist_ok=True)
    worlds = {row['map']: row for row in json.loads((root / 'completeness/combined-manifest-release-inputs-v2.json').read_text())}
    for name, face_ids in [('corrode', [29876]), ('ascent', [785834, 785384])]:
        report = json.loads((directory / f'{name}.json').read_text())
        world = Path(worlds[name]['combinedWorldFolder'])
        metadata = json.loads((world / 'geometry.json').read_text())
        raw = np.load(world / 'geometry.npz'); vertices, faces = raw['points'], raw['faces']
        for face_id in face_ids:
            row = next(row for row in report['rows'] if row['fullPackFace'] == face_id)
            object_data = metadata['objects'][row['sourceObjectIndex']]
            mesh = vertices[faces[object_data['firstFace']:object_data['firstFace'] + object_data['faceCount']]]
            face = np.asarray(row['verticesNativeMeters'])
            np.testing.assert_allclose(face, vertices[faces[row['originalSourceFace']]], atol=1e-9, rtol=0)
            center = face.mean(axis=0)
            radius = max(float(np.ptp(mesh.reshape(-1, 3)[:, :2], axis=0).max()) * .7, .2)
            nav = np.asarray(row['nativeRecastComparison']['closestHeightPair']['navVerticesNativeMeters'])
            plane = np.linalg.solve(np.column_stack((nav[:, :2], np.ones(3))), nav[:, 2])
            clip = shapely.Polygon(nav[:, :2]).intersection(shapely.box(*(center[:2] - radius), *(center[:2] + radius)))
            nav_parts = []
            for triangle in shapely.get_parts(shapely.constrained_delaunay_triangles(clip)):
                xy = np.asarray(triangle.exterior.coords)[:3]
                nav_parts.append(np.column_stack((xy, xy @ plane[:2] + plane[2])))
            nav_parts = np.asarray(nav_parts).reshape(-1, 3, 3)
            figure = plt.figure(figsize=(12, 5))
            for position, azimuth in [(121, -45), (122, -135)]:
                ax = figure.add_subplot(position, projection='3d')
                ax.add_collection3d(Poly3DCollection(mesh, facecolors='#cbd5e1', edgecolors='#64748b', linewidths=.25, alpha=.45))
                ax.add_collection3d(Poly3DCollection(face[None], facecolors='#ef4444', edgecolors='#991b1b', linewidths=1.2))
                ax.add_collection3d(Poly3DCollection(nav_parts, facecolors='#60a5fa', edgecolors='#1d4ed8', linewidths=.6, alpha=.4))
                all_points = np.concatenate((mesh.reshape(-1, 3), nav_parts.reshape(-1, 3)))
                low, high = all_points.min(axis=0), all_points.max(axis=0)
                ax.set_xlim(center[0] - radius, center[0] + radius); ax.set_ylim(center[1] - radius, center[1] + radius); ax.set_zlim(low[2] - .03, high[2] + .03)
                ax.set_box_aspect([radius * 2, radius * 2, max(high[2] - low[2], .1)]); ax.view_init(elev=24, azim=azimuth)
                ax.set_xlabel('native X, m'); ax.set_ylabel('native Y, m'); ax.set_zlabel('Z, m')
            difference = row['nativeRecastComparison']['minimumGradientMismatchWithin35cm']
            figure.suptitle(f"{name.upper()} face {face_id}: admitted source face red, prop gray, original Recast floor blue\n{row['objectPath']}", fontsize=10)
            figure.text(.5, .02, f"source normal Z = {row['normalZ']:.6f}; projected area = {row['projectedAreaMeters2']:.7f} m²; minimum native-nav gradient mismatch = {difference:.2f} m/m", ha='center', fontsize=9)
            figure.tight_layout(rect=(0, .05, 1, .92)); figure.savefig(out / f'{name}-{face_id}.png', dpi=160); plt.close(figure)
            (out / f'{name}-{face_id}.json').write_text(json.dumps(row, indent=2))
            print(name, face_id, flush=True)


if __name__ == '__main__':
    main()
