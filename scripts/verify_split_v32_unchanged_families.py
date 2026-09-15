"""Literal V31 declaration and source-profile preservation in the V32 pack."""
import json
from pathlib import Path
import numpy as np
from tactical_alignment_audit import pack
from lift_reviewed_wall_source_heights import sha

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
old=REV/'split-wall-family-normalized-candidate-v31-precise-v1';new=REV/'split-wall-family-normalized-candidate-v32-precise-v1';stage=REV/'split-connected-contact-stage-v32-precise-v1'
manifest=json.loads((stage/'stage.json').read_text());decl=json.loads((stage/'family-declarations.json').read_text());bindings=[json.loads((x/'bindings.json').read_text())for x in [old,new]]
provenance=[];scenes=[];correspondence=[]
for folder in [old,new]:
    with np.load(folder/'normalized-face-provenance.npz')as d:provenance.append({k:d[k]for k in d.files})
    scenes.append(pack(folder/'split.height.bin.gz')[1]);correspondence.append(np.load(folder/'correspondence.npz')['sourceFaces'])
full=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];control=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'];controlraw=full[control]
superseded=set(manifest['sourceOwnership'][-1]['existingRawParentIntersection'])if manifest['asitePriorityContract']else set()
def sorted_rows(prov,scene,corr,edge):
    selected=prov['generatedEdges']==edge;ids=prov['generatedFaceIds'][selected];parents=corr[ids]
    keep=~np.isin(controlraw[parents],list(superseded))if edge==17 else np.ones(len(ids),bool)
    ids=ids[keep];parents=parents[keep];bary=prov['generatedBarycentrics'][selected][keep];mask=scene['faceMasks'][ids];uv=np.zeros((len(ids),3,2));material=np.full(len(ids),-1)
    m=mask>=0;uv[m]=scene['maskedUvs'][mask[m]];material[m]=scene['maskedMaterials'][mask[m]]
    key=np.c_[parents,bary.reshape(-1,9),prov['generatedWarpCells'][selected][keep],prov['generatedRegionCells'][selected][keep]]
    order=np.lexsort(key[:,::-1].T[::-1])
    return dict(key=key[order],xyz=scene['vertices'][scene['faces'][ids]][order],masked=m[order],uv=uv[order],material=material[order])
records=[]
for edge in manifest['unchangedFamilyEdges']:
    a=next(f for f in bindings[0]['families']if f['edge']==edge);b=next(f for f in bindings[1]['families']if f['edge']==edge);staged=next(f for f in decl if f['edge']==edge)
    assert staged==a,(edge,'Staged declaration changed')
    for key in a:
        if key not in ['controlFaces','originalSourceFaces']:assert a[key]==b[key],(edge,key)
    x,y=[sorted_rows(p,s,c,edge)for p,s,c in zip(provenance,scenes,correspondence)]
    for key in x:assert np.array_equal(x[key],y[key]),(edge,key,x[key].shape,y[key].shape)
    discarded=[]
    for p in provenance:
        choose=p['discardedEdges']==edge
        if edge==17:choose&=~np.isin(controlraw[p['discardedSourceFaces']],list(superseded))
        rows=np.c_[p['discardedSourceFaces'][choose],p['discardedBarycentrics'][choose].reshape(-1,9),p['discardedRegionCells'][choose]]
        order=np.lexsort(rows[:,::-1].T[::-1])if len(rows)else np.array([],int);discarded.append(rows[order])
    assert np.array_equal(*discarded),(edge,'Discarded source partition changed')
    records.append(dict(edge=edge,literalStagedDeclaration=True,compiledMappingLiteral=True,generatedTriangles=len(x['key']),allGeneratedAttributesBitwiseEqual=True,discardedTriangles=len(discarded[0]),discardedSourcePartitionBitwiseEqual=True,
        explicitlySupersededRawParents=len(superseded)if edge==17 else 0))
report=dict(passed=True,basePackSha256=sha(old/'split.height.bin.gz'),candidatePackSha256=sha(new/'split.height.bin.gz'),stageManifestSha256=sha(stage/'stage.json'),scriptSha256=sha(Path(__file__)),families=records,
    limits='Only reviewed replacements/additions may differ. Legacy17 retains its literal mapping; its139 A-site source parents intentionally belong200018. Floor policy remains provisional.')
(new/'literal-unaffected-family-review.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(passed=True,families=len(records),output=str(new/'literal-unaffected-family-review.json'))))
