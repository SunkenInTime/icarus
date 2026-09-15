"""Compare the exact boat's along/Z projection with original 3D directional rays."""
import ctypes,gzip,json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
from shapely import Polygon,Point,union_all
from native_reference_cast import NativeReferenceModel
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,REV,OUT


def main():
    pack_path=REV/'full-height-input-v1/ascent/ascent.height.bin.gz'
    library=REV/'native-rounded-profile-oracle-build/build/Release/rounded_profile_oracle.dll'
    source=NativeReferenceModel(pack_path,library)
    correspondence_path=pack_path.parent/'source-correspondence.npz';original_ids=np.load(correspondence_path)['sourceFaces']
    raw_path=ROOT/'supplemented-v2/world/ascent/geometry.npz';meta=json.loads(raw_path.with_suffix('.json').read_text());obj=meta['objects'][7206]
    full_ids=np.flatnonzero((original_ids>=obj['firstFace'])&(original_ids<obj['firstFace']+obj['faceCount']))
    assert len(full_ids)>0
    masks=source.arrays['faceMasks'][full_ids];assert np.all(masks<0),'Masked boat needs exact alpha projection; refuse opaque silhouette.'
    triangles=source.arrays['vertices'][source.arrays['faces'][full_ids]]
    source.arrays['faces']=np.ascontiguousarray(source.arrays['faces'][full_ids]);source.arrays['faceMasks']=np.ascontiguousarray(masks)
    lo,hi=triangles.min((0,1)),triangles.max((0,1));source.arrays['bounds']=np.array([np.r_[lo,hi]],dtype=np.float64);source.arrays['nodes']=np.array([[0,len(full_ids),-1,-1]],dtype=np.int32);source.bind(library)
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg']);inverse=np.linalg.inv(affine[:,:2]);svg=triangles.copy();svg[:,:,:2]=svg[:,:,:2]@affine[:,:2].T+affine[:,2]
    line=np.array([[138.,167.5],[133.5,172.]])
    tangent=line[1]-line[0];length=float(np.linalg.norm(tangent));tangent/=length;normal=np.array([-tangent[1],tangent[0]])
    along=(svg[:,:,:2]-line[0])@tangent;depth=(svg[:,:,:2]-line[0])@normal
    profiles=np.stack((along,svg[:,:,2]),axis=2)
    shape=union_all([Polygon(p) for p in profiles if Polygon(p).area>0])
    packet=OUT/'boat-208-profile-source.npz'
    np.savez_compressed(packet,fullSourceFaces=full_ids,originalSourceFaces=original_ids[full_ids],sourceTrianglesNative=triangles,sourceTrianglesSvgZ=svg,projectedAlongZ=profiles,sourceDepth=depth,sourceBarycentrics=np.tile(np.eye(3),(len(full_ids),1,1)),authoredEndpoints=line)
    rows=[];summaries=[]
    heights=np.linspace(lo[2]+.001,hi[2]-.001,31)
    alongs=np.linspace(.001,length-.001,61)
    for angle in [-60,-40,-20,0,20,40,60]:
        radians=np.deg2rad(angle);direction_svg=normal*np.cos(radians)+tangent*np.sin(radians);direction_native=inverse@direction_svg;direction_native/=np.linalg.norm(direction_native)
        counts=dict(angleDegrees=angle,queries=0,projectedBlockedOriginalClear=0,projectedClearOriginalBlocked=0,boundaryQueries=0,originalBlocked=0,projectedBlocked=0)
        distances=[]
        for z in heights:
            for s in alongs:
                p=Point(float(s),float(z));projected=shape.covers(p);boundary=shape.boundary.distance(p)<1e-8;xy=(line[0]+s*tangent-affine[:,2])@inverse.T;center=np.r_[xy,z]
                start=center-np.r_[direction_native,0]*5;end=center+np.r_[direction_native,0]*5
                hit=source.cast(start,end,min_distance=0,end_padding=0,end_inclusive=True)
                blocked=hit is not None;counts['queries']+=1;counts['boundaryQueries']+=int(boundary);counts['originalBlocked']+=int(blocked);counts['projectedBlocked']+=int(projected)
                counts['projectedBlockedOriginalClear']+=int(projected and not blocked)
                counts['projectedClearOriginalBlocked']+=int(blocked and not projected)
                if hit is not None:distances.append(abs(hit['distanceMeters']-5))
                if projected!=blocked or angle==0:
                    rows.append(dict(angleDegrees=angle,alongSvg=float(s),originalZ=float(z),projectedBlocked=bool(projected),originalBlocked=blocked,nearProfileBoundary=boundary,sourceOriginalFace=None if hit is None else int(original_ids[full_ids[hit['face']]]),sourceHit=hit,query=[start.tolist(),end.tolist()]))
        counts['maximumSourceHitOffsetFromAuthoredLineMeters']=max(distances,default=0);summaries.append(counts)
    fig,axes=plt.subplots(1,2,figsize=(14,6))
    for p in profiles:axes[0].fill(p[:,0],p[:,1],color='#0077b6',alpha=.08)
    axes[0].axvline(0,color='black');axes[0].axvline(length,color='black');axes[0].set_title('Exact source boat along/Z silhouette; no height envelope');axes[0].set_xlabel('Authored diagonal along, SVG');axes[0].set_ylabel('Original Z, m')
    x=np.array([s['angleDegrees'] for s in summaries]);axes[1].bar(x-4,[s['projectedBlockedOriginalClear'] for s in summaries],width=8,label='Projection blocks, original clear',color='#e76f51');axes[1].bar(x+4,[s['projectedClearOriginalBlocked'] for s in summaries],width=8,label='Projection clear, original blocks',color='#2a9d8f');axes[1].set_xlabel('Ray direction relative to wall normal, degrees');axes[1].set_ylabel('Queries');axes[1].legend();axes[1].set_title('Directional difference from original boat geometry')
    fig.tight_layout();fig.savefig(OUT/'boat-208-profile-directional-review.png',dpi=180);plt.close(fig)
    report=dict(format='icarus-nonplanar-source-profile-review-v1',span=208,sourceObject=7206,sourceObjectPath=obj['path'],sourcePackSha256=sha(pack_path),sourceCorrespondenceSha256=sha(correspondence_path),sourceGeometrySha256=meta['geometrySha256'],sourcePacket=str(packet),sourcePacketSha256=sha(packet),nativeLibrarySha256=sha(library),scriptSha256=sha(Path(__file__)),sourceFaces=len(full_ids),maskedSourceFaces=int((masks>=0).sum()),originalZBounds=[float(lo[2]),float(hi[2])],sourceDepthBoundsSvg=[float(depth.min()),float(depth.max())],authoredEndpoints=line.tolist(),summaries=summaries,diagnosticQueries=rows,scope='Isolated exact opaque boat geometry only. Orthographic along/Z projection is compared with the unchanged source triangle caster. Angled differences are measured, not silently excluded; neither full scene nor standing-navigation acceptance is claimed.',mappingProposal='Use only the exact projected source profile on the authored diagonal if this tactical abstraction is accepted. Retain source fragments beyond the finite span and all original Z/UV/material references. No invented full-height wall.',productionMutation=False)
    (OUT/'boat-208-profile-directional-review.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(summaries,indent=2))


if __name__=='__main__':main()
