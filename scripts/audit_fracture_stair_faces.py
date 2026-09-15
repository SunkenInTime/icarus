"""Show every proposed stair support face, including steep bevels."""
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from probe_source_floor_regressions import load_support


def main():
    revision = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    role_path = revision / 'source-floor-audited-terrain-v1/fracture.terrain-role.json'
    role = json.loads(role_path.read_text())
    support = load_support(revision, 'fracture', True)
    ids = np.flatnonzero(np.isin(support.source_ids, role['fullPackFaceIds']))
    assert len(ids) == len(role['fullPackFaceIds'])
    points = support.points[ids]
    normals = np.cross(points[:, 1] - points[:, 0], points[:, 2] - points[:, 0])
    length = np.linalg.norm(normals, axis=1)
    normals /= length[:, None]
    group = np.where(normals[:, 2] >= .999999, 0, np.where(normals[:, 2] >= .65, 1, 2))
    colors = np.array(['#059669', '#2563eb', '#dc2626'])[group]
    nav_ids = support.detailed_navigation_indices
    nav_tree = shapely.STRtree(support.polygons[nav_ids])
    records = []
    for index, triangle in enumerate(points):
        samples = np.vstack((triangle, triangle.mean(axis=0)))
        owners, local_nav = nav_tree.query(shapely.points(samples[:, :2]), predicate='intersects')
        predicted = np.sum(samples[owners, :2] * support.planes[nav_ids[local_nav], :2], axis=1) + support.planes[nav_ids[local_nav], 2]
        residual = samples[owners, 2] - predicted
        records.append({'fullPackFace': int(support.source_ids[ids[index]]), 'supportIndex': int(ids[index]), 'verticesNativeMeters': triangle.tolist(), 'normal': normals[index].tolist(), 'normalGroup': ['horizontal', 'slope-normalZ-at-least-.65', 'steep-bevel-normalZ-below-.65'][group[index]], 'areaMeters2': float(length[index] / 2), 'projectedAreaMeters2': float(abs(length[index] * normals[index, 2]) / 2), 'heightRangeMeters': [float(triangle[:, 2].min()), float(triangle[:, 2].max())], 'navSampleCount': len(owners), 'minimumAbsoluteNavResidualMeters': float(np.min(abs(residual))) if len(residual) else None, 'navResidualRangeMeters': [float(residual.min()), float(residual.max())] if len(residual) else None})
    out = revision / 'fracture-stair-role-face-audit-v1'
    out.mkdir(exist_ok=True)
    report = {'roleManifestSha256': hashlib.sha256(role_path.read_bytes()).hexdigest(), 'supportSha256': role['supportSha256'], 'productionMutation': False, 'roleNotModified': True, 'groups': {label: int(np.sum(group == i)) for i, label in enumerate(['horizontal', 'slope', 'steep-bevel'])}, 'scope': 'Every face in existing175-face bounded stair role manifest. Normal groups are review categories only; no automatic exclusion. Nav samples include actual detailed floors at vertices/centroid and report all intersecting layers.', 'faces': records}
    (out / 'faces.json').write_text(json.dumps(report, indent=2))
    figure = plt.figure(figsize=(16, 5))
    ax = figure.add_subplot(131)
    ax.add_collection(PolyCollection(points[:, :, :2], facecolors=colors, edgecolors='#334155', linewidths=.25))
    ax.autoscale_view(); ax.set_aspect('equal'); ax.set_xlabel('X, m'); ax.set_ylabel('Y, m'); ax.set_title('All175 admitted faces, top view')
    bounds = [points.reshape(-1, 3).min(axis=0), points.reshape(-1, 3).max(axis=0)]
    for slot, azimuth in [(132, -45), (133, -135)]:
        ax3 = figure.add_subplot(slot, projection='3d')
        ax3.add_collection3d(Poly3DCollection(points, facecolors=colors, edgecolors='#334155', linewidths=.22))
        ax3.set_xlim(bounds[0][0], bounds[1][0]); ax3.set_ylim(bounds[0][1], bounds[1][1]); ax3.set_zlim(bounds[0][2], bounds[1][2]); ax3.set_box_aspect(bounds[1] - bounds[0]); ax3.view_init(elev=25, azim=azimuth)
        ax3.set_xlabel('X'); ax3.set_ylabel('Y'); ax3.set_zlabel('Z, m'); ax3.set_title('Source support from opposite sides')
    figure.suptitle('Fracture stair role review:122 horizontal green;38 slopes blue;15 steep/bevel red. No role changes.')
    figure.tight_layout(); figure.savefig(out / 'all175-faces.png', dpi=150); plt.close(figure)
    figure = plt.figure(figsize=(15, 10))
    steep_ids = np.flatnonzero(group == 2)
    for panel, selected in enumerate(steep_ids):
        ax = figure.add_subplot(3, 5, panel + 1, projection='3d')
        center = points[selected].mean(axis=0)
        local = np.linalg.norm(points.mean(axis=1) - center, axis=1) < .65
        ax.add_collection3d(Poly3DCollection(points[local], facecolors='#cbd5e1', edgecolors='#64748b', linewidths=.2, alpha=.5))
        ax.add_collection3d(Poly3DCollection(points[selected:selected + 1], facecolors='#dc2626', edgecolors='#7f1d1d', linewidths=.8))
        local_points = np.vstack((points[local].reshape(-1, 3), points[selected]))
        low, high = local_points.min(axis=0) - .02, local_points.max(axis=0) + .02
        ax.set_xlim(low[0], high[0]); ax.set_ylim(low[1], high[1]); ax.set_zlim(low[2], high[2]); ax.set_box_aspect(np.maximum(high - low, .15)); ax.view_init(elev=25, azim=-50)
        ax.set_title(f"face{records[selected]['fullPackFace']} | nZ{normals[selected, 2]:.4f}\nXY area{records[selected]['projectedAreaMeters2']:.6f}m²", fontsize=8)
        ax.tick_params(labelsize=5)
    figure.suptitle('Each proposed steep/bevel support face in red, neighboring admitted source in gray')
    figure.tight_layout(); figure.savefig(out / 'steep15-closeups.png', dpi=150); plt.close(figure)
    print(report['groups'])


if __name__ == '__main__':
    main()
