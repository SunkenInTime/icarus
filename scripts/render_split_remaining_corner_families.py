"""Read-only source and candidate sections for unresolved wall junctions."""
import json
import gzip
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from tactical_alignment_audit import pack, vector_lines
from render_competing_floor_assemblies import clip_mesh_xy
from tactical_alignment_composite import explicit_warp

ROOT=Path('E:/IcarusWorldAudit/2026-09-06'); REV=ROOT/'tactical-visibility-revision'

def sections(tris,z):
    output=[]; rows=[]
    for i,tri in enumerate(tris):
        hits=[]
        for a,b in zip(tri,np.roll(tri,-1,axis=0)):
            if (a[2]<=z<b[2]) or (b[2]<=z<a[2]):
                hits.append(a[:2]+(b[:2]-a[:2])*(z-a[2])/(b[2]-a[2]))
        if len(hits)==2: output.append(hits); rows.append(i)
    return np.array(output).reshape(-1,2,2),np.array(rows,dtype=int)

def main(output_name='split-remaining-corner-source-review-v1',groups=None,candidate_version='v4'):
    out=REV/output_name;out.mkdir(exist_ok=True)
    meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text())
    raw=np.load(ROOT/'supplemented-v2/world/split/geometry.npz');p,f=raw['points'],raw['faces']
    starts=np.array([o['firstFace'] for o in meta['objects']])
    full=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    control=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces']
    objs=np.searchsorted(starts,full[control],side='right')-1
    candidate=REV/f'split-wall-family-normalized-candidate-{candidate_version}'
    candidate_parents=np.load(candidate/'correspondence.npz')['sourceFaces']
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg']);matrix,origin=affine[:,:2],affine[:,2]
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));before=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;after=np.array(w['targetAttackSvg']).reshape(-1,2);warp=explicit_warp(before,after-before,np.array(w['triangles']).reshape(-1,3))
    lines=vector_lines(Path('assets/maps/split_map.svg'))
    packs=[]
    for label,path,objids in [('Original control',REV/'global-ground-complete-v2/split/split.height.bin.gz',objs),(candidate_version.upper()+' normalized candidate',candidate/'split.height.bin.gz',objs[candidate_parents])]:
        _,arrays=pack(path);packs.append((label,arrays,objids))
    groups=groups or [('ramp-upper-grate',[7897,7895],[357,282,377,299]),('ramp-lower-box-depth',[7897,7869],[357,302,370,317]),('clove-right-endcap',[7791,7792,4714,4774],[252,190,265,201])]
    summary=[]
    for name,objects,bounds in groups:
        colors={obj:plt.cm.tab10(i) for i,obj in enumerate(objects)}
        fig=plt.figure(figsize=(18,11))
        for view in range(2):
            ax=fig.add_subplot(2,4,1+view*4,projection='3d');meshes=[]
            for obj in objects:
                row=meta['objects'][obj];mesh=p[f[row['firstFace']:row['firstFace']+row['faceCount']]].copy();mesh[:,:,:2]=mesh[:,:,:2]@matrix.T+origin
                mesh=clip_mesh_xy(mesh,np.array(bounds[:2]),np.array(bounds[2:]));meshes.append(mesh)
                if len(mesh):ax.add_collection3d(Poly3DCollection(mesh,facecolors=colors[obj],edgecolors='#334155',linewidths=.15,alpha=.65))
            verts=np.concatenate([m.reshape(-1,3) for m in meshes if len(m)])
            lo,hi=verts.min(0),verts.max(0);ax.set_xlim(bounds[0],bounds[2]);ax.set_ylim(bounds[1],bounds[3]);ax.set_zlim(lo[2],hi[2]);ax.set_box_aspect([bounds[2]-bounds[0],bounds[3]-bounds[1],(hi[2]-lo[2])*3.91]);ax.view_init(25,-65 if view==0 else 115)
            ax.set_title('Original source meshes, angle '+str(view+1));ax.set_xlabel('Pre-W SVG X');ax.set_ylabel('Pre-W SVG Y');ax.set_zlabel('Native Z, m')
        for pack_idx,(label,arrays,objids) in enumerate(packs):
            selected=np.flatnonzero(np.isin(objids,objects));tri=arrays['vertices'][arrays['faces'][selected]].copy();tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin
            for hi,z in enumerate([.75,1.75,2.75]):
                ax=fig.add_subplot(2,4,pack_idx*4+hi+2)
                for edge,line in enumerate(lines):
                    if np.all(line.max(0)>=bounds[:2]) and np.all(line.min(0)<=bounds[2:]):
                        ax.plot(*line.T,color='#f97316',linewidth=2.5);ax.text(*line.mean(0),str(edge),fontsize=8,color='#c2410c',clip_on=True)
                seg,rows=sections(tri,z)
                for obj in objects:
                    chosen=rows[objids[selected[rows]]==obj]
                    if len(chosen):
                        ss,_=sections(tri[chosen],z);paths=[]
                        for line in ss:
                            sample=np.linspace(line[0],line[1],max(2,int(np.linalg.norm(line[1]-line[0])/.15)+1));mapped=warp.apply(sample);paths.extend(np.stack((mapped[:-1],mapped[1:]),axis=1))
                        ax.add_collection(LineCollection(paths,colors=[colors[obj]],linewidths=1,label=str(obj)))
                ax.set_xlim(bounds[0],bounds[2]);ax.set_ylim(bounds[3],bounds[1]);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f'{label}\nrelative {z} m',fontsize=10)
                if hi==0:ax.legend(fontsize=7)
        notes=' | '.join(f'{o}: {meta["objects"][o]["path"] if "path" in meta["objects"][o] else meta["objects"][o].get("name","")}' for o in objects)
        fig.suptitle(name+'\nOrange: authored outline. 2D sections include display W. Both 3D views show original source. Masked sections show bounds, not alpha samples.',fontsize=12)
        fig.tight_layout(rect=[0,0,1,.95]);fig.savefig(out/f'{name}.png',dpi=160);plt.close(fig)
        summary.append({'id':name,'boundsSvg':bounds,'objects':[dict(index=o,**meta['objects'][o]) for o in objects],'sectionIncludesMaskedWithoutSampling':True})
    (out/'manifest.json').write_text(json.dumps(summary,indent=2));print(out)

if __name__=='__main__':main()
