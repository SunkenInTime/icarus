"""Full source/depth context for the remaining original-scene wall contacts."""
import gzip
import hashlib
import json
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from build_split_connected_tower import ROOT, REV
from render_competing_floor_assemblies import clip_mesh_xy
from render_split_remaining_corner_families import sections


def main():
    out = REV / 'split-component7-catwalk-join-review-v1'
    out.mkdir(exist_ok=True)
    proposals = [json.loads(gzip.decompress((REV / f'split-connected-contour-proposals-v2/component-{c}.json.gz').read_bytes())) for c in [7]]
    path = ROOT / 'supplemented-v2/world/split/geometry.npz'
    raw = np.load(path)
    metadata = json.loads(path.with_suffix('.json').read_text())
    affine = np.array(json.loads((ROOT / 'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg'])
    groups = [('hostel-catwalk-join', [6727,7205,6966,6831,6948,6994], [108,128,124,145], [7.25,8.25,9.75,11.75])]
    rows = []
    for name, object_ids, box, heights in groups:
        triangles, ids, owners, objects = {}, [], [], []
        for obj in object_ids:
            item = metadata['objects'][obj]
            faces = np.arange(item['firstFace'], item['firstFace']+item['faceCount'])
            tri = raw['points'][raw['faces'][faces]].copy()
            tri[:, :, :2] = tri[:, :, :2] @ affine[:, :2].T + affine[:, 2]
            triangles[obj] = tri
            ids.extend(faces.tolist())
            owners.extend([obj]*len(faces))
            objects.append(dict(index=obj, **item, projectedBounds=np.stack((tri.min((0,1)), tri.max((0,1)))).tolist()))
        np.savez_compressed(out / f'{name}-full-source.npz', sourceFaceIds=np.array(ids), sourceObjectIds=np.array(owners), trianglesSvgSourceZ=np.concatenate(list(triangles.values())))
        colors = {obj:plt.cm.tab20(i) for i,obj in enumerate(object_ids)}
        clipped = {obj:clip_mesh_xy(tri, np.array(box[:2]), np.array(box[2:])) for obj,tri in triangles.items()}
        figure = plt.figure(figsize=(19,12))
        for index in range(2):
            ax = figure.add_subplot(2,3,1+3*index,projection='3d')
            for obj,tri in clipped.items():
                ax.add_collection3d(Poly3DCollection(tri, facecolors=colors[obj], edgecolors=colors[obj], alpha=.3, linewidths=.14))
            ax.set_xlim(box[0],box[2]); ax.set_ylim(box[1],box[3]); ax.set_zlim(5,16)
            ax.view_init(25,-65 if index == 0 else 115)
            ax.set_box_aspect([box[2]-box[0],box[3]-box[1],11*3.91])
            ax.set_xlabel('Source SVG X'); ax.set_ylabel('Source SVG Y'); ax.set_zlabel('Original source Z, m')
            ax.set_title('Original source, connected depth view')
        for slot,z in zip([2,3,5,6],heights):
            ax = figure.add_subplot(2,3,slot)
            for proposal in proposals:
                for span in proposal['spans']:
                    line = np.array(span['authoredEndpoints'])
                    if (line.max(0)>=box[:2]).all() and (line.min(0)<=box[2:]).all():
                        ax.plot(*line.T,color='#111827',lw=2)
                        ax.text(*line.mean(0),str(span['completeSpan']),fontsize=8,clip_on=True)
            for obj,tri in clipped.items():
                lines,_ = sections(tri,z)
                if len(lines): ax.add_collection(LineCollection(lines, colors=[colors[obj]], lw=1.1, label=f'{obj} {metadata["objects"][obj]["path"].split("/")[-2]}'))
            ax.set_xlim(box[0],box[2]); ax.set_ylim(box[3],box[1]); ax.set_aspect('equal'); ax.grid(alpha=.2)
            ax.set_title(f'Original absolute Z={z:g}m')
            ax.legend(fontsize=6,loc='best')
        figure.suptitle(name+' | Full-instance source packet, finite view only. No mapping or ownership decision.\nBlack is authored contour. Sections show source triangles without opacity sampling; height cuts do not assert standing support.')
        figure.tight_layout(rect=[0,0,1,.95])
        figure.savefig(out / f'{name}.png',dpi=160)
        plt.close(figure)
        rows.append(dict(group=name,viewBox=box,sourceObjects=objects,sourceFaceCount=len(ids),sourcePacket=f'{name}-full-source.npz'))
    (out / 'source-context.json').write_text(json.dumps(dict(sourceGeometrySha256=hashlib.sha256(path.read_bytes()).hexdigest(),groups=rows,scope='Read-only full source instances at the component 7 hostel/catwalk continuation. Finite plots do not authorize whole-object normalization.'),indent=2))
    print(out)


if __name__ == '__main__':
    main()
