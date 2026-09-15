"""Read-only original Ascent poster sheets and their geometric backing."""
import hashlib
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np

ROOT=Path('E:/IcarusWorldAudit/2026-09-06')
R=ROOT/'tactical-visibility-revision'
OUT=R/'ascent-poster-source-review-v1'
OUT.mkdir(exist_ok=True)
raw_path=ROOT/'supplemented-v2/world/ascent/geometry.npz'
raw=np.load(raw_path)
points=raw['points'];faces=raw['faces']
meta=json.loads(raw_path.with_suffix('.json').read_text())
objects=meta['objects']
bounds=np.array([o['boundsMeters'] for o in objects])
poster_ids=list(range(1041,1049))
direct_hits={1041,1042,1046,1048}
packet=[];records=[]


def object_triangles(oid):
    obj=objects[oid]
    ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
    return ids,points[faces[ids]].astype(float)


def geometric_hits(origin,direction,excluded):
    # Literal triangle contacts, independent of material opacity/collision role.
    end=origin+direction*.5
    lo=np.minimum(origin,end)-1e-6;hi=np.maximum(origin,end)+1e-6
    candidate=np.flatnonzero((bounds[:,0]<=hi).all(1)&(bounds[:,1]>=lo).all(1))
    hits=[]
    for oid in candidate:
        if int(oid) in excluded:continue
        ids,tri=object_triangles(int(oid));e1=tri[:,1]-tri[:,0];e2=tri[:,2]-tri[:,0]
        h=np.cross(np.broadcast_to(direction,e2.shape),e2);det=np.einsum('ij,ij->i',e1,h)
        valid=abs(det)>1e-12;inv=np.divide(1,det,out=np.zeros_like(det),where=valid)
        delta=origin-tri[:,0];u=np.einsum('ij,ij->i',delta,h)*inv;q=np.cross(delta,e1);v=(q@direction)*inv;t=np.einsum('ij,ij->i',e2,q)*inv
        valid&=(u>=-1e-8)&(v>=-1e-8)&(u+v<=1+1e-8)&(t>1e-6)&(t<=.5)
        for i in np.flatnonzero(valid):hits.append(dict(object=int(oid),path=objects[int(oid)]['path'],originalFace=int(ids[i]),distanceMeters=float(t[i]),pointNative=(origin+t[i]*direction).tolist()))
    return sorted(hits,key=lambda h:h['distanceMeters'])[:8]


for oid in poster_ids:
    ids,tri=object_triangles(oid);unique=np.unique(tri.reshape(-1,3),axis=0);center=unique.mean(0)
    _,singular,v=np.linalg.svd(unique-center,full_matrices=False);normal=v[-1]
    area=float(np.linalg.norm(np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]),axis=1).sum()/2)
    nearest=[geometric_hits(center,sign*normal,set(poster_ids)) for sign in (-1,1)]
    rec=dict(object=oid,path=objects[oid]['path'],directFrozenRayHit=oid in direct_hits,originalFaces=ids.tolist(),triangleCount=len(tri),uniqueVertices=len(unique),nativeBounds=[unique.min(0).tolist(),unique.max(0).tolist()],surfaceAreaSquareMeters=area,bestFitNormal=normal.tolist(),maximumPlaneResidualMeters=float(np.max(abs((unique-center)@normal))),normalProbeCenter=center.tolist(),nearestGeometricContactsByNormalSign=nearest)
    records.append(rec);packet.append((oid,ids,tri))

groups=[('door145',list(range(1041,1045))),('wall150',list(range(1045,1049)))]
for name,ids in groups:
    posters=np.concatenate([t for oid,_,t in packet if oid in ids]);lo=posters.min((0,1))-[.5,.5,.6];hi=posters.max((0,1))+[.5,.5,.7]
    owners={h['object'] for r in records if r['object'] in ids for ray in r['nearestGeometricContactsByNormalSign'] for h in ray[:1]}
    contexts={oid:object_triangles(oid)[1] for oid in owners}
    fig=plt.figure(figsize=(14,6.7));axes=[fig.add_subplot(121,projection='3d'),fig.add_subplot(122,projection='3d')]
    for ax,angle in zip(axes,[-65,115]):
        for oid,tri in contexts.items():
            keep=(tri.min(1)<=hi).all(1)&(tri.max(1)>=lo).all(1)
            ax.add_collection3d(Poly3DCollection(tri[keep],facecolors='#64748b',edgecolors='#475569',alpha=.14,linewidths=.3))
        for oid,_,tri in packet:
            if oid not in ids:continue
            ax.add_collection3d(Poly3DCollection(tri,facecolors='#ea580c' if oid in direct_hits else '#2563eb',edgecolors='#1e293b',alpha=.9,linewidths=.6))
            c=tri.mean((0,1));ax.text(*c,str(oid),fontsize=9)
        ax.set_xlim(lo[0],hi[0]);ax.set_ylim(lo[1],hi[1]);ax.set_zlim(lo[2],hi[2]);ax.set_box_aspect(hi-lo);ax.view_init(elev=22,azim=angle);ax.set_xlabel('Native X, m');ax.set_ylabel('Native Y, m');ax.set_zlabel('Original Z, m')
    fig.suptitle(f'Ascent {name}: full original poster instances, unchanged source XYZ\nOrange: directly hit sheets. Blue: companion sheets. Gray: nearest geometric backing; material/collision role not inferred.');fig.tight_layout(rect=[0,0,1,.91]);fig.savefig(OUT/f'{name}-original-3d.png',dpi=140);plt.close(fig)
    fig,ax=plt.subplots(figsize=(9,7))
    for oid,tri in contexts.items():
        keep=(tri.min(1)<=hi).all(1)&(tri.max(1)>=lo).all(1)
        closed=np.concatenate([tri[keep,:,:2],tri[keep,:1,:2]],axis=1);ax.add_collection(LineCollection(closed,colors='#64748b',alpha=.25,linewidths=.5,label=f'Backing{oid}'))
    for oid,_,tri in packet:
        if oid not in ids:continue
        closed=np.concatenate([tri[:,:,:2],tri[:,:1,:2]],axis=1);ax.add_collection(LineCollection(closed,colors='#ea580c' if oid in direct_hits else '#2563eb',linewidths=2,label=f'Poster{oid}'))
    ax.set_xlim(lo[0],hi[0]);ax.set_ylim(lo[1],hi[1]);ax.set_aspect('equal');ax.grid(alpha=.2);ax.legend(fontsize=8);ax.set_xlabel('Native X, m');ax.set_ylabel('Native Y, m');ax.set_title(f'{name}: exact raw XY, no depth expansion or W\nAll poster instances have only two triangles; adjacent backing shown separately.');fig.tight_layout();fig.savefig(OUT/f'{name}-original-plan.png',dpi=140);plt.close(fig)

np.savez_compressed(OUT/'poster-source-packet.npz',sourceObjectIds=np.concatenate([np.full(len(t),o) for o,_,t in packet]),originalFaces=np.concatenate([f for _,f,_ in packet]),nativeTriangles=np.concatenate([t for _,_,t in packet]))
(OUT/'review.json').write_text(json.dumps(dict(scope=__doc__,sourceGeometryMutation=False,limitations='Nearest geometric triangle contact is measured without material/collision filtering. Flatness and source placement support assembly review but do not alone authorize removal or define final 2D blocker semantics.',inputs=[dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in [raw_path,raw_path.with_suffix('.json')]],objects=records),indent=2))
for r in records:print(r['object'],'plane residual',r['maximumPlaneResidualMeters'],'nearest',[(x[0]['object'],x[0]['distanceMeters']) if x else None for x in r['nearestGeometricContactsByNormalSign']])
