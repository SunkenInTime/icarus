"""Bounded terminal-profile correction for the demonstrated western vent jamb."""
import json,gzip,copy
from pathlib import Path
import numpy as np
import shapely
from seal_split_legacy105_rank_one_declarations import seal
from verify_region_mapping import verify_region_topology
from tactical_alignment_composite import explicit_warp
from lift_reviewed_wall_source_heights import sha

R=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
prior=R/'split-vent-room-finite-field-experiment-v6/sealed-held-region-declaration.json'
out=R/'split-vent-room-jamb-endpoint-v7';out.mkdir(exist_ok=False)
old=json.loads(prior.read_text());f=copy.deepcopy(old);s=np.array(f['sourceVerticesSvg']);t=np.array(f['targetVerticesSvg']);cells=np.array(f['triangles'])
# Existing finite-cell breakpoints. The full source terminal lies inside the
# plateau; the two adjoining bands join the already reviewed room mapping.
x0,x1,x2,x3=213.45656076289248,219.8870750927633,220.8797744870143,224.63315766092913
y0,y1,y2,y3=210.50658377433626,212.00994659427406,212.7,218.
weight=np.interp(s[:,0],[x0,x1,x2,x3],[0.,1.,1.,0.])
shift=np.interp(s[:,1],[y0,y1,y2,y3],[0.,y1-211.513,y2-211.513,0.])
t[:,1]-=weight*shift
plateau=(s[:,0]>=x1)&(s[:,0]<=x2)&(s[:,1]>=y1)&(s[:,1]<=y2)
t[plateau,1]=211.513
f['targetVerticesSvg']=t.tolist();f,rank=seal(f)
for d in f['declaredRankOneMappings']:d['id']=d['id'].replace('legacy105','vent-jamb-v7')
f['jambEndpointRevision']=dict(priorDeclarationSha256=sha(prior),sourceXSupport=[x0,x1,x2,x3],sourceYSupport=[y0,y1,y2,y3],targetEndpointY=211.513,
    reason='Source7789 western terminal shadow exceeded the authored jamb end. Retain finite source Z and UV; normalize this endpoint to the same SVG line as the preserved pipe200190.')
f['status']='Held finite jamb-endpoint proposal; requires source-scope and five-ray review before bake.'
p=out/'region-declaration.json';p.write_text(json.dumps(f,indent=2)+'\n')
w=json.loads(gzip.decompress((R/'display-warps-v1/split.display-warp.json.gz').read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;wt=np.array(w['targetAttackSvg']).reshape(-1,2);fw=explicit_warp(ws,wt-ws,np.array(w['triangles']).reshape(-1,3))
topology=verify_region_topology(f,fw)
changed=np.flatnonzero(np.any(t!=np.array(old['targetVerticesSvg']),axis=1));changed_cells=np.flatnonzero(np.isin(cells,changed).any(1));region=shapely.union_all(shapely.polygons(s[cells[changed_cells]]))
raw=R.parent/'supplemented-v2/world/split/geometry.npz'
with np.load(raw)as data:points=data['points'];faces=data['faces']
meta=json.loads(raw.with_suffix('.json').read_text());records=[]
for obj in f['objects']:
    item=meta['objects'][obj];ids=np.arange(item['firstFace'],item['firstFace']+item['faceCount']);tri=points[faces[ids]][:,:,:2]@m.T+o;shapes=shapely.convex_hull(shapely.multipoints(tri));affected=ids[shapely.intersects(shapes,region)]
    if len(affected):records.append(dict(object=obj,rawParents=affected.tolist(),sourcePath=item['path']))
report=dict(priorDeclarationSha256=sha(prior),declarationSha256=sha(p),scriptSha256=sha(Path(__file__)),sourceVerticesUnchanged=f['sourceVerticesSvg']==old['sourceVerticesSvg'],sourceCellsUnchanged=f['triangles']==old['triangles'],sourceMembershipUnchanged=f['objects']==old['objects']and f['reviewedSourceFaces']==old['reviewedSourceFaces'],targetXUnchanged=bool(np.array_equal(t[:,0],np.array(old['targetVerticesSvg'])[:,0])),changedVertices=changed.tolist(),changedCells=changed_cells.tolist(),affectedSource=records,topology=topology,rank=rank,sourceZandUv='Not edited; remain interpolated from literal source parents.')
(out/'scope-and-topology.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(output=str(out),declarationSha256=sha(p),changedVertices=len(changed),changedCells=len(changed_cells),affected=[dict(object=a['object'],faces=len(a['rawParents']))for a in records])))
