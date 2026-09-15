"""Verify compiled source-world wall oracle against sealed original source lineage.

This does not trust lifted fragment heights as its reference. It recovers source
coordinates independently from the original control backup/ground field and
sealed control-to-full mapping, then checks the compiled oracle and coverage.
"""
import argparse,gzip,json
from collections import defaultdict
from pathlib import Path
import numpy as np
import shapely
from scipy.spatial import cKDTree
from scipy.optimize import linear_sum_assignment
from scipy.spatial.distance import cdist
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from build_global_tactical_candidate import GroundField
from verify_normalized_wall_profiles import profile_frame
from native_compact_wall_profiles import sha

def dominant_bary(points,triangles):
    e=triangles[:,1:]-triangles[:,:1];normal=np.cross(e[:,0],e[:,1]);drop=np.argmax(abs(normal),axis=1);bary=np.empty((len(points),3,3));error=0.
    for axis in range(3):
        ids=np.flatnonzero(drop==axis)
        if not len(ids):continue
        keep=[i for i in range(3) if i!=axis];basis=np.swapaxes(e[ids][:,:,keep],1,2);rhs=np.swapaxes((points[ids]-triangles[ids,:1])[:,:,keep],1,2)
        uv=np.swapaxes(np.linalg.solve(basis,rhs),1,2);bary[ids]=np.concatenate((1-uv.sum(2,keepdims=True),uv),axis=2)
    recovered=np.einsum('nij,njk->nik',bary,triangles);error=float(np.linalg.norm(recovered-points,axis=2).max(initial=0));return bary,error

def polygons(values):
    result=[]
    for triangle in values:
        p=shapely.Polygon(triangle[:,1:])
        if not p.is_valid:p=shapely.MultiPoint(triangle[:,1:]).convex_hull
        result.append(p)
    return result

def verify(compiled,candidate,full_path,warp_path,output):
    if output.exists():raise FileExistsError(output)
    b=json.loads((candidate/'bindings.json').read_text());sealed=json.loads((candidate/'independent-profile-review.json').read_text());data=json.loads(gzip.decompress((compiled/'wall-profiles.json.gz').read_bytes()));backup=Path(b['sourceBackup']);original=Path(b.get('originalSourcePack',str(backup)));control_header,control=pack(backup);full_header,full=pack(full_path);oracle_path=compiled/'oracle'/f'{data["map"]}.height.bin.gz';oracle_header,oracle=pack(oracle_path)
    assert sha(backup)==sha(original)==b['sourcePackSha256'];assert sha(full_path)==control_header['sourcePackSha256'];assert sha(warp_path)==b['displayWarpSha256']==data['displayWarpSha256'];assert sha(candidate/'bindings.json')==sealed['wallBindingsSha256']==data['bindingsSha256'];assert sha(candidate/f'{data["map"]}.height.bin.gz')==sealed['candidatePackSha256'];assert sha(oracle_path)==data['candidatePackSha256']
    ground_path=original.parent/f'{data["map"]}.tactical-ground.json.gz';assert sha(ground_path)==control_header['tacticalGroundFieldSha256'];field=GroundField(ground_path)
    c2f=np.load(original.parent/'correspondence.npz')['sourceFaces'].astype(np.int64);parents=np.load(candidate/'correspondence.npz')['sourceFaces'];p=np.load(candidate/'normalized-face-provenance.npz')
    gparents=parents[p['generatedFaceIds']];dparents=p['discardedSourceFaces'].astype(np.int64);allparents=np.unique(np.r_[gparents,dparents]);control_tri=control['vertices'][control['faces'][allparents]].copy();lifted=control_tri.copy();lifted[:,:,2]+=field.heights(lifted[:,:,:2].reshape(-1,2)).reshape(-1,3);source_tri=full['vertices'][full['faces'][c2f[allparents]]];parent_bary,plane_error=dominant_bary(lifted,source_tri);assert plane_error<1e-7
    lookup={int(parent):i for i,parent in enumerate(allparents)};families={f['edge']:f for f in b['families']}
    warp=json.loads(gzip.decompress(warp_path.read_bytes()));matrix=np.column_stack((warp['projection']['axisU'],warp['projection']['axisV']));origin=np.array(warp['projection']['origin']);source_svg=np.array(warp['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;target_svg=np.array(warp['targetAttackSvg']).reshape(-1,2);forward=explicit_warp(source_svg,target_svg-source_svg,np.array(warp['triangles']).reshape(-1,3))
    expected=defaultdict(list);discard_expected={};expected_generated=0;zero_discards=[]
    for i,(parent,edge) in enumerate(zip(gparents,p['generatedEdges'])):
        if edge<0:continue
        bary=p['generatedBarycentrics'][i]@parent_bary[lookup[int(parent)]];expected[(int(edge),int(c2f[parent]))].append(bary);expected_generated+=1
    # Decide required discarded coverage from sealed data, without trusting the compiler's restored list.
    for i,(parent,edge) in enumerate(zip(dparents,p['discardedEdges'])):
        if edge<0:continue
        idx=lookup[int(parent)];bary=p['discardedBarycentrics'][i]@parent_bary[idx];source=source_tri[idx,0]+bary[:,1:]@(source_tri[idx,1:]-source_tri[idx,0]);ctrl=p['discardedBarycentrics'][i]@control_tri[idx];f=families[int(edge)];o,t,_=profile_frame(f,'source');along=(ctrl[:,:2]@matrix.T+origin-o)@t;lo,hi=f['sourceAlong'];tlo,thi=f['targetAlong'];target=tlo+np.clip((along-lo)/(hi-lo),0,1)*(thi-tlo);profile=np.column_stack((target,source[:,2]));area=abs(np.linalg.det(np.stack((profile[1]-profile[0],profile[2]-profile[0]))))*.5
        # Different independent arithmetic can classify a numerical zero differently.
        discard_expected[i]=dict(edge=int(edge),parent=int(c2f[parent]),bary=bary,profile=profile,area=float(area))
        if area==0:zero_discards.append(i)
    corr=np.load(compiled/'source-correspondence.npz');oids=corr['oracleFaceIds'].astype(np.int64);assert set(oids)==set(range(len(oracle['faces'])));assert len(oids)==len(corr['fullSourceParents'])
    actual_tri=oracle['vertices'][oracle['faces'][oids]];full_parents=corr['fullSourceParents'].astype(np.int64);bary=corr['sourceBarycentrics'];assert bary.shape==(len(oids),3,3);assert np.isfinite(bary).all();minimum=float(bary.min());sum_error=float(abs(bary.sum(2)-1).max());assert minimum>=-1e-7 and sum_error<1e-10
    original_tri=full['vertices'][full['faces'][full_parents]];source_xyz=original_tri[:,:1]+np.einsum('nij,njk->nik',bary[:,:,1:],original_tri[:,1:]-original_tri[:,:1]);z_error=float(abs(source_xyz[:,:,2]-actual_tri[:,:,2]).max(initial=0));assert z_error<1e-10
    op=np.load(compiled/'oracle/normalized-face-provenance.npz');edge_by_id=dict(zip(op['generatedFaceIds'],op['generatedEdges']));edges=np.array([edge_by_id[i] for i in oids]);displayed=forward.apply((actual_tri[:,:,:2]@matrix.T+origin).reshape(-1,2)).reshape(-1,3,2);max_normal=max_along=0.;actual=defaultdict(list);restored=defaultdict(list)
    for i,(parent,edge) in enumerate(zip(full_parents,edges)):
        f=families[int(edge)];so,st,_=profile_frame(f,'source');to,tt,tn=profile_frame(f,'target');salong=(source_xyz[i,:,:2]@matrix.T+origin-so)@st;lo,hi=f['sourceAlong'];tlo,thi=f['targetAlong'];expected_along=tlo+np.clip((salong-lo)/(hi-lo),0,1)*(thi-tlo);max_normal=max(max_normal,float(abs((displayed[i]-to)@tn).max()));max_along=max(max_along,float(abs((displayed[i]-to)@tt-expected_along).max()));discard=int(corr['restoredDiscardIds'][i]);
        if discard>=0:
            assert discard in discard_expected,('Unknown restored discard',discard)
            expected_discard=discard_expected[discard]
            assert int(parent)==expected_discard['parent'] and int(edge)==expected_discard['edge'],('Restored discard lineage mismatch',discard,int(parent),int(edge),expected_discard['parent'],expected_discard['edge'])
            restored[discard].append(bary[i])
        else:actual[(int(edge),int(parent))].append(bary[i])
    assert max_normal<1e-8 and max_along<1e-8,(max_normal,max_along)
    full_masks=full['faceMasks'][full_parents];oracle_masks=oracle['faceMasks'][oids];assert np.array_equal(full_masks<0,oracle_masks<0);uv_error=0.
    masked=full_masks>=0
    if masked.any():
        expected_uv=np.einsum('nij,njk->nik',bary[masked],full['maskedUvs'][full_masks[masked]]);uv_error=float(abs(expected_uv-oracle['maskedUvs'][oracle_masks[masked]]).max());assert uv_error<1e-9;assert np.array_equal(full['maskedMaterials'][full_masks[masked]],oracle['maskedMaterials'][oracle_masks[masked]])
    assert full_header['materials']==oracle_header['materials']
    # Texture content is compared independently of container offsets and copies.
    import struct
    def texture_hashes(path,header):
        raw=gzip.decompress(path.read_bytes());base=(8+struct.unpack_from('<I',raw,4)[0]+7)//8*8
        import hashlib
        return [(t['width'],t['height'],hashlib.sha256(raw[base+t['offset']:base+t['offset']+t['width']*t['height']]).hexdigest()) for t in header['textures']]
    assert texture_hashes(full_path,full_header)==texture_hashes(oracle_path,oracle_header)
    max_difference=max_extra_overlap=max_hausdorff=0.;failures=[]
    for key in set(expected)|set(actual):
        # Sealed surviving fragments must match one-to-one, including degenerate
        # ones. Polygon Hausdorff distances are unstable for nearly collinear
        # barycentric footprints and can conceal duplicate/missing records.
        ep=np.asarray(expected.get(key,[])).reshape(-1,9);ap=np.asarray(actual.get(key,[])).reshape(-1,9)
        if len(ep)!=len(ap) or not len(ep):failures.append(dict(edge=key[0],fullSourceParent=key[1],expectedFragments=len(ep),actualFragments=len(ap)));continue
        distances,indices=cKDTree(ep).query(ap)
        if len(set(indices))!=len(indices):
            costs=cdist(ap,ep);ri,ci=linear_sum_assignment(costs);distances=costs[ri,ci]
        error=float(distances.max());max_hausdorff=max(max_hausdorff,error)
        if error>1e-8:failures.append(dict(edge=key[0],fullSourceParent=key[1],fragmentBaryError=error))
    restoration=[]
    for i in set(discard_expected)|set(restored):
        row=discard_expected[i];profile=row['profile'];original_bary=row['bary'];parts=restored.get(i,[])
        # A collapsed wall depth can have full original-source area but zero
        # displayed profile area. Only restored pieces require source-domain
        # partition coverage; an omitted profile is checked in the display/Z
        # domain, with reconstruction uncertainty reported explicitly.
        eu=polygons([original_bary])[0];part_polygons=polygons(parts);au=shapely.union_all(part_polygons);difference=float(eu.symmetric_difference(au).area) if parts else 0.
        extra_overlap=max(0.,float(shapely.area(part_polygons).sum()-au.area))
        max_extra_overlap=max(max_extra_overlap,extra_overlap)
        scale=max(1.,float(abs(profile).max()));coordinate_error=plane_error*(1+float(np.linalg.norm(matrix)))+64*np.finfo(float).eps*scale
        u,v=profile[1]-profile[0],profile[2]-profile[0]
        area_error=float(coordinate_error*(abs(u).sum()+abs(v).sum())+4*coordinate_error**2)
        uncertain=0<row['area']<=area_error
        restoration.append(dict(discardedIndex=int(i),compiledParts=len(parts),sourceBaryCoverageDifference=difference,extraSourceBaryOverlap=extra_overlap,independentProfileArea=row['area'],profileAreaUncertaintyBound=area_error,numericalPositiveArea=uncertain,omittedWithinArithmeticUncertainty=not parts and uncertain))
        max_difference=max(max_difference,difference)
        if difference>1e-9:failures.append(dict(discardedIndex=int(i),missingRestoredSourceBaryArea=difference))
        if extra_overlap>1e-9:failures.append(dict(discardedIndex=int(i),extraRestoredSourceBaryOverlap=extra_overlap))
        if not parts and row['area']>area_error:failures.append(dict(discardedIndex=int(i),missingPositiveProfileArea=row['area'],arithmeticUncertaintyBound=area_error))
    report=dict(scope=__doc__,compiledProfilesSha256=sha(compiled/'wall-profiles.json.gz'),oraclePackSha256=sha(oracle_path),fullSourcePackSha256=sha(full_path),sealedProvenanceSha256=sha(candidate/'normalized-face-provenance.npz'),verifierSha256=sha(Path(__file__)),originalParentPlaneErrorMeters=plane_error,oracleTriangles=len(oids),minimumBarycentric=minimum,maximumBarycentricSumError=sum_error,maximumOriginalZErrorMeters=z_error,maximumAuthoredNormalErrorSvg=max_normal,maximumAuthoredAlongErrorSvg=max_along,maskedTriangles=int(masked.sum()),maximumOriginalUvError=uv_error,materialsAndTextureBytesMatch=True,sourceCoverageGroups=len(set(expected)|set(actual)),maximumSourceBaryCoverageDifference=max_difference,maximumExtraSourceBaryOverlap=max_extra_overlap,maximumSourceBaryHausdorff=max_hausdorff,restoredCoverage=restoration,failures=failures,failureCount=len(failures),productionMutation=False,limitations=['Coverage comparisons use floating source barycentric tolerances; numerical-scale zero decisions are explicitly reported.','Original source Z and attributes are preserved under intentionally normalized wall XY.','This certifies reviewed source lineage and wall subset coverage, not floor selection or whole-scene visibility.'])
    report['maximumGeneratedFragmentBarycentricMatchError']=max_hausdorff
    report['generatedFragmentMatching']='One-to-one triangle-record matching; no polygon simplification or source-area substitution.'
    report['numericalDiscardProfiles']=sum(r['numericalPositiveArea'] for r in restoration)
    report['omittedNumericalDiscardProfiles']=sum(r['omittedWithinArithmeticUncertainty'] for r in restoration)
    report['literalDiscardZeroClassificationCertified']=report['omittedNumericalDiscardProfiles']==0
    report['limitations'].append('Discarded profiles below the reported reconstruction envelope remain numerically ambiguous; a passing tolerance gate does not certify their exact zero/nonzero classification.')
    output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:report[k] for k in ['oracleTriangles','maximumOriginalZErrorMeters','maximumAuthoredAlongErrorSvg','maximumOriginalUvError','sourceCoverageGroups','maximumSourceBaryCoverageDifference','maximumGeneratedFragmentBarycentricMatchError','omittedNumericalDiscardProfiles','failureCount']},indent=2));assert not failures,'Source-world oracle failed independent source verification; report preserved'
if __name__=='__main__':
    p=argparse.ArgumentParser();[p.add_argument(k,type=Path) for k in ['compiled','candidate','full','warp','output']];a=p.parse_args();verify(a.compiled,a.candidate,a.full,a.warp,a.output)
