"""Read-only source context for Split's B generator and authored curved edge."""
import gzip
import hashlib
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np

from audit_all_map_wall_span_coverage import authored_spans
from render_split_remaining_corner_families import sections

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT / 'tactical-visibility-revision'


def main(out=None, object_ids=(6577, 6694)):
    out = out or REV / 'split-component8-source-review-v1'
    out.mkdir(exist_ok=False)
    raw_path = ROOT / 'supplemented-v2/world/split/geometry.npz'
    raw = np.load(raw_path)
    meta = json.loads(raw_path.with_suffix('.json').read_text())
    projection = ROOT / 'tactical-alignment-sides-v1/split.json'
    affine = np.array(json.loads(projection.read_text())['nativeToAttackSvg'])
    svg = Path('assets/maps/split_map.svg')
    spans = [(row, segment) for row, segment in authored_spans(svg)
             if row['elementIndex'] == 1 and row['subpath'] == 8]
    assert [r['span'] for r, _ in spans] == [202, 203, 204, 205]
    meshes, ids, objects = [], [], []
    for index in object_ids:
        obj = meta['objects'][index]
        face_ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        tri = raw['points'][raw['faces'][face_ids]].copy()
        tri[:, :, :2] = tri[:, :, :2] @ affine[:, :2].T + affine[:, 2]
        meshes.append(tri)
        ids.append(face_ids)
        objects.append(dict(index=index, **obj))
    curves = [np.array([[v.real, v.imag] for v in
              [segment.point(t) for t in np.linspace(0, 1, 1001)]]) for _, segment in spans]
    colors = ['#64748b', '#ea580c', '#16a34a', '#9333ea']
    assert len(meshes) <= len(colors)
    authored_covers = [
        [[56.3212,168.983],[56.3212,161.54],[63.764,161.54],[63.764,168.983]],
        [[69.6119,186.527],[69.6119,194.501],[77.5864,194.501],[77.5864,186.527]],
    ]
    fig = plt.figure(figsize=(17, 13))
    for index, angle in enumerate([-65, 120]):
        ax = fig.add_subplot(2, 3, 1 + index * 3, projection='3d')
        for mesh, color in zip(meshes, colors):
            ax.add_collection3d(Poly3DCollection(mesh, facecolors=color,
                               edgecolors=color, alpha=.13, linewidths=.12))
        whole = np.concatenate(meshes)
        lo, hi = whole.min((0, 1)), whole.max((0, 1))
        ax.set(xlim=(lo[0], hi[0]), ylim=(lo[1], hi[1]), zlim=(lo[2], hi[2]))
        ax.set_box_aspect((hi-lo) / [3.90962, 3.90962, 1])
        ax.view_init(elev=24, azim=angle)
        ax.set_title('Original generator6577 and adjacent source covers')
        ax.set_xlabel('Source SVG X'); ax.set_ylabel('Source SVG Y'); ax.set_zlabel('Raw source Z, m')
    section_records = []
    for slot, z in zip([2, 3, 5, 6], [4.75, 6.25, 8.75, 11.75]):
        ax = fig.add_subplot(2, 3, slot)
        rows = []
        for obj, mesh, color in zip(objects, meshes, colors):
            lines, _ = sections(mesh, z)
            ax.add_collection(LineCollection(lines, colors=color, linewidths=1.3,
                              label=str(obj['index'])))
            rows.append(dict(object=obj['index'], segments=np.asarray(lines).tolist()))
        for (record, _), curve in zip(spans, curves):
            ax.plot(*curve.T, color='#111827', linewidth=1.2)
            ax.text(*curve[len(curve)//2], str(record['span']), fontsize=9)
        for cover in authored_covers:
            ax.plot(*np.asarray(cover).T, color='#111827', linewidth=1.2)
        ax.set(xlim=(37, 81), ylim=(198, 158), title=f'Absolute source Z={z}m')
        ax.set_aspect('equal'); ax.grid(alpha=.2); ax.legend(fontsize=8)
        section_records.append(dict(z=z, objects=rows))
    fig.suptitle('Split component8 source context. Black is the actual authored contour, including cubic204.\n'
                 'Source geometry only; no blocker assignment, movement or height inference.')
    fig.tight_layout(h_pad=3)
    fig.savefig(out / 'generator-source-context.png', dpi=155)
    plt.close(fig)
    curve = spans[2][1]
    ypoly = np.poly1d(np.imag(curve.poly().coefficients))
    roots = np.roots(np.polyder(ypoly))
    ts = [0., 1.] + [float(t.real) for t in roots if abs(t.imag) < 1e-12 and 0 < t.real < 1]
    maximum = max(abs(ypoly(t)-curve.start.imag) for t in ts)
    report = dict(scope=__doc__, objects=objects, spans=[row for row, _ in spans],
        separatelyAuthoredCoverStrokes=authored_covers,
        cubic204=dict(controlPoints=[[v.real, v.imag] for v in
                        [curve.start, curve.control1, curve.control2, curve.end]],
                      maximumDistanceFromEndpointChordSvg=float(maximum),
                      deviationAtNative8xPixels=float(maximum * 8),
                      policy='Do not substitute the endpoint chord for this authored curve.'),
        inputs=[dict(path=str(p), sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                for p in [raw_path, raw_path.with_suffix('.json'), projection, svg]],
        productionMutation=False, sourceRolesAccepted=False)
    (out / 'source-context.json').write_text(json.dumps(report, indent=2))
    (out / 'source-sections.json.gz').write_bytes(gzip.compress(json.dumps(section_records).encode(), mtime=0))
    np.savez_compressed(out / 'full-source-context.npz', sourceFaceIds=np.concatenate(ids),
                       sourceObjectIds=np.concatenate([np.full(len(x), o['index']) for x, o in zip(ids, objects)]),
                       sourceTrianglesSvgZ=np.concatenate(meshes))
    print(json.dumps(report['cubic204'], indent=2))


if __name__ == '__main__':
    main()
