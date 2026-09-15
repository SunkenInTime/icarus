"""Exact source review packets for short or unresolved Ascent component returns."""
import gzip
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT, REV, OUT


def main():
    folder = REV/'ascent-connected-contour-proposals-v1'
    raw_path = ROOT/'supplemented-v2/world/ascent/geometry.npz'
    raw = np.load(raw_path)
    meta = json.loads(raw_path.with_suffix('.json').read_text())
    affine = np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg'])
    coverage = json.loads(gzip.decompress((REV/'all-map-wall-span-coverage-v1/ascent/attack.coverage.json.gz').read_bytes()))
    components = [json.loads(gzip.decompress((folder/f'component-{c}.json.gz').read_bytes())) for c in [5, 7]]
    cases = []
    for span in [138, 148, 184, 191, 194, 199, 208]:
        row = next(r for c in components for r in c['spans'] if r['completeSpan'] == span)
        line = np.array(row['authoredEndpoints'])
        o = line[0]
        t = line[1]-o
        length = np.linalg.norm(t)
        t /= length
        n = np.array([-t[1], t[0]])
        samples = [r for r in coverage['samples'] if r['span'] == span and r.get('originalSourceFace') is not None]
        objects = sorted({r['sourceObjectIndex'] for r in samples})
        ids, triangles, owners = [], [], []
        for obj in objects:
            ob = meta['objects'][obj]
            source_ids = np.arange(ob['firstFace'], ob['firstFace']+ob['faceCount'])
            xyz = raw['points'][raw['faces'][source_ids]].copy()
            xyz[:, :, :2] = xyz[:, :, :2] @ affine[:, :2].T + affine[:, 2]
            along, depth = (xyz[:, :, :2]-o) @ t, (xyz[:, :, :2]-o) @ n
            near = (along.max(1) >= -2) & (along.min(1) <= length+2) & (depth.max(1) >= -3) & (depth.min(1) <= 3)
            ids.extend(source_ids[near].tolist())
            triangles.extend(xyz[near].tolist())
            owners.extend([obj]*int(near.sum()))
        xyz = np.array(triangles)
        ids, owners = np.array(ids, dtype=np.int64), np.array(owners, dtype=np.int64)
        packet = OUT/f'return-{span}-source-context.npz'
        np.savez_compressed(packet, sourceFaces=ids, sourceObjects=owners, sourceTrianglesSvgZ=xyz, authoredEndpoints=line)
        fig = plt.figure(figsize=(13, 6))
        ax = fig.add_subplot(121)
        view = fig.add_subplot(122, projection='3d')
        for i, obj in enumerate(objects):
            selected = xyz[owners == obj]
            color = plt.get_cmap('tab10')(i % 10)
            for tri in selected:
                ax.plot(*np.vstack((tri[:, :2], tri[:1, :2])).T, color=color, alpha=.2, lw=.5)
            ax.plot([], [], color=color, label=f"{obj}: {meta['objects'][obj]['path'].split('/')[1]}")
            if len(selected):
                view.add_collection3d(Poly3DCollection(selected, facecolor=color, edgecolor=color, alpha=.16, linewidth=.15))
        ax.plot(*line.T, color='black', lw=3, label=f'SVG span {span}')
        ax.set_xlim(line[:, 0].min()-4, line[:, 0].max()+4)
        ax.set_ylim(line[:, 1].max()+4, line[:, 1].min()-4)
        ax.set_aspect('equal')
        ax.legend(fontsize=7)
        ax.set_title('Exact source context; unchanged authored edge in black')
        if len(xyz):
            lo, hi = xyz.min((0, 1)), xyz.max((0, 1))
            view.set_xlim(lo[0], hi[0]); view.set_ylim(lo[1], hi[1]); view.set_zlim(lo[2], hi[2])
            view.set_box_aspect(np.maximum(hi-lo, .1))
        view.view_init(elev=26, azim=-50)
        view.set_xlabel('Source SVG X'); view.set_ylabel('Source SVG Y'); view.set_zlabel('Original Z, m')
        view.set_title('Original source geometry, including distinct props')
        fig.suptitle(f'Ascent return {span}: no ownership or opaque fill inferred')
        fig.tight_layout(rect=[0, 0, 1, .95])
        image = OUT/f'return-{span}-source-review.png'
        fig.savefig(image, dpi=180)
        plt.close(fig)
        cases.append(dict(span=span, authoredEndpoints=line.tolist(), componentProposal=row, sourceContext=str(packet), sourceContextSha256=sha(packet), sourceObjects=[dict(index=o, path=meta['objects'][o]['path']) for o in objects], sourceSamples=samples, image=str(image), reviewStatus='Requires personal source-role decision; sparse sampling flag is retained.'))
    report = dict(format='icarus-unresolved-return-source-review-v1', sourceGeometrySha256=meta['geometrySha256'], sourceFileSha256=sha(raw_path), componentSummarySha256=sha(folder/'summary.json'), scriptSha256=sha(Path(__file__)), cases=cases, productionMutation=False)
    (OUT/'short-return-source-review.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps([dict(span=c['span'], sourceObjects=c['sourceObjects']) for c in cases], indent=2))


if __name__ == '__main__':
    main()
