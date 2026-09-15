"""Full raw Ascent window/conduit instances and reconstructed local-height cuts.

This is source geometry evidence only. It assigns no blocker or decoration role.
"""
import hashlib
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np

from build_global_tactical_candidate import GroundField
from probe_static_floor_sections import sections
from tactical_alignment_audit import pack

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');R=ROOT/'tactical-visibility-revision'
OUT=R/'ascent-window-conduit-source-review-v1';OUT.mkdir(exist_ok=True)
raw_path=ROOT/'supplemented-v2/world/ascent/geometry.npz';raw=np.load(raw_path)
points=raw['points'];faces=raw['faces'];meta=json.loads(raw_path.with_suffix('.json').read_text());objects=meta['objects']
bounds=np.array([o['boundsMeters'] for o in objects])
candidate=R/'ascent-connected-component5-candidate-v5/ascent.height.bin.gz'
control=R/'global-ground-complete-v2/ascent/ascent.height.bin.gz'
field_path=control.parent/'ascent.tactical-ground.json.gz'
_,ca=pack(candidate);_,co=pack(control);field=GroundField(field_path)
trace_path=R/'ascent-component5-control-v5-evidence/frozen-contact-first-hits.json'
trace=next(r for r in json.loads(trace_path.read_text())['records'] if r['id']=='span-144-center')
q=np.array(trace['query']);observer_z=float(q[2]+field.heights(q[None,:2])[0]);hits=[]
for hit in trace['samples']:
    if hit.get('sourceObject') not in [769,6571]:continue
    cid,pid,_,original=hit['faceChain'];ct=ca['vertices'][ca['faces'][cid]];pt=co['vertices'][co['faces'][pid]]
    assert np.array_equal(ct,pt)
    h=np.array(hit['hitNative']);uv=np.linalg.lstsq((ct[1:]-ct[0]).T,h-ct[0],rcond=None)[0];bary=np.r_[1-uv.sum(),uv]
    assert np.linalg.norm(bary@ct-h)<1e-9
    lifted=pt.copy();lifted[:,2]+=field.heights(pt[:,:2]);xyz=bary@lifted
    assert abs(xyz[2]-(h[2]+field.heights(h[None,:2])[0]))<1e-7
    parent=points[faces[original]].astype(float);weights=np.linalg.lstsq((parent[1:]-parent[0]).T,xyz-parent[0],rcond=None)[0]
    parent_bary=np.r_[1-weights.sum(),weights];residual=float(np.linalg.norm(parent_bary@parent-xyz));assert residual<1e-6
    hits.append(dict(sourceObject=hit['sourceObject'],originalFace=original,candidateFace=cid,controlParent=pid,candidatePoint=h.tolist(),candidateBarycentrics=bary.tolist(),sourceNative=xyz.tolist(),rawParentBarycentrics=parent_bary.tolist(),rawParentResidualMeters=residual))


def object_triangles(oid):
    o=objects[oid];ids=np.arange(o['firstFace'],o['firstFace']+o['faceCount'])
    return ids,points[faces[ids]].astype(float)


def nearest_geometric(origin,direction,excluded):
    end=origin+direction*.75;lo=np.minimum(origin,end)-1e-6;hi=np.maximum(origin,end)+1e-6
    candidates=np.flatnonzero((bounds[:,0]<=hi).all(1)&(bounds[:,1]>=lo).all(1));results=[]
    for oid in candidates:
        if oid in excluded:continue
        ids,t=object_triangles(int(oid));e1=t[:,1]-t[:,0];e2=t[:,2]-t[:,0];h=np.cross(np.broadcast_to(direction,e2.shape),e2);det=np.einsum('ij,ij->i',e1,h)
        ok=abs(det)>1e-12;inv=np.divide(1,det,out=np.zeros_like(det),where=ok);delta=origin-t[:,0];u=np.einsum('ij,ij->i',delta,h)*inv;v3=np.cross(delta,e1);v=(v3@direction)*inv;distance=np.einsum('ij,ij->i',e2,v3)*inv
        ok&=(u>=-1e-8)&(v>=-1e-8)&(u+v<=1+1e-8)&(distance>1e-6)&(distance<=.75)
        for i in np.flatnonzero(ok):results.append(dict(object=int(oid),path=objects[int(oid)]['path'],originalFace=int(ids[i]),distanceMeters=float(distance[i]),pointNative=(origin+distance[i]*direction).tolist()))
    return sorted(results,key=lambda r:r['distanceMeters'])[:1]


records=[];packet=[]
for oid,label in [(6571,'window6571'),(769,'conduit769')]:
    ids,tri=object_triangles(oid);local_hits=[h for h in hits if h['sourceObject']==oid];hit_xyz=np.array([h['sourceNative'] for h in local_hits]);zlo=float(hit_xyz[:,2].min());zhi=float(hit_xyz[:,2].max())
    contacts=[]
    for fid,t in zip(ids,tri):
        normal=np.cross(t[1]-t[0],t[2]-t[0]);length=np.linalg.norm(normal)
        if length==0:continue
        normal/=length
        for sign in (-1,1):
            for h in nearest_geometric(t.mean(0),normal*sign,{oid}):contacts.append(dict(fromOriginalFace=int(fid),normalSign=sign,**h))
    backing_ids=sorted({h['object'] for h in contacts})
    context={i:object_triangles(i) for i in backing_ids}
    lo=tri.min((0,1))-[.15,.15,.15];hi=tri.max((0,1))+[.15,.15,.15]
    fig=plt.figure(figsize=(14,7));axes=[fig.add_subplot(121,projection='3d'),fig.add_subplot(122,projection='3d')]
    for ax,angle in zip(axes,[-65,115]):
        for bi,(_,bt) in context.items():
            keep=(bt.min(1)<=hi).all(1)&(bt.max(1)>=lo).all(1);ax.add_collection3d(Poly3DCollection(bt[keep],facecolors='#64748b',edgecolors='#64748b',alpha=.1,linewidths=.2))
        ax.add_collection3d(Poly3DCollection(tri,facecolors='#0891b2',edgecolors='#164e63',alpha=.5,linewidths=.5))
        ax.scatter(hit_xyz[:,0],hit_xyz[:,1],hit_xyz[:,2],color='#dc2626',s=9,depthshade=False)
        ax.set_xlim(lo[0],hi[0]);ax.set_ylim(lo[1],hi[1]);ax.set_zlim(lo[2],hi[2]);ax.set_box_aspect(hi-lo);ax.set_xticks(np.linspace(lo[0],hi[0],3));ax.set_yticks(np.linspace(lo[1],hi[1],3));ax.set_zticks(np.linspace(lo[2],hi[2],5));ax.view_init(elev=24,azim=angle);ax.set_xlabel('Native X, m');ax.set_ylabel('Native Y, m');ax.set_zlabel('Original Z, m')
    fig.suptitle(f'Ascent {label}: full unchanged source instance, {len(tri)} triangles\nCyan instance; gray nearby geometric contacts; red frozen-query hits lifted to original Z. No role assigned.');fig.subplots_adjust(left=.06,right=.92,bottom=.16,top=.85,wspace=.24);fig.savefig(OUT/f'{label}-original-3d.png',dpi=140);plt.close(fig)
    fig,axes=plt.subplots(1,3,figsize=(16,6));section_rows=[]
    for panel,(ax,height) in enumerate(zip(axes,[None,zlo,zhi])):
        section_ids=[]
        for bi,(fids,bt) in [(oid,(ids,tri)),*context.items()]:
            keep=(bt.min(1)<=hi).all(1)&(bt.max(1)>=lo).all(1);t=bt[keep];f=fids[keep]
            if height is None:lines=np.concatenate([t[:,:,:2],t[:,:1,:2]],axis=1)
            else:
                patch=np.array([[lo[0],lo[1]],[hi[0],lo[1]],[hi[0],hi[1]],[lo[0],hi[1]]]);cut=sections(t,f,np.array([0.,0.,height-1.75]),patch)
                assert cut is not None
                lines,cut_ids=cut;section_ids.append(dict(object=bi,originalFaces=cut_ids,segmentsNativeXY=lines.tolist()))
            ax.add_collection(LineCollection(lines,colors='#0891b2' if bi==oid else '#64748b',alpha=.9 if bi==oid else .3,linewidths=1.4 if bi==oid else .5))
        ax.scatter(hit_xyz[:,0],hit_xyz[:,1],color='#dc2626',s=8);ax.set_xlim(lo[0],hi[0]);ax.set_ylim(lo[1],hi[1]);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_xlabel('Native X, m');ax.set_ylabel('Native Y, m');ax.set_title('Full raw plan' if height is None else f'Raw horizontal cut Z{height:.9f}m')
        if height is not None:section_rows.append(dict(sourceZ=height,objects=section_ids))
    fig.suptitle(f'{label}: local contact heights Z{zlo:.9f}–{zhi:.9f}m; original observer eye Z{observer_z:.9f}m\nThe provisional relative query bends in original Z. These local cuts are not a horizontal ray from that observer.');fig.tight_layout(rect=[0,0,1,.91]);fig.savefig(OUT/f'{label}-original-plan-and-cuts.png',dpi=140);plt.close(fig)
    records.append(dict(object=oid,path=objects[oid]['path'],originalFaces=ids.tolist(),nativeBounds=[tri.min((0,1)).tolist(),tri.max((0,1)).tolist()],geometricBackingObjects=[dict(index=i,**objects[i]) for i in backing_ids],nearestFaceNormalGeometricContacts=contacts,sourceHeightRange=[zlo,zhi],localSourceCuts=section_rows))
    packet.append((oid,ids,tri))
    for bi,(biids,bt) in context.items():
        keep=(bt.min(1)<=hi).all(1)&(bt.max(1)>=lo).all(1);packet.append((bi,biids[keep],bt[keep]))
    print(label,len(tri),'full faces, geometric neighbors',backing_ids,'height range',zlo,zhi)

np.savez_compressed(OUT/'source-context-packet.npz',sourceObjectIds=np.concatenate([np.full(len(t),o) for o,_,t in packet]),originalFaces=np.concatenate([f for _,f,_ in packet]),nativeTriangles=np.concatenate([t for _,_,t in packet]))
inputs=[raw_path,raw_path.with_suffix('.json'),candidate,control,field_path,trace_path]
(OUT/'review.json').write_text(json.dumps(dict(scope=__doc__,geometryMutation=False,roleAssigned=False,observerQuery=q.tolist(),observerOriginalEyeZ=observer_z,reconstruction='Contacted candidate triangles are bitwise equal to control triangles. Lift control vertices by frozen ground, interpolate exact hit barycentrics, and independently verify raw parent plane and direct ground evaluation.',sourceHeightHits=hits,objects=records,inputs=[dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in inputs],limitations=['Geometric backing probes ignore opacity and collision. They identify spatial context only.','These local original-Z cuts explain frozen relative-height contacts; they are not a live horizontal sightline or floor-policy validation.']),indent=2))
