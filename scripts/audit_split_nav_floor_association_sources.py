"""Source identities behind missing Split nav/render-floor associations.

All exact-XY source intersections are retained without a height band. Nearest
heights rank evidence for inspection only; no floor or tolerance is chosen.
"""
import hashlib
import json
from collections import Counter
from pathlib import Path

import numpy as np
import shapely
from pxr import Usd,UsdGeom

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
OUT=REV/'split-nav-floor-source-association-review-v1'


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def intersections(triangles,queries):
    polygons=shapely.polygons(triangles[:,:,:2]);area=shapely.area(polygons);eligible=np.flatnonzero(area>0)
    tri=triangles[eligible];tree=shapely.STRtree(polygons[eligible]);qi,ti=tree.query(shapely.points(queries[:,:2]),predicate='intersects')
    values=tri[ti];a=values[:,1,:2]-values[:,0,:2];b=values[:,2,:2]-values[:,0,:2];d=queries[qi,:2]-values[:,0,:2]
    det=a[:,0]*b[:,1]-a[:,1]*b[:,0];u=(d[:,0]*b[:,1]-d[:,1]*b[:,0])/det;v=(a[:,0]*d[:,1]-a[:,1]*d[:,0])/det
    bary=np.column_stack((1-u-v,u,v));heights=np.einsum('ni,ni->n',bary,values[:,:,2])
    return qi,eligible[ti],heights,bary


def main():
    OUT.mkdir(exist_ok=False)
    candidate=REV/'all-map-nav-source-floor-candidates-v1/split.floor-candidates.npz';data=np.load(candidate)
    clearance=REV/'split-nav-source-floor-clearance-v1/candidate-columns.npz';columns=np.load(clearance)
    samples=data['samples'];inside=columns['insideSvg'];missing=(data['count']==0)&inside
    counts=np.bincount(columns['sampleIds'],minlength=len(samples));clear=np.bincount(columns['sampleIds'][columns['centerColumnClear']==1],minlength=len(samples))
    blocked=inside&(counts>0)&(clear==0);ids=np.flatnonzero(missing|blocked);queries=samples[ids]
    support_path=REV/'source-floor-support-all-walkable-v1/split.floor-support.npz';support=np.load(support_path)
    sourceids=np.flatnonzero(support['sourceFaces']>=0);tri=support['vertices'][support['triangles'][sourceids]]
    qi,ti,z,bary=intersections(tri,queries)
    full=sourceids[ti];packids=support['sourceFaces'][full];correspondence=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];rawids=correspondence[packids]
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(raw_path);meta=json.loads(raw_path.with_suffix('.json').read_text());starts=np.array([o['firstFace'] for o in meta['objects']])
    objids=np.searchsorted(starts,rawids,side='right')-1
    np.savez_compressed(OUT/'unrestricted-render-support-intersections.npz',sampleIds=ids[qi],sourceHeights=z,originalSourceFaces=rawids,fullPackFaces=packids,supportIds=full,barycentrics=bary)
    print('render intersections',len(qi),'queries',len(ids),flush=True)
    # BVPawn export contains independent meshes, including invisible blocking
    # volumes. These are exported triangle references; native BodySetup/profile
    # verification remains necessary before calling any one the collision floor.
    pawn_path=Path('E:/IcarusWorldAudit/2026-09-04/split-cli-13.05-verified-options/Exports/ShooterGame/Content/Maps/Bonsai/Bonsai_BVPawn.usda')
    stage=Usd.Stage.Open(str(pawn_path));cache=UsdGeom.XformCache();pawn_tri=[];pawn_owner=[];pawn_rows=[]
    for prim in stage.Traverse():
        if not prim.IsA(UsdGeom.Mesh):continue
        mesh=UsdGeom.Mesh(prim);points=np.asarray(mesh.GetPointsAttr().Get(),dtype=float);transform=np.asarray(cache.GetLocalToWorldTransform(prim));points=(points@transform[:3,:3]+transform[3,:3])*.01
        counts=np.asarray(mesh.GetFaceVertexCountsAttr().Get());indices=np.asarray(mesh.GetFaceVertexIndicesAttr().Get())
        if not len(points) or not len(counts):continue
        assert (counts==3).all()
        t=points[indices.reshape(-1,3)];oid=len(pawn_rows);pawn_tri.extend(t);pawn_owner.extend([oid]*len(t))
        pawn_rows.append(dict(primPath=str(prim.GetPath()),firstFace=len(pawn_tri)-len(t),faceCount=len(t),boundsMeters=[points.min(0).tolist(),points.max(0).tolist()],usdVisibility=str(mesh.ComputeVisibility())))
    pawn_tri=np.asarray(pawn_tri);pawn_owner=np.asarray(pawn_owner);pi,pf,pz,pb=intersections(pawn_tri,queries)
    np.savez_compressed(OUT/'pawn-export-intersections.npz',sampleIds=ids[pi],sourceHeights=pz,exportedTriangleIds=pf,barycentrics=pb,sourceTriangles=pawn_tri,sourceObjectIds=pawn_owner)
    print('Pawn export intersections',len(pi),'triangles',len(pawn_tri),flush=True)
    rows=[]
    for local,sid in enumerate(ids):
        hits=np.flatnonzero(qi==local);ordered=hits[np.argsort(abs(z[hits]-samples[sid,2]),kind='stable')]
        def render_row(i):
            oid=int(objids[i]);return dict(sourceObject=oid,path=meta['objects'][oid]['path'],originalFace=int(rawids[i]),fullPackFace=int(packids[i]),supportFace=int(full[i]),height=float(z[i]),deltaFromNav=float(z[i]-samples[sid,2]),barycentrics=bary[i].tolist())
        phits=np.flatnonzero(pi==local);porder=phits[np.argsort(abs(pz[phits]-samples[sid,2]),kind='stable')]
        pawn=[]
        for i in porder:
            oid=int(pawn_owner[pf[i]]);pawn.append(dict(sourceObject=oid,primPath=pawn_rows[oid]['primPath'],exportedTriangle=int(pf[i]),localFace=int(pf[i]-pawn_rows[oid]['firstFace']),height=float(pz[i]),deltaFromNav=float(pz[i]-samples[sid,2]),barycentrics=pb[i].tolist()))
        blocked_records=[]
        for c in np.flatnonzero((columns['sampleIds']==sid)&(columns['centerColumnClear']==0)):
            face=int(columns['hitFullHeightPackFaces'][c]);rid=int(correspondence[face]);oid=int(np.searchsorted(starts,rid,side='right')-1)
            blocked_records.append(dict(candidateHeight=float(columns['sourceHeights'][c]),firstUpwardHitHeight=float(columns['hitHeight'][c]),fullPackFace=face,originalFace=rid,sourceObject=oid,path=meta['objects'][oid]['path']))
        rows.append(dict(sample=int(sid),position=samples[sid].tolist(),displayedSvg=columns['displayedSvg'][sid].tolist(),nativeTriangle=int(data['nativeTriangles'][sid]),nativeParent=int(data['nativeParents'][sid]),missingNearbyRenderSupport=bool(missing[sid]),allNearColumnsBlocked=bool(blocked[sid]),renderCandidates=[render_row(i) for i in ordered],pawnExportCandidates=pawn,blockedColumns=blocked_records))
    report=dict(scope=__doc__,queries=len(ids),missingInside=int(missing.sum()),allColumnsBlocked=int(blocked.sum()),missingNearestRenderObjects=dict(Counter(r['renderCandidates'][0]['path'] if r['renderCandidates'] else 'NO EXACT XY RENDER SUPPORT' for r in rows if r['missingNearbyRenderSupport'])),pawnExportObjects=pawn_rows,records=rows,
        evidence=[dict(path=str(p),sha256=sha(p)) for p in [candidate,clearance,support_path,raw_path,pawn_path,Path(__file__)]],
        limits=['Source support eligibility is pre-existing and provisional. All candidate heights are retained; no larger association window is introduced.','An exported BVPawn mesh alone is not verified cooked Pawn collision. Its component and BodySetup still require attribution.','Only the frozen original Split sample positions are checked. Continuous parent coverage and new floor assignment remain unverified.'],productionMutation=False)
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['queries','missingInside','allColumnsBlocked','missingNearestRenderObjects']}))


if __name__=='__main__':main()
