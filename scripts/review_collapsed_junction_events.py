"""Account for empty family sections using exact discarded corner profiles."""
import json,gzip
from pathlib import Path
import numpy as np
import shapely
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from probe_source_junction_closure import mapped_sections

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')

def main():
    folder=REV/'split-wall-family-normalized-candidate-v15';proof=json.loads((folder/'bindings.json').read_text());families={f['edge']:f for f in proof['families']};_,source=pack(Path(proof['sourceBackup']));_,candidate=pack(folder/'split.height.bin.gz');p=np.load(folder/'normalized-face-provenance.npz');report=json.loads((folder/'connected-contour-closure.json').read_text())
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);x=np.array(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;y=np.array(w['targetAttackSvg']).reshape(-1,2);index=np.array(w['triangles']).reshape(-1,3);warp=explicit_warp(x,y-x,index);cells=shapely.polygons(x[index]);tree=shapely.STRtree(cells)
    records=[]
    for pair in report['pairs']:
        edges=pair['edges'];join=np.array(pair['targetJoinSvg']);point=shapely.Point(join);geometry={};discard={}
        for edge in edges:
            ids=p['generatedFaceIds'][p['generatedEdges']==edge];geometry[edge]=candidate['vertices'][candidate['faces'][ids]]
            ids=np.flatnonzero(p['discardedEdges']==edge);parents=p['discardedSourceFaces'][ids];original=source['vertices'][source['faces'][parents]];xyz=np.einsum('nij,njk->nik',p['discardedBarycentrics'][ids],original);sf=families[edge]['sourceFrame'];tf=families[edge]['targetFrame'];sa,sb=families[edge]['sourceAlong'];ta,tb=families[edge]['targetAlong'];xy=xyz[:,:,:2]@m.T+o;along=(xy-np.array(sf['origin']))@np.array(sf['tangent']);target_along=ta+np.clip((along-sa)/(sb-sa),0,1)*(tb-ta);xyz[:,:,:2]=np.array(tf['origin'])+target_along[:,:,None]*np.array(tf['tangent']);discard[edge]=(xyz,parents,ids)
        for row in pair['records']:
            if row['status']!='introduced-disconnection':continue
            z=row['heightMeters'];record=dict(edges=edges,heightMeters=z,targetJoinSvg=join.tolist(),families=[])
            for edge in edges:
                rendered=mapped_sections(geometry[edge],z,m,o,warp,cells,tree,shapely.box(*(join-4),*(join+4)));distance=None if rendered.is_empty else float(rendered.distance(point));xyz,parents,ids=discard[edge];selected=np.flatnonzero((xyz[:,:,2].min(1)<=z)&(xyz[:,:,2].max(1)>=z));hits=[]
                for k in selected:
                    tri=xyz[k];crossings=[]
                    for a,b in zip(tri,np.roll(tri,-1,axis=0)):
                        if a[2]==z:crossings.append(a[:2])
                        if (a[2]-z)*(b[2]-z)<0:crossings.append(a[:2]+(b[:2]-a[:2])*(z-a[2])/(b[2]-a[2]))
                    if crossings and np.max(np.linalg.norm(np.array(crossings)-join,axis=1))<=1e-6:hits.append(dict(controlParent=int(parents[k]),discardRow=int(ids[k]),maximumJoinDistanceSvg=float(np.max(np.linalg.norm(np.array(crossings)-join,axis=1)))))
                record['families'].append(dict(edge=edge,renderedDistanceToJoinSvg=distance,discardedProfilesAtJoin=hits))
            represented=any(f['renderedDistanceToJoinSvg'] is not None and f['renderedDistanceToJoinSvg']<=1e-6 for f in record['families']);missing_supported=all((f['renderedDistanceToJoinSvg'] is not None and f['renderedDistanceToJoinSvg']<=1e-6) or (f['renderedDistanceToJoinSvg'] is None and f['discardedProfilesAtJoin']) for f in record['families']);record['classification']='collapsed-profile-covered-by-retained-neighbor-at-authored-join' if represented and missing_supported else 'unresolved';records.append(record)
    result=dict(scope='Supplemental classification of sampled closure rows. A source overhang can collapse to the authored corner and have no nondegenerate output triangle. It is accounted only when exact discarded source barycentrics reach that corner at the same height and a retained neighboring profile covers it. This does not change tolerances or add geometry.',records=records);(folder/'collapsed-junction-event-review.json').write_text(json.dumps(result,indent=2));print([(r['edges'],r['heightMeters'],r['classification']) for r in records])

if __name__=='__main__':main()
