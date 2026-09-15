"""Conservative source-plane proposals across every authored straight span.

These are review candidates, never acceptance or geometry mutations. Every span
receives a result, including curved, short, ambiguous and incomplete source data.
"""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
POLICY=dict(minimumLengthSvg=2.,standingHeightMeters=1.75,maximumSourcePlaneResidualSvg=.005,maximumSourceNormalZ=.02,maximumSourceTargetAngleDegrees=5.,maximumEndpointShiftSvg=3.,minimumLengthRatio=.8,maximumLengthRatio=1.2,maximumContinuousStandingGapSvg=.001,scope='Conservative proposal thresholds, not game constants or final alignment tolerances.')


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def wall_frame(start,end):
    start,end=np.asarray(start),np.asarray(end);delta=end-start;length=float(np.linalg.norm(delta));tangent=delta/length
    return dict(origin=start.tolist(),tangent=tangent.tolist(),normal=[-float(tangent[1]),float(tangent[0])]),length


def merge_intervals(values,lower,upper):
    result=[]
    for a,b in sorted(values):
        a=max(a,lower);b=min(b,upper)
        if b<=a:continue
        if result and a<=result[-1][1]+1e-9:result[-1][1]=max(result[-1][1],b)
        else:result.append([float(a),float(b)])
    cursor=lower;gaps=[]
    for a,b in result:
        if a>cursor:gaps.append([cursor,a])
        cursor=max(cursor,b)
    if cursor<upper:gaps.append([cursor,upper])
    return result,gaps


def height_segments(triangles,z):
    lines=[]
    for triangle in triangles:
        points=[]
        for a,b in zip(triangle,np.roll(triangle,-1,axis=0)):
            av=a[2]-z;bv=b[2]-z
            if av==0:points.append(a[:2])
            if av*bv<0:points.append(a[:2]+(b[:2]-a[:2])*av/(av-bv))
        if len(points)>=2:
            points=np.unique(np.array(points),axis=0)
            if len(points)>=2:
                distances=np.linalg.norm(points[:,None]-points[None,:],axis=2);i,j=np.unravel_index(distances.argmax(),distances.shape);lines.append([points[i],points[j]])
    return np.array(lines).reshape(-1,2,2)


def propose(name,output):
    coverage_path=REV/f'all-map-wall-span-coverage-v1/{name}/attack.coverage.json.gz';coverage=json.loads(gzip.decompress(coverage_path.read_bytes()))
    source_faces={r['originalSourceFace']:r for r in coverage['sourceFaces']};results=[];pending=[]
    contact_owners={}
    for sample in coverage['samples']:
        if sample.get('status')=='contact' and sample.get('relativeEyeHeightMeters')==POLICY['standingHeightMeters']:
            contact_owners.setdefault(sample['originalSourceFace'],set()).add(sample['span'])
    affine=np.array(json.loads((ROOT/f'tactical-alignment-sides-v1/{name}.json').read_text())['nativeToAttackSvg']);matrix,origin=affine[:,:2],affine[:,2]
    for span in coverage['spans']:
        result=dict(map=name,completeSpan=span['span'],edge=span['legacyStraightEdgeIndex'],authoredStart=span['startSvg'],authoredEnd=span['endSvg'],lengthSvg=span['lengthSvg'],segmentType=span['segmentType'],status='rejected',reasons=[])
        result['adjacentAuthoredSpans']=[{k:other[k] for k in ['span','legacyStraightEdgeIndex','startSvg','endSvg','segmentType']} for other in coverage['spans'] if other['span']!=span['span'] and other['subpath']==span['subpath'] and other['elementIndex']==span['elementIndex'] and (np.linalg.norm(np.array(other['startSvg'])-span['endSvg'])<1e-7 or np.linalg.norm(np.array(other['endSvg'])-span['startSvg'])<1e-7)]
        results.append(result)
        reasons=result['reasons']
        if span['segmentType']!='Line':reasons.append('curved-span-needs-separate-policy');continue
        if span['lengthSvg']<POLICY['minimumLengthSvg']:reasons.append('short-span-retained-in-review-queue');continue
        rows=[coverage['samples'][i] for i in span['sampleRows'] if coverage['samples'][i].get('relativeEyeHeightMeters')==POLICY['standingHeightMeters']]
        result['standingSampleCount']=len(rows)
        if len(rows)!=len(span['samplePositions']) or not rows:reasons.append('standing-sample-position-coverage-incomplete');continue
        if any(r['status']!='contact' for r in rows):reasons.append('missing-or-ambiguous-standing-contact');continue
        if any(sum(r['receiverSides'])!=1 or not r['probeStartInsideReceiver'] for r in rows):reasons.append('ambiguous-receiver-or-observer-side');continue
        if len({r['receiverSign'] for r in rows})!=1:reasons.append('receiver-side-changes-across-span');continue
        result['receiverSign']=rows[0]['receiverSign'];result['maximumObservedGapSvg']=max(abs(r['inwardGapSvg']) for r in rows)
        ids=sorted({r['originalSourceFace'] for r in rows});objects=sorted({r['sourceObjectIndex'] for r in rows});result['standingContactSourceFaces']=ids;result['standingContactObjects']=objects
        triangles=np.array([source_faces[i]['verticesNativeMeters'] for i in ids]);normals=np.array([source_faces[i]['normal'] for i in ids])
        if np.max(abs(normals[:,2]))>POLICY['maximumSourceNormalZ']:reasons.append('standing-contact-is-not-a-near-vertical-plane');continue
        xy=triangles[:,:,:2]@matrix.T+origin;points=xy.reshape(-1,2);center=points.mean(0)
        _,_,basis=np.linalg.svd(points-center,full_matrices=False);tangent=basis[0];target_delta=np.array(span['endSvg'])-span['startSvg']
        if tangent@target_delta<0:tangent=-tangent
        normal=np.array([-tangent[1],tangent[0]]);residual=float(np.max(abs((points-center)@normal)));result['sourcePlaneResidualSvg']=residual
        if residual>POLICY['maximumSourcePlaneResidualSvg']:reasons.append('multiple-source-planes-or-neighboring-return-contact');continue
        angle=float(np.degrees(np.arccos(np.clip(tangent@(target_delta/np.linalg.norm(target_delta)),-1,1))));result['sourceTargetAngleDegrees']=angle
        if angle>POLICY['maximumSourceTargetAngleDegrees']:reasons.append('source-target-direction-disagreement');continue
        along=(points-center)@tangent;start=center+along.min()*tangent;end=center+along.max()*tangent
        frame,length=wall_frame(start,end);target_frame,target_length=wall_frame(span['startSvg'],span['endSvg']);ratio=length/target_length;result['sourceLengthRatio']=ratio
        if not POLICY['minimumLengthRatio']<=ratio<=POLICY['maximumLengthRatio']:reasons.append('source-face-extent-does-not-match-authored-span');continue
        endpoint_shift=np.linalg.norm(np.array([start,end])-np.array([span['startSvg'],span['endSvg']]),axis=1);result['endpointShiftsSvg']=endpoint_shift.tolist()
        if endpoint_shift.max()>POLICY['maximumEndpointShiftSvg']:reasons.append('source-corner-join-too-far-from-authored-endpoint');continue
        result.update(sourceFrame=frame,targetFrame=target_frame,sourceAlong=[0,length],targetAlong=[0,target_length])
        pending.append(result)

    rawpath=ROOT/f'supplemented-v2/world/{name}/geometry.npz';metadata=json.loads(rawpath.with_suffix('.json').read_text())
    source_path=REV/f'global-ground-complete-v2/{name}/{name}.height.bin.gz'
    plot_data={}
    if pending:
        raw=np.load(rawpath);raw_points,raw_faces=raw['points'],raw['faces'];_,control=pack(source_path)
        full=np.load(source_path.parent/'correspondence.npz')['sourceFaces'];original=np.load(REV/f'full-height-input-v1/{name}/source-correspondence.npz')['sourceFaces'][full];order=np.argsort(original);sorted_original=original[order]
        for result in pending:
            sf=result['sourceFrame'];fo=np.array(sf['origin']);tangent=np.array(sf['tangent']);normal=np.array(sf['normal']);length=result['sourceAlong'][1]
            primary=[]
            for obj in result['standingContactObjects']:
                item=metadata['objects'][obj];ids=np.arange(item['firstFace'],item['firstFace']+item['faceCount']);tri=raw_points[raw_faces[ids]];xyz=tri.copy();xyz[:,:,:2]=tri[:,:,:2]@matrix.T+origin
                ns=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]);magnitude=np.linalg.norm(ns,axis=1);nz=np.divide(abs(ns[:,2]),magnitude,out=np.ones(len(ns)),where=magnitude>1e-20)
                plane_distance=np.max(abs((xyz[:,:,:2]-fo)@normal),axis=1);along=(xyz[:,:,:2]-fo)@tangent
                eligible=(plane_distance<=POLICY['maximumSourcePlaneResidualSvg'])&(nz<=POLICY['maximumSourceNormalZ'])&(along.max(1)>=0)&(along.min(1)<=length)
                primary.extend(ids[eligible].tolist())
            primary=sorted(set(primary));result['primaryPlaneSourceFaces']=primary
            conflicts={str(fid):sorted(contact_owners.get(fid,set())-{result['completeSpan']}) for fid in primary if contact_owners.get(fid,set())-{result['completeSpan']}}
            if conflicts:
                result['competingAuthoredContactSpans']=conflicts;result['reasons'].append('source-plane-also-contacts-another-authored-span');continue
            if not set(result['standingContactSourceFaces']).issubset(primary):result['reasons'].append('sampled-source-face-not-in-expanded-plane');continue
            selected=np.concatenate([order[np.searchsorted(sorted_original,i,'left'):np.searchsorted(sorted_original,i,'right')] for i in primary])
            if not len(selected):result['reasons'].append('primary-plane-absent-from-retained-control');continue
            result['expandedMaskedControlFaces']=selected[control['faceMasks'][selected]>=0].tolist()
            if result['expandedMaskedControlFaces']:result['reasons'].append('masked-plane-needs-continuous-alpha-profile-review');continue
            tri=control['vertices'][control['faces'][selected]].copy();tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin;segments=height_segments(tri,POLICY['standingHeightMeters'])
            along=(segments-fo)@tangent;intervals,gaps=merge_intervals([(a.min(),a.max()) for a in along],0,length);maximum_gap=max([b-a for a,b in gaps],default=0)
            result.update(controlFaces=selected.tolist(),standingProfileIntervalsSvg=intervals,standingProfileGapsSvg=gaps,maximumStandingProfileGapSvg=maximum_gap,sourceObjects=[dict(sourceObjectIndex=i,**metadata['objects'][i]) for i in result['standingContactObjects']])
            if maximum_gap>POLICY['maximumContinuousStandingGapSvg']:result['reasons'].append('continuous-standing-source-profile-has-a-gap');continue
            source_tri=raw_points[raw_faces[primary]].copy();source_tri[:,:,:2]=source_tri[:,:,:2]@matrix.T+origin;extent=(source_tri[:,:,:2]-fo)@tangent
            # Do not silently clamp an unrelated continuation from the same
            # coplanar instance just because a few of its vertices touch scope.
            if extent.min() < -.005 or extent.max()>length+.005:result['reasons'].append('coplanar-face-continues-beyond-proposed-source-endpoint');continue
            result.update(status='proposal-needs-personal-source-and-corner-review',sourceHeightRangeMeters=[float(source_tri[:,:,2].min()),float(source_tri[:,:,2].max())],heightPolicy='Preserve every listed source triangle profile and alpha. Continuous standing coverage is a proposal filter, never a full-height extrusion.',sourceProfileVerticesNative=raw_points[raw_faces[primary]].tolist())
            plot_data[result['completeSpan']]=(segments,source_tri)
        # A source triangle cannot be normalized independently to two authored
        # spans. Reject both proposals; a future joint corner binding is needed.
        owners={}
        for result in pending:
            if result['status'].startswith('proposal'):
                for fid in result['primaryPlaneSourceFaces']:owners.setdefault(fid,[]).append(result)
        for fid,uses in owners.items():
            if len(uses)>1:
                for result in uses:
                    result['status']='rejected';result.setdefault('conflictingSourceFaces',[]).append(fid)
                    if 'source-face-owned-by-multiple-authored-spans' not in result['reasons']:result['reasons'].append('source-face-owned-by-multiple-authored-spans')

    proposals=[r for r in results if r['status'].startswith('proposal')]
    summary=dict(map=name,spans=len(results),proposals=len(proposals),rejected=len(results)-len(proposals),reasons=dict(Counter(reason for r in results for reason in r['reasons'])),totalProposedLengthSvg=sum(r['lengthSvg'] for r in proposals),totalAuthoredLengthSvg=sum(r['lengthSvg'] for r in results))
    report=dict(scope='Review proposals only. Source profiles from provisional ground-control packs are not independent gameplay certification. Curved, short, mixed-plane, missing-contact and shared-corner cases remain explicit rejected queues.',policy=POLICY,generatorSha256=sha(Path(__file__)),sourceGeometrySha256=metadata['geometrySha256'],sourcePackSha256=sha(source_path),artSha256=coverage['artSha256'],coverageSha256=sha(coverage_path),summary=summary,results=results)
    (output/f'{name}.json.gz').write_bytes(gzip.compress(json.dumps(report,separators=(',',':')).encode(),mtime=0));(output/f'{name}-summary.json').write_text(json.dumps(summary,indent=2))
    chosen=sorted(proposals,key=lambda r:r['maximumObservedGapSvg'],reverse=True)[:6]
    if chosen:
        w=json.loads(gzip.decompress((REV/f'display-warps-v1/{name}.display-warp.json.gz').read_bytes()));before=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;after=np.array(w['targetAttackSvg']).reshape(-1,2);warp=explicit_warp(before,after-before,np.array(w['triangles']).reshape(-1,3))
        fig,axes=plt.subplots(len(chosen),2,figsize=(13,3*len(chosen)),squeeze=False)
        for row,result in enumerate(chosen):
            segments,source_tri=plot_data[result['completeSpan']];ax=axes[row,0];mapped=[]
            for line in segments:
                points=warp.apply(np.linspace(line[0],line[1],max(2,int(np.linalg.norm(line[1]-line[0])/.2)+1)));mapped.extend(np.stack((points[:-1],points[1:]),axis=1))
            ax.add_collection(LineCollection(mapped,colors='#0284c7',linewidths=1));line=np.array([result['authoredStart'],result['authoredEnd']]);ax.plot(*line.T,color='#ea580c',linewidth=2);lo=line.min(0)-2;hi=line.max(0)+2;ax.set_xlim(lo[0],hi[0]);ax.set_ylim(hi[1],lo[1]);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f"Span{result['completeSpan']} / edge{result['edge']}; standing source blue, SVG orange\nObserved gap ≤{result['maximumObservedGapSvg']:.3f} SVG; {len(result['primaryPlaneSourceFaces'])} exact source faces")
            ax=axes[row,1];sf=result['sourceFrame'];along=(source_tri[:,:,:2]-sf['origin'])@sf['tangent']
            for a,triangle in zip(along,source_tri):ax.fill(a,triangle[:,2],color='#0284c7',alpha=.2);ax.plot(np.r_[a,a[0]],np.r_[triangle[:,2],triangle[0,2]],color='#075985',linewidth=.3)
            ax.set_title('Original source along/Z profile; every layer stays separate');ax.set_xlabel('Source along, SVG');ax.set_ylabel('Original source Z, m');ax.grid(alpha=.2)
        fig.suptitle(f'{name.title()}: highest observed-gap proposals, not accepted wall families');fig.tight_layout(rect=[0,0,1,.985]);fig.savefig(output/f'{name}-contact-sheet.png',dpi=145);plt.close(fig)
    print(json.dumps(summary),flush=True)
    return summary


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--maps',default='abyss,ascent,bind,breeze,corrode,fracture,haven,icebox,lotus,pearl,split,summit,sunset');p.add_argument('--output',default='all-map-straight-wall-proposals-v1');args=p.parse_args();output=REV/args.output;output.mkdir(exist_ok=True)
    summaries=[propose(name,output) for name in args.maps.split(',')];(output/'summary.json').write_text(json.dumps(dict(policy=POLICY,maps=summaries),indent=2))
