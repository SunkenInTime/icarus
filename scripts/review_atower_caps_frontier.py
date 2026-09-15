"""Read-only exact source cap categories and the connected tower return frontier."""
import json
import hashlib
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from tactical_alignment_audit import vector_lines
from render_competing_floor_assemblies import clip_mesh_xy

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'

def main():
    out=REV/'split-multiplane-corner-proposals-v1'
    raw=np.load(ROOT/'supplemented-v2/world/split/geometry.npz');p,f=raw['points'],raw['faces']
    meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text())
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg'])
    lines=vector_lines(Path('assets/maps/split_map.svg'))
    proposal=json.loads((out/'atower-connected-profile-proposal.json').read_text())
    cats=[('Box ledges, edge85 depth', [1896459,1896460,1896461,1896462],85),
          ('Long horizontal and sloped ledges, edge86 depth',[1896425,1896426,1896427,1896428,1896431,1896432,1896435,1896436,1896448,1896449],86),
          ('Upper box roof and side continuation',[1896414,1896403,1896404,1896419,1896420],None)]
    records=[];fig=plt.figure(figsize=(17,12))
    for row,(title,ids,owner) in enumerate(cats):
        rawxyz=p[f[ids]].copy();rawxyz[:,:,:2]=rawxyz[:,:,:2]@affine[:,:2].T+affine[:,2]
        clipped_ids=[];pieces=[]
        bounds=[324.2514863932356,183.078124196902,332.10036,185.482]
        for fid,tri in zip(ids,rawxyz):
            clipped=clip_mesh_xy(np.array([tri]),np.array(bounds[:2]),np.array(bounds[2:]))
            pieces.extend(clipped);clipped_ids.extend([fid]*len(clipped))
        xyz=np.array(pieces)
        for col in range(2):
            ax=fig.add_subplot(3,2,row*2+col+1,projection='3d' if col==0 else None)
            for i,(fid,tri) in enumerate(zip(clipped_ids,xyz)):
                c=plt.cm.tab20(i)
                if col==0:
                    ax.add_collection3d(Poly3DCollection([tri],facecolors=[c],edgecolors='#334155',alpha=.75,linewidths=.7))
                    ax.text(*tri.mean(0),str(fid),fontsize=6)
                else:
                    ax.fill(tri[:,0],tri[:,1],color=c,alpha=.4);ax.plot(*np.vstack([tri,tri[0]])[:,:2].T,color=c)
                    ax.text(*tri[:,:2].mean(0),str(fid),fontsize=6,clip_on=True)
            lo=xyz.reshape(-1,3).min(0);hi=xyz.reshape(-1,3).max(0)
            if col==0:
                ax.set_xlim(lo[0]-.1,hi[0]+.1);ax.set_ylim(lo[1]-.1,hi[1]+.1);ax.set_zlim(lo[2]-.05,hi[2]+.05);ax.set_box_aspect([max(hi[0]-lo[0],1),max(hi[1]-lo[1],1),max((hi[2]-lo[2])*3.91,1)]);ax.view_init(30,-65);ax.set_zlabel('Original source Z, m')
            else:
                for edge in [84,85,86,87]:ax.plot(*lines[edge].T,color='#ea580c',linewidth=2);ax.text(*lines[edge].mean(0),str(edge),clip_on=True)
                ax.set_xlim(323,334);ax.set_ylim(187,181);ax.set_aspect('equal');ax.grid(alpha=.2)
            ax.set_title(title+(' — original source' if col==0 else ' — source XY and authored outline'),fontsize=10)
        records.append(dict(category=title,proposedOwner=owner,sourceFaces=ids,sourceZRange=[float(xyz[:,:,2].min()),float(xyz[:,:,2].max())],sourceVerticesSvgZ=xyz.tolist(),clippedTriangleSourceFaces=clipped_ids,clipBoundsSvg=bounds,policy='Preserve per-face Z/UV and exact clipped source area; do not extrude or merge height intervals.'))
    fig.suptitle('Split 84/85/86 cap ownership review. Numbered source fragments are clipped to the reviewed corner bounds. Outside source remains unchanged.');fig.tight_layout(rect=[0,0,1,.97]);fig.savefig(out/'atower-cap-categories.png',dpi=160);plt.close(fig)
    ids=list(range(meta['objects'][5918]['firstFace'],meta['objects'][5918]['firstFace']+meta['objects'][5918]['faceCount']))
    xyz=p[f[ids]].copy();xyz[:,:,:2]=xyz[:,:,:2]@affine[:,:2].T+affine[:,2]
    bounds=[324,181,337,216];clipped=clip_mesh_xy(xyz,np.array(bounds[:2]),np.array(bounds[2:]))
    fig=plt.figure(figsize=(16,9));ax=fig.add_subplot(121,projection='3d');ax.add_collection3d(Poly3DCollection(clipped,facecolors='#0ea5e9',edgecolors='#334155',linewidths=.1,alpha=.6));ax.set_xlim(324,337);ax.set_ylim(181,216);ax.set_zlim(clipped[:,:,2].min(),clipped[:,:,2].max());ax.view_init(25,-55);ax.set_box_aspect([13,35,25]);ax.set_title('Source5918: continuous return and lower diagonal');ax.set_zlabel('Original source Z, m')
    ax=fig.add_subplot(122)
    for tri in clipped:ax.plot(*np.vstack([tri,tri[0]])[:,:2].T,color='#0284c7',linewidth=.25,alpha=.5)
    for edge in range(84,90):ax.plot(*lines[edge].T,color='#ea580c',linewidth=2.5);ax.text(*lines[edge].mean(0),str(edge),fontsize=11,clip_on=True)
    ax.set_xlim(324,337);ax.set_ylim(216,181);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title('Blue: source XY; orange: exact authored walls')
    fig.suptitle('Closure frontier: moving86 requires connected87; moving87 also changes its88 join. These returns share source5918.');fig.tight_layout(rect=[0,0,1,.95]);fig.savefig(out/'atower-87-88-closure-frontier.png',dpi=160);plt.close(fig)
    (out/'atower-cap-categories.json').write_text(json.dumps(dict(sourceGeometrySha256=meta['geometrySha256'],generatorSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),categories=records,frontierObject=dict(index=5918,**meta['objects'][5918]),notes=['The earlier48 entries include intermediate rejected pieces later admitted to86; they are not48 distinct unresolved source faces.','No candidate geometry has changed.','87 and88 source membership still requires exact clipped face/profile binding; this plot alone is not approval.']),indent=2))
    print(out/'atower-cap-categories.png')

if __name__=='__main__':main()
