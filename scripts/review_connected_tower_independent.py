"""Read-only review of V14 tower ownership and the four changed edge91 rays."""
import gzip,json
from pathlib import Path
import numpy as np
import shapely
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp
from native_compact_wall_profiles import sha
from verify_normalized_wall_profiles import profile_frame
ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision';folder=REV/'split-wall-family-normalized-candidate-v14';out=REV/'split-tower-independent-review-v14';out.mkdir(exist_ok=True)
bindings=json.loads((folder/'bindings.json').read_text());families={f['edge']:f for f in bindings['families']};wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix);src=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;dst=np.array(w['targetAttackSvg']).reshape(-1,2);tri=np.array(w['triangles']).reshape(-1,3);backward=explicit_warp(dst,src-dst,tri);forward=explicit_warp(src,dst-src,tri)
library=REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll';control=NativeReferenceModel(Path(bindings['sourceBackup']),library);candidate=NativeReferenceModel(folder/'split.height.bin.gz',library);p=np.load(folder/'normalized-face-provenance.npz');parents=np.load(folder/'correspondence.npz')['sourceFaces'];control_full=np.load(Path(bindings['sourceBackup']).parent/'correspondence.npz')['sourceFaces'];full_original=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];original_ids=full_original[control_full];meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text());starts=np.array([o['firstFace'] for o in meta['objects']]);records=json.loads((folder/'independent-junction-rays.json').read_text())['records'];changed=[r for r in records if r['svgEdge']==91 and r['status']=='no-candidate-hit' and r['sourceOriginallyBlocked']]
review=[];profiles={};all_ownership={}
for edge,f in families.items():
    for fid in f.get('reviewedSourceFaces',[]):all_ownership.setdefault(fid,[]).append(edge)
    if edge not in [89,90,91,92,93]:continue
    ids=p['generatedFaceIds'][p['generatedEdges']==edge];xyz=candidate.arrays['vertices'][candidate.arrays['faces'][ids]];display=forward.apply((xyz[:,:,:2]@matrix.T+origin).reshape(-1,2)).reshape(-1,3,2);o,t,n=profile_frame(f,'target');profile=np.stack(((display-o)@t,xyz[:,:,2]),axis=2);polys=[]
    for item in profile:
        geom=shapely.Polygon(item)
        if geom.area>0 and geom.is_valid:polys.append(geom)
    profiles[edge]=(ids,profile,shapely.union_all(polys))
for r in changed:
    xy=(backward.apply(np.array([r['startSvg'],r['expectedContactSvg']]))-origin)@inverse.T;finish=xy[1]+.5*(xy[1]-xy[0]);z=r['relativeEyeHeightMeters'];a=np.r_[xy[0],z];b=np.r_[finish,z];old=control.cast(a,b);new=candidate.cast(a,b);assert old and new is None;fid=int(old['face']);raw=int(original_ids[fid]);obj=int(np.searchsorted(starts,raw,side='right')-1);owned=[f['edge'] for f in bindings['families'] if fid in f['controlFaces']];o,t,_=profile_frame(families[91],'target');along=float((np.array(r['expectedContactSvg'])-o)@t);region=profiles[91][2];vertical=region.intersection(shapely.LineString([[along,-100],[along,100]]))
    mapped=[]
    for i in np.flatnonzero(parents[p['generatedFaceIds']]==fid):
        face=int(p['generatedFaceIds'][i]);edge=int(p['generatedEdges'][i]);xyz=candidate.arrays['vertices'][candidate.arrays['faces'][face]];display=forward.apply(xyz[:,:2]@matrix.T+origin);mapped.append(dict(candidateFace=face,edge=edge,verticesSvgZ=np.column_stack((display,xyz[:,2])).tolist()))
    review.append(dict(query=r,controlHit=old,controlHitDisplayedSvg=forward.apply(np.array(old['point'][:2])@matrix.T+origin).tolist(),originalSourceFace=raw,sourceObjectIndex=obj,sourceObjectPath=meta['objects'][obj]['path'],claimedControlFamilies=owned,generatedFragments=mapped,edge91ProfileHeightIntervalsAtContact=shapely.get_coordinates(vertical).tolist(),edge91ProfileDistance=float(region.distance(shapely.Point(along,z))),nativeQuery=np.r_[a,b].tolist()))
fig,axes=plt.subplots(1,3,figsize=(17,5))
for ax,edge in zip(axes,[90,91,92]):
    ids,profile,region=profiles[edge]
    for polygon in profile:ax.fill(polygon[:,0],polygon[:,1],color='#247ba0',alpha=.15)
    ax.set_xlim(-.1,min(families[edge]['targetAlong'][1]+.1,32));ax.set_ylim(-.2,8);ax.set_title(f'Edge {edge}: retained control height profiles');ax.set_xlabel('Authored along distance, SVG');ax.set_ylabel('Control relative Z, metres');ax.grid(alpha=.2)
    if edge==91:
        for z in [.75,1.75,2.75]:ax.scatter([2],[z],c='#e63946',s=35)
fig.tight_layout();fig.savefig(out/'tower-90-91-92-profiles.png',dpi=180);plt.close(fig)
report=dict(scope=__doc__,candidateSha256=sha(folder/'split.height.bin.gz'),bindingsSha256=sha(folder/'bindings.json'),provenanceSha256=sha(folder/'normalized-face-provenance.npz'),sourceSha256=sha(Path(bindings['sourceBackup'])),scriptSha256=sha(Path(__file__)),duplicateReviewedSourceOwners={str(k):v for k,v in all_ownership.items() if len(v)>1},changedRays=review,productionMutation=False)
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps([dict(sourceFace=r['originalSourceFace'],object=r['sourceObjectPath'],owners=r['claimedControlFamilies'],height=r['query']['relativeEyeHeightMeters'],profileDistance=r['edge91ProfileDistance'],intervals=r['edge91ProfileHeightIntervalsAtContact']) for r in review],indent=2))
