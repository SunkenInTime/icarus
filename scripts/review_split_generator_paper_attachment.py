"""Source attachment and unchanged-field paper membership proposal. No bake."""
import ctypes
import argparse
from copy import deepcopy
import gzip
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
import shapely

from native_compact_wall_profiles import sha
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from finite_region_cells import region_fragments
from native_region_source import native_source_rows
from authored_wall_profile_cells import inverse_in_cell
from verify_normalized_wall_profiles import verify_source_partition
from native_reference_cast import NativeReferenceModel
from propose_split_generator_region import curve_y

ROOT=Path('E:/IcarusWorldAudit/2026-09-06'); REV=ROOT/'tactical-visibility-revision'


def triangle_hit(origin,target,triangles):
    direction=target-origin; length=np.linalg.norm(direction); direction/=length
    e1=triangles[:,1]-triangles[:,0];e2=triangles[:,2]-triangles[:,0]
    h=np.cross(direction,e2);det=np.einsum('ij,ij->i',e1,h)
    valid=abs(det)>1e-14;inv=np.zeros(len(det));inv[valid]=1/det[valid]
    s=origin-triangles[:,0];u=np.einsum('ij,ij->i',s,h)*inv;q=np.cross(s,e1)
    v=q@direction*inv;t=np.einsum('ij,ij->i',e2,q)*inv
    valid&=(u>=0)&(v>=0)&(u+v<=1)&(t>=1e-5)&(t<length-1e-5)
    ids=np.flatnonzero(valid)
    return None if not len(ids) else (int(ids[np.argmin(t[ids])]),float(t[ids].min()))


def main(family_path=None,output=None):
    output=output or REV/'split-generator-paper1640-attachment-proposal-v1';output.mkdir(exist_ok=False)
    gp=ROOT/'supplemented-v2/world/split/geometry.npz';mp=gp.with_suffix('.json')
    raw=np.load(gp);meta=json.loads(mp.read_text());objects=meta['objects']
    def mesh(owner):
        obj=objects[owner];ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
        return ids,raw['points'][raw['faces'][ids]]
    ids,paper=mesh(1640);gen_ids,generator=mesh(6577)
    plane=float(raw['points'][raw['faces'][2258328]][0,1])
    front=(generator[:,:,1]==plane).all(1)
    wall=generator[front];wall_ids=gen_ids[front]
    paper_profile=shapely.union_all(shapely.polygons(paper[:,:,[0,2]]))
    wall_profile=shapely.union_all(shapely.polygons(wall[:,:,[0,2]]))
    uncovered=float(shapely.difference(paper_profile,wall_profile).area)
    assert uncovered==0
    crossing=(paper[:,:,1].min(1)<plane)&(paper[:,:,1].max(1)>plane)
    fp=family_path or REV/'split-generator-connected-profile-proposal-v4/region-declaration.json'
    original=json.loads(fp.read_text());family=deepcopy(original)
    if family_path is None:
        assert 1640 not in family['objects'] and not set(ids)&set(family['reviewedSourceFaces'])
        family['objects'].append(1640);family['reviewedSourceFaces']=sorted(set(family['reviewedSourceFaces'])|set(ids.tolist()))
        family['paperAttachmentReview']=dict(status='Membership proposal only; unchanged field leaves upper curled paper residual. Not accepted as complete wall fix.',
            sourceObject=1640,sourceFaceCount=len(ids),backingObject=6577,
            policy='Wall-mounted detail absent from SVG follows existing generator field. Preserve complete source Z, UV and current material admission.',
            unchangedFieldSha256=sha(fp))
    else:
        assert family['objects']==[1640] and set(family['reviewedSourceFaces'])==set(ids)
    for key in original:
        if key not in ['objects','reviewedSourceFaces']:assert family[key]==original[key]
    (output/'region-declaration.json').write_text(json.dumps(family,indent=2)+'\n')
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack([w['projection']['axisU'],w['projection']['axisV']]);offset=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix)
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+offset;wt=np.array(w['targetAttackSvg']).reshape(-1,2);cells=np.array(w['triangles']).reshape(-1,3)
    unwarp=explicit_warp(wt,ws-wt,cells);forward=explicit_warp(np.array(w['sourceNativeMeters']).reshape(-1,2),wt-np.array(w['sourceNativeMeters']).reshape(-1,2),cells)
    control_path=REV/'global-ground-complete-v2/split/split.height.bin.gz';_,control=pack(control_path)
    fullraw=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    controlraw=fullraw[np.load(control_path.parent/'correspondence.npz')['sourceFaces']]
    selected=np.flatnonzero(np.isin(controlraw,ids));assert set(controlraw[selected])==set(ids)
    assert (control['faceMasks'][selected]<0).all(), 'This narrow ray review requires opaque paper; masked source needs alpha handling'
    parts=[];parents=[];weights=[];regions=[];mapped=[]
    for index,face in enumerate(selected):
        xyz=control['vertices'][control['faces'][face]];data=np.column_stack([xyz.copy(),np.eye(3)]);data[:,:2]=xyz[:,:2]@matrix.T+offset
        for fragment,warp_cell,region in region_fragments(data,family,unwarp,source_construction=native_source_rows(xyz,matrix,offset)):
            bary=fragment[:,3:];native=bary@xyz;native[:,:2]=(inverse_in_cell(fragment[:,:2],unwarp,warp_cell)-offset)@inverse.T
            for j in range(1,len(fragment)-1):
                take=[0,j,j+1];parts.append(native[take]);weights.append(bary[take]);parents.append(int(face));regions.append(region);mapped.append(fragment[take,:2])
        if index%25==0:print('paper controls',index,len(selected),flush=True)
    parts=np.array(parts);weights=np.array(weights);parents=np.array(parents);mapped=np.array(mapped)
    partition=verify_source_partition(parents,weights,selected.tolist())
    z_expected=np.einsum('nij,nj->ni',weights,control['vertices'][control['faces'][parents]][:,:,2])
    assert np.max(abs(parts[:,:,2]-z_expected))<1e-12
    excess=mapped[:,:,1]-np.array([curve_y(x) for x in mapped[:,:,0].reshape(-1)]).reshape(mapped.shape[:2])
    np.savez_compressed(output/'source-and-mapped-fragments.npz',paperRawFaces=ids,paperTriangles=paper,backingRawFaces=wall_ids,
        backingTriangles=wall,mappedTriangles=parts,mappedSvg=mapped,controlParents=parents,barycentrics=weights,regionCells=regions)
    fan_path=REV/'generator-v30-curved-front-source-fan-v2/report.json';fan=json.loads(fan_path.read_text());q=np.array(fan['summary']['query'][:3])
    candidate=REV/'split-wall-family-normalized-candidate-v30-cached-v1';caster=NativeReferenceModel(candidate/'split.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    candidate_raw=controlraw[np.load(candidate/'correspondence.npz')['sourceFaces']]
    excluded=np.flatnonzero(np.isin(candidate_raw,ids)).astype(np.int32);rows=[]
    fpointer=ctypes.POINTER(ctypes.c_double);ipointer=ctypes.POINTER(ctypes.c_int32)
    for old in fan['rows']:
        goal=(unwarp.apply(np.array(old['authoredCurveSvg'])[None])[0]-offset)@inverse.T
        direction=goal-q[:2];direction/=np.linalg.norm(direction);target=np.r_[goal+direction*.2,q[2]].astype(float)
        result=np.zeros(3);face=caster.nearest(*caster.pointers,q.ctypes.data_as(fpointer),target.ctypes.data_as(fpointer),1e-5,1e-5,0,excluded.ctypes.data_as(ipointer),len(excluded),result.ctypes.data_as(fpointer))
        assert face>=0 and caster.arrays['faceMasks'][face]<0, 'Frozen backing ray must hit opaque source'
        hit=triangle_hit(q,target,parts);distance=float(result[0]);owner=6577 if candidate_raw[face]>=objects[6577]['firstFace'] and candidate_raw[face]<objects[6577]['firstFace']+objects[6577]['faceCount'] else -1
        if hit is not None and hit[1]<distance:distance=hit[1];owner=1640
        direction3=target-q;direction3/=np.linalg.norm(direction3);point=q+direction3*distance;svg=forward.apply(point[None,:2])[0]
        residual=svg[1]-curve_y(svg[0]);rows.append(dict(t=old['t'],previousObject=old['sourceObject'],proposedObject=owner,
            distanceMeters=distance,hitSvg=svg.tolist(),authoredCubicVerticalResidualSvg=float(residual)))
    fig=plt.figure(figsize=(13,6))
    for i,azimuth in enumerate([-80,75]):
        ax=fig.add_subplot(1,2,i+1,projection='3d');ax.add_collection3d(Poly3DCollection(wall,facecolors='#668dad',alpha=.3))
        ax.add_collection3d(Poly3DCollection(paper,facecolors='#e5b751',edgecolors='#8e622b',linewidths=.2,alpha=.95))
        ax.set_xlim(-23.3,-19.9);ax.set_ylim(57.87,58.07);ax.set_zlim(3.6,5.8);ax.set_box_aspect([3.4,.8,2.2]);ax.view_init(20,azimuth)
        ax.set_yticks([57.9,58.0]);ax.set_xlabel('Native X m');ax.set_ylabel('Native Y m');ax.set_zlabel('Original Z m')
    fig.suptitle('Complete paper1640 against actual generator6577 plane. Source geometry, no edits.\nDepth axis expanded four times to show curled paper and attachment.');fig.tight_layout(rect=[0,0,1,.9]);fig.savefig(output/'original-paper-attachment.png',dpi=150);plt.close(fig)
    report=dict(sourceGeometrySha256=sha(gp),sourceMetadataSha256=sha(mp),existingFieldSha256=sha(fp),proposalSha256=sha(output/'region-declaration.json'),
        packetSha256=sha(output/'source-and-mapped-fragments.npz'),scriptSha256=sha(Path(__file__)),fanSha256=sha(fan_path),candidateSha256=sha(candidate/'split.height.bin.gz'),
        sourceObject=objects[1640],backingPlaneNativeY=plane,backingRawFaces=wall_ids.tolist(),paperProjectionOutsideBackingAreaMeters2=uncovered,
        sourceFacesCrossingBackingPlane=int(crossing.sum()),maximumOutwardCurlMeters=float(plane-paper[:,:,1].min()),maximumBehindPlaneMeters=float(paper[:,:,1].max()-plane),
        originalMaterial=meta['materials'][5495],sourceRawFaces=len(ids),controlFaces=len(selected),generatedIncludingDegenerate=len(parts),sourcePartition=partition,
        maximumControlHeightErrorMeters=float(np.max(abs(parts[:,:,2]-z_expected))),fieldGeometryUnchanged=True,
        maximumMappedUpperCurlResidualSvg=float(excess.max()),frozenStandingRayCount=len(rows),previousPaperFirstHits=sum(r['sourceObject']==1640 for r in fan['rows']),
        maximumFrozenStandingCubicResidualSvg=max(abs(r['authoredCubicVerticalResidualSvg']) for r in rows),rows=rows,
        acceptance=('Proposal only. Frozen standing curve fan tested with exact finite field clipping and unchanged full candidate backing. '
                    +('Upper curl remains outside the cubic; do not accept as all-height fix. ' if excess.max()>1e-5 else 'All generated paper fragments lie on the certified cubic polyline at every retained source height. Both-side rendering remains required. ')
                    +'No bake, production data or material policy changed.'))
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['rows','sourcePartition','backingRawFaces','originalMaterial']},indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--family-path',type=Path);parser.add_argument('--output',type=Path)
    args=parser.parse_args();main(args.family_path,args.output)
