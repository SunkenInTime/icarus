"""Locate source-area duplication in a frozen region candidate's two stages."""
import json,gzip
from pathlib import Path
import numpy as np
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from authored_region_cells import partition_mesh,barycentric
from exact_source_partition import prove_partition
from prepare_ascent_connected_corners import REV

folder=REV/'ascent-connected-component5-candidate-v5';b=json.loads((folder/'bindings.json').read_text());f=b['families'][0];_,a=pack(Path(b['sourceBackup']));w=json.loads(gzip.decompress((REV/'display-warps-v1/ascent.display-warp.json.gz').read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.asarray(w['projection']['origin']);s=np.asarray(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;t=np.asarray(w['targetAttackSvg']).reshape(-1,2);warp=explicit_warp(t,s-t,np.asarray(w['triangles']).reshape(-1,3));fid=556571;tri=a['vertices'][a['faces'][fid]].copy();tri[:,:2]=tri[:,:2]@m.T+o;data=np.column_stack((tri,np.eye(3)));sp=np.asarray(f['sourceVerticesSvg']);tp=np.asarray(f['targetVerticesSvg']);cells=np.asarray(f['triangles']);parts=partition_mesh(data,sp,cells)
def triangulate(parts):return np.asarray([p[[0,j,j+1],3:] for p in parts for j in range(1,len(p)-1)])
rows=[]
for p,c in parts:
    q=p.copy();q[:,:2]=barycentric(q[:,:2],sp[cells[c]])@tp[cells[c]];wp=[x for x,_ in partition_mesh(q,warp.points,warp.tri.simplices)]
    before=triangulate([p]);after=triangulate(wp)
    import shapely
    beforepoly=shapely.union_all(shapely.polygons(before[:,:,1:]));afterpolys=shapely.polygons(after[:,:,1:]);union=shapely.union_all(afterpolys)
    missing=beforepoly.symmetric_difference(union).area*2;overlap=max(0.,sum(x.area for x in afterpolys)-union.area)*2
    rows.append(dict(cell=c,part=p.tolist(),mapped=q.tolist(),pieces=len(after),relativeMissing=missing,relativeOverlap=overlap))
report=dict(sourceTriangle=tri.tolist(),sourceStage=prove_partition(triangulate([p for p,c in parts])),rows=rows)
(folder/'bary-partition-stage-diagnostic.json').write_text(json.dumps(report,indent=2)+'\n');print('source',report['sourceStage']['passed'],report['sourceStage']['relativeSymmetricDifferenceUpperBound']['decimal']);print(json.dumps([r for r in rows if r['relativeMissing']>1e-9 or r['relativeOverlap']>1e-9],indent=2))
