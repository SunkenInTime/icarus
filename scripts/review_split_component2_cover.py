"""Exact attached cover context and shared wall datum proposal, no bake."""
import gzip,json,hashlib
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from build_split_connected_tower import ROOT,REV
from render_competing_floor_assemblies import clip_mesh_xy
from render_split_remaining_corner_families import sections

def main():
    out=REV/'split-component2-cover-review-v1';out.mkdir(exist_ok=True);path=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(path);meta=json.loads(path.with_suffix('.json').read_text());affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg']);obj=meta['objects'][5803];ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount']);cover=raw['points'][raw['faces'][ids]].copy();cover[:,:,:2]=cover[:,:,:2]@affine[:,:2].T+affine[:,2]
    body=np.load(REV/'split-component2-source-review-v1/full-objects-source-packet.npz')['sourceSvgTriangles'];body=clip_mesh_xy(body,np.array([413.,132.]),np.array([427.,146.]));lo=cover.min((0,1));hi=cover.max((0,1));authored=np.array([[417.298,134.959],[417.298,142.933],[424.741,142.933],[424.741,134.959]])
    fig=plt.figure(figsize=(16,11))
    for i in range(2):
        ax=fig.add_subplot(2,3,1+i*3,projection='3d');ax.add_collection3d(Poly3DCollection(body,facecolors='#94a3b8',edgecolors='#64748b',alpha=.18,linewidths=.15));ax.add_collection3d(Poly3DCollection(cover,facecolors='#f97316',edgecolors='#9a3412',alpha=.65,linewidths=.35));ax.set_xlim(413,427);ax.set_ylim(132,146);ax.set_zlim(-.1,8.5);ax.view_init(24,-65 if i==0 else 110);ax.set_title('Original5803 cover beside shell');ax.set_xlabel('Pre-W SVG X');ax.set_ylabel('Pre-W SVG Y');ax.set_zlabel('Absolute source Z,m')
    for i,z in enumerate([.75,1.75,3.5,4.1]):
        ax=fig.add_subplot(2,3,[2,3,5,6][i]);ax.plot([413,424.741,424.741],[134.959,134.959,132],color='#111827',lw=2,label='Authored shell');ax.plot(*authored.T,color='#2563eb',lw=2,label='Actual authored cover stroke')
        for mesh,color,label in [(body,'#64748b','Original shell'),(cover,'#f97316','Original cover')]:
            lines,_=sections(mesh,z);ax.add_collection(LineCollection(lines,colors=color,lw=1.3,label=label))
        ax.set_xlim(413,427);ax.set_ylim(146,132);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f'Raw source Z={z}m');ax.legend(fontsize=7)
    fig.suptitle('Attached cover5803, complete124-face source profile. Blue is its separately authored SVG stroke.\nNo extrusion, mapping or role change applied in this packet.',fontsize=12);fig.tight_layout(rect=[0,0,1,.94]);fig.savefig(out/'cover-source-context.png',dpi=160);plt.close(fig)
    np.savez_compressed(out/'cover-source.npz',sourceFaceIds=ids,sourceTrianglesSvgZ=cover)
    body_left,body_right=390.7150310866566,423.94680343336705
    old_left_target=392.311+(lo[0]-body_left)/(body_right-body_left)*(424.741-392.311)
    report=dict(sourceGeometrySha256=hashlib.sha256(path.read_bytes()).hexdigest(),sourceObject=dict(index=5803,**obj),sourceFaceIds=ids.tolist(),sourceBoundsSvgZ=[lo.tolist(),hi.tolist()],authoredStroke=authored.tolist(),proposal=dict(wholeObject=True,preserveSourceZAndUv=True,sharedTopDatum=134.959,sharedRightDatum=424.741,existingBodyMappedCoverLeft=float(old_left_target),authoredCoverLeft=417.298,bodyAlongChangeNeededSvg=float(417.298-old_left_target),mapping='Add the exact source cover-left X as a shared tangent-coordinate knot in the body region and the cover region. Both use the same right endpoint and contact-plane Y datum. Cover extends down to its own authored142.933 edge; shell roof overhang retains its reviewed wall-depth collapse. Different height profiles remain separate.',unresolved='Confirm exact source structural face planes versus outer cover bevels before choosing the source rectangle bounds.'))
    (out/'source-and-shared-datum.json').write_text(json.dumps(report,indent=2));print(out);print('bounds',lo,hi,'existingBodyMappedLeft',old_left_target)

if __name__=='__main__':main()
