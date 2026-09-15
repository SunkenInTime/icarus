"""Build bounded authored-wall candidates from exact reviewed source-face packets.

Only candidate packs are written. Corner ownership and provisional ground policy
remain outside this builder's acceptance scope.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
from types import SimpleNamespace
import numpy as np
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from tactical_pack_writer import write_pack
from authored_wall_profile_cells import wall_breakpoints,normalized_fragments,inverse_in_cell
from build_split_normalized_wall_families import cut

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
PILOTS={'ascent':[143,213],'icebox':[115]}

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def build(name,output=None,supplement=None):
    out=Path(output) if output else REV/f'{name}-reviewed-wall-candidate-v1'
    if out.exists():raise FileExistsError(out)
    source_path=REV/f'global-ground-complete-v2/{name}/{name}.height.bin.gz'
    header,arrays=pack(source_path);source=SimpleNamespace(header=header,raw=gzip.decompress(source_path.read_bytes()),arrays=arrays)
    c2f=np.load(source_path.parent/'correspondence.npz')['sourceFaces'];f2o=np.load(REV/f'full-height-input-v1/{name}/source-correspondence.npz')['sourceFaces'];c2o=f2o[c2f]
    folder=REV/f'{name}-wall-family-review-v1';review_path=folder/'reviewed-candidates.json';review=json.loads(review_path.read_text());review_summary=json.loads((folder/'summary.json').read_text())
    assert review_summary['controlPackSha256']==sha(source_path)
    warp_path=REV/f'display-warps-v1/{name}.display-warp.json.gz';w=json.loads(gzip.decompress(warp_path.read_bytes()));assert sha(warp_path)==review_summary['displayWarpSha256']
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix)
    extra=None
    if supplement:
        extra=json.loads(Path(supplement).read_text());assert extra['map']==name
        assert sha(REV/f'full-height-input-v1/{name}/{name}.height.bin.gz')==extra['fullHeightPackSha256']
        assert sha(warp_path)==extra['displayWarpSha256']
        for path_key in ['sourcePacket','proposal']:
            assert sha(extra[path_key])==extra[path_key+'Sha256']
    source_svg=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;target_svg=np.array(w['targetAttackSvg']).reshape(-1,2);wt=np.array(w['triangles']).reshape(-1,3)
    unwarp=explicit_warp(target_svg,source_svg-target_svg,wt);families=[];face_families={}
    for sid in PILOTS[name]:
        reviewed=next(r for r in review['candidates'] if r['span']==sid);packet_path=folder/reviewed['packetFile'];assert sha(packet_path)==reviewed['packetSha256'];packet=json.loads(packet_path.read_text())
        assert sha(folder/reviewed['sectionFile'])==reviewed['sectionSha256']
        span=packet['span'];target_line=np.array([span['startSvg'],span['endSvg']]);axis=int(np.argmax(abs(target_line[1]-target_line[0])));other=1-axis
        assert abs(target_line[1,other]-target_line[0,other])<1e-10,'Pilot helper accepts only axis-aligned authored spans'
        native_axis=np.array(packet['sourcePlane']['axisXY']);projected_axis=matrix@native_axis
        assert abs(projected_axis[other])<1e-7*abs(projected_axis[axis]),'Source wall frame is not axis-aligned'
        rows=[r for r in packet['originalSamples'] if r.get('relativeEyeHeightMeters')==1.75 and r.get('sourceObjectIndex')==packet['primaryInstanceIndex'] and r.get('probeStartInsideReceiver') and 2<=r['alongSvg']<=span['lengthSvg']-2]
        endpoints=[min(rows,key=lambda r:r['alongSvg']),max(rows,key=lambda r:r['alongSvg'])]
        source_pair=np.array([r['hitControlXYZ'][:2] for r in endpoints])@matrix.T+origin;target_pair=np.array([r['pointSvg'] for r in endpoints]);order=np.argsort(source_pair[:,axis]);source_pair=source_pair[order];target_pair=target_pair[order]
        source_along=source_pair[:,axis].tolist();target_along=target_pair[:,axis].tolist();assert target_along[1]>target_along[0]
        original_ids=np.array(reviewed['exactSourceFaceIds'],dtype=np.int64);control_ids=np.flatnonzero(np.isin(c2o,original_ids));assert set(control_ids)==set(reviewed['exactControlFaceIds'])
        extra_families=[] if extra is None else [row for row in extra['families'] if row['edge']==sid]
        for row in extra_families:
            added_ids=np.array(row['exactSourceFaceIds'],dtype=np.int64)
            assert len(added_ids)==len(set(added_ids));assert set(added_ids).issubset(set(c2o))
            original_ids=np.union1d(original_ids,added_ids)
        control_ids=np.flatnonzero(np.isin(c2o,original_ids))
        triangles=arrays['vertices'][arrays['faces'][control_ids]];projected=triangles[:,:,:2]@matrix.T+origin
        box=[0.,0.,0.,0.];box[axis],box[axis+2]=source_along;box[other]=float(projected[:,:,other].min()-1e-8);box[other+2]=float(projected[:,:,other].max()+1e-8)
        family=dict(edge=sid,legacyStraightEdgeIndex=span['legacyStraightEdgeIndex'],objects=[packet['primaryInstanceIndex']],sourceObjects=[dict(sourceObjectIndex=packet['primaryInstanceIndex'],**packet['primaryInstance'])],
            axis=axis,box=box,sourceAlong=source_along,targetAlong=target_along,fixed=float(target_line[0,other]),
            reviewedSourceFrame=packet['sourcePlane'],reviewedSourceFaceIds=original_ids.tolist(),eligibleControlFaceIds=control_ids.tolist(),
            packet=str(packet_path),packetSha256=sha(packet_path),sectionSha256=reviewed['sectionSha256'],
            boundedInteriorAlongSvg=[min(r['alongSvg'] for r in endpoints),max(r['alongSvg'] for r in endpoints)],
            controlFaces=[],originalSourceFaces=[],cornerStatus='Unresolved; at least two authored SVG units at both ends are outside this normalization.')
        for row in extra_families:
            family['objects'].append(row['sourceObjectIndex'])
            family['sourceObjects'].append({'sourceObjectIndex':row['sourceObjectIndex'],'path':row['sourceObjectPath'],'reviewSupplement':str(supplement)})
        family['reviewSupplement']=None if not extra_families else {'path':str(supplement),'sha256':sha(supplement),'exactSourceFaceIds':[face for row in extra_families for face in row['exactSourceFaceIds']]}
        family['displayWarpBreakpoints']=wall_breakpoints(unwarp,axis,family['fixed'],*target_along)
        for face in control_ids:face_families.setdefault(int(face),[]).append(family)
        families.append(family)
    additions=[];parents=[];newmasks=[];uvs=list(arrays['maskedUvs']);materials=list(arrays['maskedMaterials']);removed=[];bindings=[];bary_proof=[];warp_cells=[]
    discarded_parents=[];discarded_bary=[];discarded_edges=[];outside_count=0;verts=arrays['vertices'];faces=arrays['faces']
    def discard(data,parent,edge):
        for j in range(1,len(data)-1):
            discarded_parents.append(parent);discarded_bary.append(data[[0,j,j+1],3:]);discarded_edges.append(edge)
    for face_id,allowed in sorted(face_families.items()):
        xyz=verts[faces[face_id]];projected=xyz.copy();projected[:,:2]=projected[:,:2]@matrix.T+origin
        pieces=[list(np.column_stack((projected,np.eye(3))))];transformed=[];tiny=[]
        for family in allowed:
            remainder=[]
            for poly in pieces:
                a=np.array(poly);box=family['box']
                if np.any(a[:,:2].max(0)<box[:2]) or np.any(a[:,:2].min(0)>box[2:]):remainder.append(poly);continue
                inside,other=cut(poly,box);remainder.extend(other)
                if len(inside)<3:continue
                physical=np.array(inside)[:,:3].copy();physical[:,:2]=(physical[:,:2]-origin)@inverse.T
                area=sum(np.linalg.norm(np.cross(physical[j]-physical[0],physical[j+1]-physical[0])) for j in range(1,len(physical)-1))
                if area<1e-12:tiny.append((np.array(inside),family['edge']));continue
                transformed.append((inside,family));family['controlFaces'].append(face_id);family['originalSourceFaces'].append(int(c2o[face_id]))
            pieces=remainder
        if not transformed:continue
        removed.append(face_id);outside_count+=len(pieces)
        for data,edge in tiny:discard(data,face_id,edge)
        for poly,family in [(p,None) for p in pieces]+transformed:
            collapsed=[];fragments=[(np.array(poly),-1)] if family is None else normalized_fragments(np.array(poly),family,unwarp,discarded=collapsed)
            for data in collapsed:discard(data,face_id,family['edge'])
            for data,cell in fragments:
                weights=data[:,3:];newxyz=weights@xyz
                if family is not None:newxyz[:,:2]=(inverse_in_cell(data[:,:2],unwarp,cell)-origin)@inverse.T
                for j in range(1,len(data)-1):
                    idx=[0,j,j+1];tri=newxyz[idx];bary=weights[idx];edge=-1 if family is None else family['edge']
                    if np.linalg.norm(np.cross(tri[1]-tri[0],tri[2]-tri[0]))<1e-12:
                        discarded_parents.append(face_id);discarded_bary.append(bary);discarded_edges.append(edge);continue
                    additions.append(tri);parents.append(face_id);bindings.append(edge);bary_proof.append(bary);warp_cells.append(cell)
                    mask=int(arrays['faceMasks'][face_id])
                    if mask>=0:newmasks.append(len(uvs));uvs.append(bary@arrays['maskedUvs'][mask]);materials.append(arrays['maskedMaterials'][mask])
                    else:newmasks.append(-1)
    keep=np.ones(len(faces),bool);keep[removed]=False;old_ids=np.flatnonzero(keep);added=np.array(additions);newpoints=np.vstack((verts,added.reshape(-1,3)));newfaces=np.vstack((faces[keep],np.arange(len(verts),len(newpoints)).reshape(-1,3)))
    masks=np.r_[arrays['faceMasks'][keep],newmasks];correspondence=np.r_[old_ids,parents]
    for family in families:
        family['controlFaces']=sorted(set(family['controlFaces']));family['originalSourceFaces']=sorted(set(family['originalSourceFaces']))
    out.mkdir(parents=True);backup=out/f'{name}.source-backup.height.bin.gz';shutil.copyfile(source_path,backup);assert sha(backup)==sha(source_path)
    proof=dict(format='icarus-authored-wall-family-normalization-v1',map=name,physicalRayEquivalence=False,productionMutation=False,sourceBackup=str(backup),originalSourcePack=str(source_path),sourcePackSha256=sha(backup),displayWarpSha256=sha(warp_path),sourceGeometrySha256=header['sourceGeometrySha256'],
        reviewedCandidatesSha256=sha(review_path),builderSha256=sha(Path(__file__)),sharedProfileHelperSha256=sha(Path('scripts/authored_wall_profile_cells.py')),sharedCutHelperSha256=sha(Path('scripts/build_split_normalized_wall_families.py')),writerSha256=sha(Path('scripts/tactical_pack_writer.py')),
        families=families,removedControlFaces=removed,addedTriangles=len(added),unchangedOriginalFaces=len(old_ids),preservedOutsideFragments=outside_count,collapsedWallDepthTriangles=len(discarded_parents),
        displayWarpInteriorProof='Partition source clips/clamps and every target W cell boundary; sparse barycentric provenance preserves original Z and alpha.',
        cornerOwnership='Only exact reviewed source face IDs are eligible. Bounded interiors preserve all fragments outside the clip rectangle; both end regions remain unresolved.',
        heightPolicy='Retain original control Z and alpha profiles. No extrusion, height union, maximum-height fill or source object-name admission.',
        unresolved=['Bounded interiors only; normalization joins at the retained end regions require visual audit.','Provisional control ground policy is unchanged.','Actual original-world physical ray equivalence is intentionally not claimed.','Backings, standalone props and openings outside exact reviewed face IDs remain unchanged.'])
    print(name,'writing',len(removed),'replaced;',len(added),'generated;',len(discarded_parents),'discarded',flush=True)
    result=write_pack(source,backup,out,newpoints,newfaces,masks,np.array(uvs),np.array(materials),correspondence,header['tacticalGroundFieldSha256'],header['heightDomainMeters'],proof,
        header_overrides={'status':'experimental-authored-wall-normalization','referenceEquivalence':'Exact reviewed source wall profiles retain Z and alpha while bounded XY is intentionally mapped onto authored SVG interiors.','authoredWallNormalization':proof},
        fragment_proof={'inputFaceIds':np.arange(len(old_ids),len(newfaces)),'barycentrics':np.array(bary_proof),'edges':np.array(bindings),'warpCells':np.array(warp_cells),'discardedSourceFaces':np.array(discarded_parents),'discardedBarycentrics':np.array(discarded_bary).reshape(-1,3,3),'discardedEdges':np.array(discarded_edges)})
    (out/'bindings.json').write_text(json.dumps(proof,indent=2)+'\n');(out/'summary.json').write_text(json.dumps(result,indent=2)+'\n');print(name,result,flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('map',choices=PILOTS);parser.add_argument('--output');parser.add_argument('--supplement');args=parser.parse_args();build(args.map,args.output,args.supplement)
