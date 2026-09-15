"""Sample source-connected contour joins before and after wall normalization.

Uses declared adjacent wall families, retained source control parents, and exact
W-cell segment splitting. This tests selected family profiles at explicit height
events. It is not a proof of all intervening faces, alpha, or physical sightlines.
"""
import argparse,json,gzip,hashlib
from collections import Counter
from pathlib import Path
import numpy as np
import shapely
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from probe_source_junction_closure import mapped_sections

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')

def main(folder,pairs,failed_events_only=False):
    proof=json.loads((folder/'bindings.json').read_text());family={f['edge']:f for f in proof['families']};source_path=Path(proof['sourceBackup']);_,before=pack(source_path);_,after=pack(folder/'split.height.bin.gz');sparse=np.load(folder/'normalized-face-provenance.npz');generated=np.asarray(sparse['generatedFaceIds']);edges=np.asarray(sparse['generatedEdges'])
    wpath=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wpath.read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);source_svg=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;target_svg=np.array(w['targetAttackSvg']).reshape(-1,2);indices=np.array(w['triangles']).reshape(-1,3);forward=explicit_warp(source_svg,target_svg-source_svg,indices);cells=shapely.polygons(source_svg[indices]);tree=shapely.STRtree(cells)
    results=[]
    existing=json.loads((folder/'connected-contour-closure.json').read_text()) if failed_events_only else None
    for a,b in pairs:
        fa,fb=family[a],family[b];sj=np.array(fa['sharedSourceJoins'][1]);tj=np.array(fa['sharedAuthoredJoins'][1]);lo=np.minimum(sj,tj)-1.;hi=np.maximum(sj,tj)+1.;bounds=[*lo,*hi];clip=shapely.box(*bounds);geometry=[]
        for arrays,selector in [(before,lambda e:np.array(family[e]['controlFaces'])),(after,lambda e:generated[edges==e])]:
            side=[]
            for edge in [a,b]:
                ids=selector(edge);assert not np.any(arrays['faceMasks'][ids]>=0),'Masked source requires separate alpha-profile proof';tri=arrays['vertices'][arrays['faces'][ids]];xy=tri[:,:,:2]@matrix.T+origin;keep=np.all(xy.max(1)>=lo-3,axis=1)&np.all(xy.min(1)<=hi+3,axis=1);side.append(tri[keep])
            geometry.append(side)
        vv=np.concatenate([tri.reshape(-1,3) for side in geometry for tri in side]);xy=vv[:,:2]@matrix.T+origin;near=np.all((xy>=lo)&(xy<=hi),axis=1);events=np.unique(vv[near,2]);heights=np.unique(np.r_[events,(events[:-1]+events[1:])/2,.75,1.75,2.75]);rows=[]
        if existing is not None:
            old_pair=next(p for p in existing['pairs'] if p['edges']==[a,b]);failed=[r['heightMeters'] for r in old_pair['records'] if r['status']=='introduced-disconnection'];heights=np.unique([z+delta for z in failed for delta in [-1e-9,0.,1e-9]])
        for z in heights:
            projected=[[mapped_sections(tri,float(z),matrix,origin,forward,cells,tree,clip) for tri in side] for side in geometry];gap=[None if any(g.is_empty for g in side) else float(shapely.distance(*side)) for side in projected];old,new=gap
            status='source-not-connected-at-sample' if old is None or old>1e-7 else 'introduced-disconnection' if new is None or new>1e-6 else 'connection-preserved';rows.append(dict(heightMeters=float(z),beforeGapSvg=old,afterGapSvg=new,beforeSectionLengthsSvg=[float(g.length) for g in projected[0]],afterSectionLengthsSvg=[float(g.length) for g in projected[1]],status=status))
        result=dict(edges=[a,b],sourceJoinSvg=sj.tolist(),targetJoinSvg=tj.tolist(),clipBoundsSvg=bounds,counts=dict(Counter(r['status'] for r in rows)),records=rows);results.append(result);print(a,b,result['counts'],flush=True)
    out=dict(scope=__doc__,heightMode='Frozen control-relative Z. Source absolute-Z and floor semantics remain separate.',sourcePackSha256=hashlib.sha256(source_path.read_bytes()).hexdigest(),candidatePackSha256=hashlib.sha256((folder/'split.height.bin.gz').read_bytes()).hexdigest(),displayWarpSha256=hashlib.sha256(wpath.read_bytes()).hexdigest(),probeSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),samplePolicy='Every local source and candidate vertex Z, all adjacent-event midpoints, and0.75/1.75/2.75m. Unchanged numerical gates1e-7 before and1e-6 after, in SVG units.',pairs=results)
    (folder/('connected-contour-closure-event-review.json' if failed_events_only else 'connected-contour-closure.json')).write_text(json.dumps(out,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('folder',type=Path);p.add_argument('--pairs',default='84:85,85:86,86:87,94:95,96:10099,10099:97');p.add_argument('--failed-events-only',action='store_true');args=p.parse_args();main(args.folder,[tuple(map(int,pair.split(':'))) for pair in args.pairs.split(',')],args.failed_events_only)
