"""Source-wall sections and exact instance meshes for bounded normalization review."""
import json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from tactical_alignment_audit import pack,section,vector_lines
from render_competing_floor_assemblies import clip_mesh_xy
ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
def main():
    out=REV/'split-wall-family-normalization-v1';out.mkdir(exist_ok=True)
    meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text());raw=np.load(ROOT/'supplemented-v2/world/split/geometry.npz');points,faces=raw['points'],raw['faces']
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg']);matrix,origin=affine[:,:2],affine[:,2]
    _,arrays=pack(REV/'global-ground-complete-v2/split/split.height.bin.gz');segments,ids=section(arrays,1.75,False);segments=segments@matrix.T+origin
    lines=vector_lines(Path('assets/maps/split_map.svg'))
    for name,edges,objects,bounds in [('ramp',[105,106,107],[7898,7897,7864,7866,7874,4882,4952,4948,7932],[285,275,372,320]),('clove',[175,176,177],[7790,7791,7792,4665,4666,4714,4774],[206,176,262,201])]:
        fig=plt.figure(figsize=(17,7));ax=fig.add_subplot(121)
        keep=np.all((segments.max(axis=1)>=np.array(bounds[:2]))&(segments.min(axis=1)<=np.array(bounds[2:])),axis=1)
        for line in segments[keep]:ax.plot(*line.T,color='#94a3b8',linewidth=.5)
        for edge in edges:
            line=lines[edge];ax.plot(*line.T,color='#ea580c',linewidth=2);ax.text(*line.mean(axis=0),str(edge),color='#c2410c',fontsize=11)
        ax.set_xlim(bounds[0],bounds[2]);ax.set_ylim(bounds[3],bounds[1]);ax.set_aspect('equal');ax.set_title('Control 1.75m section gray; exact SVG wall orange');ax.set_xlabel('Attack SVG X');ax.set_ylabel('Attack SVG Y')
        ax3=fig.add_subplot(122,projection='3d');meshes=[]
        for slot,index in enumerate(objects):
            obj=meta['objects'][index];mesh=points[faces[obj['firstFace']:obj['firstFace']+obj['faceCount']]].copy();mesh[:,:,:2]=mesh[:,:,:2]@matrix.T+origin
            mesh=clip_mesh_xy(mesh,np.array(bounds[:2]),np.array(bounds[2:]));meshes.append(mesh)
            color=plt.cm.tab10(slot%10);ax3.add_collection3d(Poly3DCollection(mesh,facecolors=color,edgecolors='#334155',linewidths=.08,alpha=.5 if slot<2 else .9))
            if len(mesh):ax3.text(*mesh.reshape(-1,3).mean(axis=0),str(index),fontsize=8)
        allpoints=np.concatenate([m.reshape(-1,3) for m in meshes if len(m)]);low,high=allpoints.min(axis=0),allpoints.max(axis=0);ax3.set_xlim(low[0],high[0]);ax3.set_ylim(low[1],high[1]);ax3.set_zlim(low[2],high[2]);ax3.set_box_aspect([high[0]-low[0],high[1]-low[1],(high[2]-low[2])*3.91]);ax3.view_init(25,-70)
        ax3.set_xlabel('Attack SVG X');ax3.set_ylabel('Attack SVG Y');ax3.set_zlabel('Original native Z, m');ax3.set_title('Exact original source families, retained separate by instance')
        fig.suptitle(f'Split {name}: full spans and corners before normalization. No source changes.')
        fig.tight_layout();fig.savefig(out/f'{name}-source-review.png',dpi=150);plt.close(fig)
    print(out)
if __name__=='__main__':main()
