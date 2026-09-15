"""Separate the real nav-standing return from the higher nominal 174 section."""
import gzip
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np

from render_split_remaining_corner_families import sections
from tactical_alignment_audit import pack, vector_lines
from tactical_alignment_composite import explicit_warp
from render_competing_floor_assemblies import clip_mesh_xy
from lift_reviewed_wall_source_heights import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06'); REV=ROOT/'tactical-visibility-revision'


def main():
    out=REV/'split-174-connected-source-role-review-v1';out.mkdir(exist_ok=True)
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz'
    data=np.load(raw_path);points=data['points'];faces=data['faces']
    metadata=json.loads(raw_path.with_suffix('.json').read_text())
    registration=json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())
    affine=np.array(registration['nativeToAttackSvg']);matrix,origin=affine[:,:2],affine[:,2]
    warp_path=REV/'display-warps-v1/split.display-warp.json.gz'
    w=json.loads(gzip.decompress(warp_path.read_bytes()))
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    wt=np.array(w['targetAttackSvg']).reshape(-1,2)
    forward=explicit_warp(ws,wt-ws,np.array(w['triangles']).reshape(-1,3))
    nav_path=REV/'split-174-receiver-first-hit-review-v2/nav-standing-origin-review.json'
    nav=json.loads(nav_path.read_text())
    inventory=json.loads((out/'raw-neighbor-inventory.json').read_text())
    nearby=np.unique(np.concatenate([r['faces'] for r in inventory['objects']]))
    objects=[7795,7796,4773]
    ids=np.concatenate([np.arange(metadata['objects'][o]['firstFace'],metadata['objects'][o]['firstFace']+metadata['objects'][o]['faceCount']) for o in objects])
    def raw_tri(selected):
        t=points[faces[selected]].copy();t[:,:,:2]=t[:,:,:2]@matrix.T+origin;return t
    raw=raw_tri(ids);other=raw_tri(np.setdiff1d(nearby,ids))
    complete=REV/'split-complete-control-original-height-v29-v2'
    _,scene=pack(complete/'split.height.bin.gz')
    comp=np.load(complete/'composition-provenance.npz')
    control=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces']
    lifted=np.load(REV/'split-source-world-fragments-v29-v1/source-world-fragments.npz')
    reviewed=np.load(REV/'split-source-height-region-oracle-v29-v1/original-source-provenance.npz')['fullSourceParents']
    lookup=[control,lifted['fullSourceParents'],lifted['discardedFullSourceParents'],reviewed]
    full_ids=np.empty(len(comp['group']),dtype=np.int64)
    for group in range(4):
        mask=comp['group']==group;full_ids[mask]=lookup[group][comp['inputId'][mask]]
    original_ids=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'][full_ids]
    kept=np.flatnonzero(np.isin(original_ids,ids))
    candidate=scene['vertices'][scene['faces'][kept]].copy();candidate[:,:,:2]=candidate[:,:,:2]@matrix.T+origin
    authored=vector_lines(Path('assets/maps/split_map.svg'))
    ranges=[('standing-return',[262.9,195.45,264.5,197.15]),('connected-corner',[254,190,269,202]),('vertical173-context',[259,167,269,198])]
    height_rows=[2.65,3.5,4.35,4.45,6.5,8.25]
    section_records=[]
    colors=['#7c3aed','#dc2626','#0891b2']
    for name,bounds in ranges:
        fig,axs=plt.subplots(2,3,figsize=(16,10))
        for ax,z in zip(axs.flat,height_rows):
            for line in authored:
                if np.all(line.max(0)>=bounds[:2]) and np.all(line.min(0)<=bounds[2:]):ax.plot(*line.T,color='#171717',lw=2.4)
            ss,_=sections(other,z)
            if len(ss):ax.add_collection(LineCollection([forward.apply(s) for s in ss],colors='#94a3b8',lw=.7,alpha=.5))
            ss,rows=sections(raw,z)
            if len(ss):ax.add_collection(LineCollection([forward.apply(s) for s in ss],colors='#dc2626',lw=1.1,label='Raw source after display W'))
            cs,cr=sections(candidate,z)
            if len(cs):ax.add_collection(LineCollection([forward.apply(s) for s in cs],colors='#16a34a',lw=1.1,label='V29 original-Z oracle'))
            ax.set(xlim=(bounds[0],bounds[2]),ylim=(bounds[3],bounds[1]));ax.set_aspect('equal');ax.grid(alpha=.2)
            ax.set_title(f'Absolute Z {z:.2f} m'+(' | real nav-standing eye' if z==4.35 else ''))
            ax.legend(fontsize=7)
            if name=='standing-return':
                local=(ss.max(1)>=bounds[:2]).all(1)&(ss.min(1)<=bounds[2:]).all(1) if len(ss) else []
                section_records.append(dict(height=z,rawSourceFaces=ids[rows[local]].tolist(),sourceSegments=ss[local].tolist()))
        fig.suptitle('174 corner: black authored wall, red raw source, green existing V29 absolute-height geometry.\nGray is unclassified nearby raw geometry. Sections show masked bounds; they do not sample alpha.',fontsize=12)
        fig.tight_layout(rect=[0,0,1,.94]);fig.savefig(out/f'{name}-six-height-sections.png',dpi=150);plt.close(fig)
    bounds=[262.5,194.5,265,198]
    fig=plt.figure(figsize=(15,7))
    for col,az in enumerate([-60,120],1):
        ax=fig.add_subplot(1,2,col,projection='3d')
        for obj,color in zip(objects,colors):
            row=metadata['objects'][obj];tri=raw_tri(np.arange(row['firstFace'],row['firstFace']+row['faceCount']))
            tri=clip_mesh_xy(tri,np.array(bounds[:2]),np.array(bounds[2:]));tri=tri[(tri.max(1)[:,2]>=2.5)&(tri.min(1)[:,2]<=9)]
            if len(tri):ax.add_collection3d(Poly3DCollection(tri,facecolors=color,edgecolors=color,alpha=.35,lw=.3))
        hit=raw_tri(np.array([2824296]))
        ax.add_collection3d(Poly3DCollection(hit,facecolors='#fbbf24',edgecolors='#111827',alpha=.85,lw=1))
        ax.set(xlim=(bounds[0],bounds[2]),ylim=(bounds[1],bounds[3]),zlim=(2.5,9),xlabel='Raw projected X',ylabel='Raw projected Y',zlabel='Original Z, m')
        ax.set_box_aspect([2.5,3.5,6.5*3.91]);ax.view_init(17,az)
        ax.set_title('Yellow = raw face 2824296, actual standing return')
    fig.suptitle('Original source only. Distinct lower return and upper horizontal ledge; no proposed mapping or height fill.',fontsize=12)
    fig.tight_layout();fig.savefig(out/'corner-original-height-source3d.png',dpi=150);plt.close(fig)
    report=dict(scope=__doc__,sourceGeometrySha256=sha(raw_path),oracleSha256=sha(complete/'split.height.bin.gz'),displayWarpSha256=sha(warp_path),navReviewSha256=sha(nav_path),scriptSha256=sha(Path(__file__)),objects=[dict(index=o,**metadata['objects'][o]) for o in objects],actualStandingFace=2824296,actualStandingSourceTriangle=raw_tri(np.array([2824296]))[0].tolist(),actualStandingEye=4.35,standingReturnDisplayX=263.7292389615617,authoredReturnX=263.657,standingHorizontalErrorSvg=263.7292389615617-263.657,higherNominalHorizontalDisplayY=196.82289789402603,authoredHorizontalY=196.096,sections=section_records,neighborObjects=len(inventory['objects']),limits='No mapping, no bake. Raw nearby geometry is a review queue. All displayed source Z is original absolute height. Different sections must not be conflated. Existing source material policy and doorway profiles must be preserved.')
    (out/'source-profile-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(output=str(out),sourceFaces=len(ids),oracleFragments=len(kept),sectionRows=len(section_records))))


if __name__=='__main__':main()
