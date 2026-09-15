"""Original mounted wall members with their source shell context."""
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
import shapely
from render_split_remaining_corner_families import sections
from render_competing_floor_assemblies import clip_mesh_xy
from lift_reviewed_wall_source_heights import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
out=REV/'split-upper-vent-chain-source-members-v1';out.mkdir(exist_ok=False)
raw=ROOT/'supplemented-v2/world/split/geometry.npz';d=np.load(raw);points,faces=d['points'],d['faces'];meta=json.loads(raw.with_suffix('.json').read_text())
projection=ROOT/'tactical-alignment-sides-v1/split.json';a=np.array(json.loads(projection.read_text())['nativeToAttackSvg']);corr=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];records=[]
def triangles(index):
    obj=meta['objects'][index];ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount']);t=points[faces[ids]].copy();t[:,:,:2]=t[:,:,:2]@a[:,:2].T+a[:,2];return ids,t
_,shell=triangles(5927)
for index in [5927,563,5902,5903,5926,5934,612]:
    ids,tri=triangles(index);lo=tri[:,:,:2].min((0,1));hi=tri[:,:,:2].max((0,1));padding=np.maximum((hi-lo)*.08,.3)
    bounds=np.array([lo-padding,hi+padding]);back=clip_mesh_xy(shell,*bounds)if index!=5927 else []
    contacts=[]
    for z in [6.5,6.8,8.35,10.35,12.75,15.,17.9]:
        ss,_=sections(tri,z);bb,_=sections(np.array(back),z)if len(back)else([],[])
        if len(ss)and len(bb):
            u=shapely.union_all(shapely.linestrings(ss));v=shapely.union_all(shapely.linestrings(bb));inter=u.intersection(v)
            contacts.append(dict(z=z,minimumSectionDistanceSvg=float(u.distance(v)),intersectionLengthSvg=float(inter.length)))
    fig=plt.figure(figsize=(14,7))
    for num,az in enumerate([-65,115],1):
        ax=fig.add_subplot(1,2,num,projection='3d')
        if len(back):ax.add_collection3d(Poly3DCollection(back,facecolors='#64748b',edgecolors='#64748b',lw=.12,alpha=.10))
        ax.add_collection3d(Poly3DCollection(tri,facecolors='#0d9488',edgecolors='#0f766e',lw=.4,alpha=.65))
        zlo,zhi=tri[:,:,2].min(),tri[:,:,2].max();ax.set(xlim=bounds[:,0],ylim=bounds[:,1],zlim=(zlo-.15,zhi+.15),xlabel='Source SVG X',ylabel='Source SVG Y',zlabel='Original Z, m');ax.set_box_aspect([*(bounds[1]-bounds[0]),(zhi-zlo+.3)*3.91]);ax.view_init(20,az)
    fig.suptitle(f'Raw source {index}: {meta["objects"][index]["path"].split("/")[1]}\nTeal is the original member, gray is source5927 context. No geometry moved; alpha bounds only.',fontsize=11);fig.tight_layout();fig.savefig(out/f'original-member-{index}.png',dpi=145);plt.close(fig)
    records.append(dict(index=index,**meta['objects'][index],fullPackAdmittedFaces=int(np.isin(ids,corr).sum()),sectionContacts=contacts))
(out/'source-member-review.json').write_text(json.dumps(dict(sourceGeometrySha256=sha(raw),projectionSha256=sha(projection),scriptSha256=sha(Path(__file__)),objects=records,
    status='Raw source roles and proximity only. Not a literal weld proof or gameplay collision classification.'),indent=2)+'\n');print(str(out))
