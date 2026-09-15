"""Exact source packet for the retained97/99 doorway attachment."""
import gzip,json,hashlib
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from render_competing_floor_assemblies import clip_mesh_xy
from render_split_remaining_corner_families import sections

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
OUT=REV/'split-doorframe-attachment-review-v1'

def main():
    OUT.mkdir(exist_ok=True)
    path=ROOT/'supplemented-v2/world/split/geometry.npz'
    raw=np.load(path);p,f=raw['points'],raw['faces'];meta=json.loads(path.with_suffix('.json').read_text())
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg'])
    coverage=json.loads(gzip.decompress((REV/'all-map-wall-span-coverage-v1/split/attack.coverage.json.gz').read_bytes()))
    groups=[('Floor strips',list(range(1880003,1880011)),'#64748b'),('Distant jamb',list(range(1880011,1880017))+list(range(1880037,1880043)),'#2563eb'),('Long upper rails',list(range(1880017,1880027))+list(range(1880051,1880055))+[1880057,1880058],'#9333ea'),('Near left jamb',list(range(1880027,1880033)),'#dc2626'),('Near right jamb/caps',list(range(1880033,1880037))+list(range(1880043,1880051))+[1880055,1880056,1880059,1880060],'#16a34a')]
    assert sorted(x for _,ids,_ in groups for x in ids)==list(range(1880003,1880061))
    groups += [('Main wall5927',[1893768,1893769,1893774,1893775,1894006,1894007],'#0891b2'),('Diagonal96',[1862722,1862723],'#a16207')]
    mesh={};records=[]
    for name,ids,color in groups:
        tri=p[f[ids]].copy();tri[:,:,:2]=tri[:,:,:2]@affine[:,:2].T+affine[:,2];mesh[name]=tri
        records.append(dict(name=name,color=color,originalFaces=ids,trianglesSvgSourceZ=tri.tolist(),bounds=np.stack((tri.min((0,1)),tri.max((0,1)))).tolist()))
    def draw_outline(ax,bounds):
        for s in coverage['spans']:
            a,b=np.array(s['startSvg']),np.array(s['endSvg'])
            if (np.maximum(a,b)>=bounds[:2]).all() and (np.minimum(a,b)<=bounds[2:]).all():
                ax.plot(*np.array([a,b]).T,color='#111827',lw=2.5)
                ax.text(*((a+b)/2),str(s['legacyStraightEdgeIndex'] if s['legacyStraightEdgeIndex'] is not None else 'short99'),fontsize=8,clip_on=True)
    fig=plt.figure(figsize=(18,11))
    for i,bounds in enumerate([[340,130,351,159],[340.8,149.3,346,152]]):
        ax=fig.add_subplot(2,3,1+i*3,projection='3d')
        for name,ids,color in groups:
            tri=clip_mesh_xy(mesh[name],np.array(bounds[:2]),np.array(bounds[2:]))
            if len(tri):ax.add_collection3d(Poly3DCollection(tri,facecolors=color,edgecolors='#334155',alpha=.7,linewidths=.3))
        ax.set_xlim(bounds[0],bounds[2]);ax.set_ylim(bounds[1],bounds[3]);ax.set_zlim(6.4,10.8);ax.view_init(24,-62);ax.set_box_aspect([bounds[2]-bounds[0],bounds[3]-bounds[1],17]);ax.set_title('Original doorway assembly' if i==0 else 'Original near-jamb depth faces');ax.set_xlabel('Pre-W SVG X');ax.set_ylabel('Pre-W SVG Y');ax.set_zlabel('Source Z, m')
        for k,z in enumerate([8.25,10.3]):
            ax=fig.add_subplot(2,3,2+i*3+k)
            for name,ids,color in groups:
                ss,_=sections(mesh[name],z)
                if len(ss):ax.add_collection(LineCollection(ss,colors=color,lw=2,label=name))
            draw_outline(ax,bounds);ax.set_xlim(bounds[0],bounds[2]);ax.set_ylim(bounds[3],bounds[1]);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f'Raw source section Z={z} m; black authored outline')
            if i==0 and k==0:ax.legend(fontsize=7,loc='upper left')
            if i==1:
                for fid in [1880027,1880029,1880030,1880031,1880043,1880045,1880047,1893775]:
                    tri=p[f[fid]].copy();tri[:,:2]=tri[:,:2]@affine[:,:2].T+affine[:,2];ss,_=sections(tri[None],z)
                    if len(ss):ax.text(*ss[0].mean(0),str(fid),fontsize=7,clip_on=True)
    fig.suptitle('DoorFrameB5896 is one doorway, with a projecting near jamb and connected upper rails.\nSource Z is absolute. These sections do not assert the current tactical floor policy or alpha visibility.',fontsize=13);fig.tight_layout(rect=[0,0,1,.94]);fig.savefig(OUT/'doorframe-full-and-local-source.png',dpi=170);plt.close(fig)
    report=dict(sourceGeometrySha256=hashlib.sha256(path.read_bytes()).hexdigest(),object=meta['objects'][5896],groups=records,confirmed=dict(visibleRetainedFaces=[1880029,1880030],attachedToMovedFaces=[1880027,1880028],connection='Identical original vertices, confirmed by independent root attachment mapping.',actualDoorway='The distant and near jambs are separate supports connected above by rails. No face extrusion or blanket whole-object collapse is proposed.'),proposal=dict(status='Source role review; transform not baked.',scope='Near jamb and its attached local rail/cap faces must share a declared corner transform with97/99/96. Distant jamb and opening must remain.',reasonIndependentClampInsufficient='Left-front97 and top-front99 share depth/cap vertices. Independently collapsing each surface can split the same source point. A common local corner field is required for shared points.'))
    (OUT/'source-profile-packet.json').write_text(json.dumps(report,indent=2));print(OUT)

if __name__=='__main__':main()
