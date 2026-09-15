"""Replay only five frozen jamb rays through the proposed finite target field."""
import json,gzip
from pathlib import Path
import numpy as np
import shapely
from native_reference_cast import NativeReferenceModel
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from authored_region_cells import barycentric
from render_split_remaining_corner_families import sections
from lift_reviewed_wall_source_heights import sha

R=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');C=R/'split-wall-family-normalized-candidate-v32-precise-v1';O=R/'split-vent-room-jamb-endpoint-v7'
f=json.loads((O/'region-declaration.json').read_text());scope=json.loads((O/'scope-and-topology.json').read_text());frozen=json.loads((C/'vent-left-jamb-shadow-detail.json').read_text());q=np.array(frozen['query'])
p=np.load(C/'normalized-face-provenance.npz');use=np.flatnonzero((p['generatedEdges']==200174)&np.isin(p['generatedRegionCells'],scope['changedCells']));ids=p['generatedFaceIds'][use]
caster=NativeReferenceModel(C/'split.height.bin.gz',R/'native-tactical-rays-build/Release/tactical_reference_cast.dll');_,control=pack(R/'global-ground-complete-v2/split/split.height.bin.gz')
parents=np.load(C/'correspondence.npz')['sourceFaces'];parent=parents[ids];original=control['vertices'][control['faces'][parent]];bary=p['generatedBarycentrics'][use];source=original[:,:1]+np.einsum('nij,njk->nik',bary[:,:,1:],original[:,1:]-original[:,:1])
w=json.loads(gzip.decompress((R/'display-warps-v1/split.display-warp.json.gz').read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);ws=np.array(w['sourceNativeMeters']).reshape(-1,2);wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3);fw=explicit_warp(ws,wt-ws,wc);bw=explicit_warp(wt,ws-wt,wc)
sv=np.array(f['sourceVerticesSvg']);tv=np.array(f['targetVerticesSvg']);cells=np.array(f['triangles']);new=np.empty_like(source)
for i,(tri,cell)in enumerate(zip(source,p['generatedRegionCells'][use])):
    new[i,:,:2]=barycentric(tri[:,:2]@m.T+o,sv[cells[cell]])@tv[cells[cell]]
    # Literal constant coordinates retain their exact authored endpoint.
    for axis in range(2):
        values=tv[cells[cell],axis]
        if np.all(values==values[0]):new[i,:,axis]=values[0]
stored_z=caster.arrays['vertices'][caster.arrays['faces'][ids]][:,:,2]
recovery_error=float(abs(source[:,:,2]-stored_z).max(initial=0))
assert recovery_error<1e-12
new[:,:,2]=stored_z
assert (caster.arrays['faceMasks'][ids]<0).all(),'Unexpected alpha face in this bounded profile'
lines,owners=sections(new,q[2]);shapes=shapely.linestrings(lines);tree=shapely.STRtree(shapes)
warp_polys=shapely.polygons(ws[wc]);warp_tree=shapely.STRtree(warp_polys);rows=[]
for record in frozen['records']:
    end=bw.apply(np.array(record['targetSvg'])[None])[0];delta=end-q[:2];distance=float(np.linalg.norm(delta));path=shapely.LineString([q[:2],end]);events=[0.,1.]
    for cell in warp_tree.query(path,predicate='intersects'):
        for xy in shapely.get_coordinates(path.intersection(warp_polys[cell])):events.append(float(np.clip((xy-q[:2])@delta/(delta@delta),0,1)))
    candidates=[]
    retained=caster.cast(q[:3],np.r_[end,q[2]],end_padding=0,end_inclusive=True,excluded_faces=ids)
    if retained:candidates.append(dict(kind='unchanged-V32-face',face=retained['face'],distanceMeters=retained['distanceMeters'],displaySvg=fw.apply(np.array(retained['point'])[None,:2])[0].tolist()))
    events=np.unique(events)
    for lo,hi in zip(events,events[1:]):
        if hi-lo<1e-12:continue
        xy=q[:2]+np.array([lo,hi])[:,None]*delta;shown=fw.apply(xy);line=shapely.LineString(shown);d=shown[1]-shown[0]
        for li in tree.query(line,predicate='intersects'):
            for point in shapely.get_coordinates(line.intersection(shapes[li])):
                parameter=lo+(hi-lo)*float((point-shown[0])@d/(d@d))
                if parameter*distance>=1e-5:candidates.append(dict(kind='V7-proposed-section',face=int(ids[owners[li]]),distanceMeters=parameter*distance,displaySvg=point.tolist()))
    hit=min(candidates,key=lambda a:a['distanceMeters'])if candidates else None
    rows.append(dict(targetSvg=record['targetSvg'],before=record['hit'],after=hit))
assert rows[0]['after']and rows[0]['after']['kind']=='unchanged-V32-face'
assert all(row['after']is None for row in rows[1:])
report=dict(passed=True,declarationSha256=sha(O/'region-declaration.json'),candidatePackSha256=sha(C/'split.height.bin.gz'),scriptSha256=sha(Path(__file__)),rows=rows,modifiedGeneratedFragments=len(ids),maskedModifiedFragments=0,sourceZLiteral=True,controlSourceZRecoveryError=recovery_error,
    method='Original V32 BVH retains every unaffected face. Modified cells are intersected as exact horizontal source-height sections in SVG against the query split at each display-warp cell. No pack or production mutation.',
    limits='Five frozen provisional-floor rays only. Whole candidate integrity and actual cone render still required after the combined bake.')
(O/'five-ray-review.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(passed=True,fragments=len(ids),rows=rows),indent=2))
