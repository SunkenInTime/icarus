"""Bounded authored-wall candidate. Source height and alpha profiles stay separate."""
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import gzip
import numpy as np
from tactical_alignment_audit import pack
from tactical_pack_writer import write_pack
from tactical_alignment_composite import explicit_warp
from authored_wall_profile_cells import wall_breakpoints, normalized_fragments, inverse_in_cell
ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'

def split(poly,axis,value,sign):
    inside=[];outside=[]
    for a,b in zip(poly,poly[1:]+poly[:1]):
        av=(a[axis]-value)*sign;bv=(b[axis]-value)*sign
        (inside if av>=0 else outside).append(a)
        if (av>=0)!=(bv>=0):
            q=a+(b-a)*av/(av-bv);inside.append(q);outside.append(q)
    return inside,outside

def cut(poly,box):
    outside=[]
    for axis,value,sign in [(0,box[0],1),(0,box[2],-1),(1,box[1],1),(1,box[3],-1)]:
        if not poly:break
        poly,part=split(poly,axis,value,sign)
        if len(part)>=3:outside.append(part)
    return poly,outside

def main(out=None, extra_families=None, frozen_families=None):
    out=out or REV/'split-wall-family-normalized-candidate-v13'
    if out.exists():raise FileExistsError(out)
    source_path=REV/'global-ground-complete-v2/split/split.height.bin.gz'
    header,arrays=pack(source_path);rawbytes=gzip.decompress(source_path.read_bytes());source=SimpleNamespace(header=header,raw=rawbytes,arrays=arrays)
    meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text());starts=np.array([r['firstFace'] for r in meta['objects']])
    control_full=np.load(source_path.parent/'correspondence.npz')['sourceFaces'];full_original=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];original_ids=full_original[control_full];object_ids=np.searchsorted(starts,original_ids,side='right')-1
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix)
    source_svg=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;target_svg=np.array(w['targetAttackSvg']).reshape(-1,2);wt=np.array(w['triangles']).reshape(-1,3);unwarp=explicit_warp(target_svg,source_svg-target_svg,wt)
    # Explicit reviewed families, not regex classifications. Rectangles are in
    # original attack projection and preserve every fragment outside the bound.
    # Along coordinates map structural endpoints onto exact authored corners.
    families=[
      dict(edge=106,objects=[7898,7897,7874],box=[291.0197140465251,311.,365.3024992921133,314.5],axis=0,sourceAlong=[291.0197140465251,365.3024992921133],targetAlong=[292.365,363.603],fixed=310.928),
      dict(edge=105,objects=[7898,7700,4540,7864,7866],box=[285.,281.157,294.,312.1567706085799],axis=1,sourceAlong=[281.157,312.1567706085799],targetAlong=[281.157,310.928],fixed=292.365),
      dict(edge=107,objects=[7897,4882,4952,4948,7932,7869],box=[361.3,288.69899675301633,366.03504602,314.11152854755943],axis=1,sourceAlong=[288.69899675301633,314.11152854755943],targetAlong=[288.068,310.928],fixed=363.603,depthSourceFaces=list(range(2853783,2853791))),
      dict(edge=176,objects=[7790,7791,7792,4665,4666,7766],box=[212.82192456443596,181.5,257.2,185.1],axis=0,sourceAlong=[212.82192456443596,255.87976023835205],targetAlong=[212.62,256.214],fixed=182.274),
      dict(edge=175,objects=[7791,7792,4707,4708,4714,4715,4774,4775,4796],box=[255.83313156177286,181.5,257.2,196.87543997865373],axis=1,sourceAlong=[183.19176901236128,196.87543997865373],targetAlong=[182.274,196.096],fixed=256.214,depthSourceFaces=[2823708,2823709,2823718,2823719,2823720,2823721]),
      dict(edge=177,objects=[7790],box=[212.,183.19176901236128,213.1,194.8692659633886],axis=1,sourceAlong=[183.19176901236128,194.8692659633886],targetAlong=[182.274,194.501],fixed=212.62),
      dict(edge=15,objects=[7334,7330,7107,2985,2986],box=[243.2763786927137,83.46,315.0613344130065,86.47],axis=0,sourceAlong=[243.2763786927137,314.5970759536322],targetAlong=[243.987,315.225],fixed=83.9221,reviewedInteriorDepthWindows={7334:[245.61905769107693,294.19094130247896],7107:[294.185661740186,314.6]}),
      dict(edge=108,objects=[7897,7895,6163],box=[363.34172355,288.5,394.62465136274017,288.8],axis=0,sourceAlong=[363.3476891540715,394.62465136274017],targetAlong=[363.603,394.97],fixed=288.068),
      dict(edge=174,objects=[7795,7796,4773],box=[255.80903050904556,195.99,263.7171436931447,196.9],axis=0,sourceAlong=[255.83313156177286,263.65378894562883],targetAlong=[256.214,263.657],fixed=196.096,reviewedInteriorDepthWindows={7795:[255.83313256177286,263.65378794562883]}),
      dict(edge=16,objects=[7107],box=[313.,58.50,315.40,85.88],axis=1,sourceAlong=[59.30093385631051,85.41320153690589],targetAlong=[56.809,83.9221],fixed=315.225,reviewedInteriorDepthAxis=1,reviewedInteriorDepthWindows={7107:[59.33,85.316]},depthSourceFaces=list(range(2492193,2492201))),
      dict(edge=17,objects=[7107,429,5857],box=[315.3810760401235,56.42,408.30832232903276,58.98],axis=0,sourceAlong=[316.1939347510129,408.30832232903276],targetAlong=[315.225,409.855],fixed=56.809,reviewedInteriorDepthWindows={7107:[316.16491207241916,345.8868493035712],5857:[345.7543989116954,408.30832132903276]},depthSourceFaces=[2492113,2492114]),
    ]
    if frozen_families is not None:
        from copy import deepcopy
        assert not extra_families, 'Frozen cumulative declarations already contain every family'
        families=deepcopy(frozen_families)
        assert len({f['edge'] for f in families})==len(families), 'Duplicate frozen family identity'
    else:families.extend(extra_families or [])
    raw_geometry=np.load(ROOT/'supplemented-v2/world/split/geometry.npz');raw_points,raw_faces=raw_geometry['points'],raw_geometry['faces']
    for family in families:
        if frozen_families is not None:continue  # Exact reviewed depth IDs are already sealed.
        for obj,interval in family.get('reviewedInteriorDepthWindows',{}).items():
            item=meta['objects'][obj];ids=np.arange(item['firstFace'],item['firstFace']+item['faceCount']);tri=raw_points[raw_faces[ids]].copy();tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin
            depth_axis=family.get('reviewedInteriorDepthAxis',0)
            admitted=(tri[:,:,depth_axis].min(1)>=interval[0])&(tri[:,:,depth_axis].max(1)<=interval[1])
            family.setdefault('depthSourceFaces',[]).extend(ids[admitted].tolist())
    for family in families:
        if family.get('mappingType')=='piecewise-affine-region-v1':
            pass
        elif 'targetFrame' in family:
            from authored_wall_profile_cells import frame_wall_breakpoints
            family['displayWarpBreakpoints']=frame_wall_breakpoints(unwarp,family['targetFrame'],*family['targetAlong'])
        else:
            family['displayWarpBreakpoints']=wall_breakpoints(unwarp,family['axis'],family['fixed'],*family['targetAlong'])
        family['sourceObjects']=[dict(sourceObjectIndex=i,**meta['objects'][i]) for i in family['objects']]
        family['controlFaces']=[];family['originalSourceFaces']=[]
    from region_partition_certificate import SourceCellCertificate
    containment_certifiers={id(f):SourceCellCertificate(f) for f in families if f.get('sourceContainmentArithmeticPolicy')}
    object_set={i for r in families for i in r['objects']};candidate_ids=np.flatnonzero(np.isin(object_ids,list(object_set)))
    additions=[];parents=[];newmasks=[];uvs=list(arrays['maskedUvs']);materials=list(arrays['maskedMaterials']);removed=[];bindings=[];bary_proof=[];warp_cells=[];discarded=0;outside_count=0
    discarded_parents=[];discarded_bary=[];discarded_edges=[];region_cells=[];discarded_region_cells=[]
    verts=arrays['vertices'];faces=arrays['faces']
    main_shells={7897,7898,7790,7791,7792,7334,7107,7795,7796,5857}
    for face_id in candidate_ids:
        xyz=verts[faces[face_id]];projected=xyz.copy();projected[:,:2]=projected[:,:2]@matrix.T+origin
        pieces=[list(np.column_stack((projected,np.eye(3))))];transformed=[];tiny_clipped=[]
        obj=int(object_ids[face_id])
        normal=np.cross(projected[1]-projected[0],projected[2]-projected[0])
        tangent_axis=int(np.argmin(abs(normal[:2]))) if np.linalg.norm(normal[:2])>1e-12 else None
        for family in families:
            if obj not in family['objects']:continue
            if 'reviewedSourceFaces' in family and int(original_ids[face_id]) not in family['reviewedSourceFaces']:continue
            # A shared room object contains both meeting walls. The actual
            # sheet orientation determines ownership before any spatial cut.
            # Otherwise a horizontal span steals and collapses its vertical
            # neighbor, introducing an artificial corner opening.
            explicit_depth=int(original_ids[face_id]) in family.get('depthSourceFaces',[])
            if obj in main_shells and tangent_axis!=family.get('axis') and not explicit_depth:continue
            remainder=[]
            for poly in pieces:
                a=np.array(poly);box=family['box']
                if np.any(a[:,:2].max(axis=0)<box[:2]) or np.any(a[:,:2].min(axis=0)>box[2:]):remainder.append(poly);continue
                inside,other=cut(poly,box);remainder.extend(other)
                if len(inside)<3:continue
                # Degenerate pieces created only on a clip boundary do not
                # count as a semantic source-face replacement.
                physical=np.array(inside)[:,:3].copy();physical[:,:2]=(physical[:,:2]-origin)@inverse.T
                area=sum(np.linalg.norm(np.cross(physical[i]-physical[0],physical[i+1]-physical[0])) for i in range(1,len(physical)-1))
                if area<1e-12 and family.get('mappingType')!='piecewise-affine-region-v1':
                    tiny_clipped.append((np.array(inside),family['edge']));continue
                transformed.append((inside,family));family['controlFaces'].append(int(face_id));family['originalSourceFaces'].append(int(original_ids[face_id]))
            pieces=remainder
        if not transformed:continue
        removed.append(int(face_id));outside_count+=len(pieces)
        for data,edge in tiny_clipped:
            for j in range(1,len(data)-1):
                discarded_parents.append(int(face_id));discarded_bary.append(data[[0,j,j+1],3:]);discarded_edges.append(edge);discarded_region_cells.append(-1)
        for poly,family in [(p,None) for p in pieces]+transformed:
            collapsed=[]
            if family is not None and family.get('mappingType')=='piecewise-affine-region-v1':
                if family.get('sourcePartitionMethod')=='finite-convex-cells-v1':
                    from finite_region_cells import region_fragments
                else:
                    assert family.get('sourcePartitionMethod') is None, 'Unknown source partition method'
                    from authored_region_cells import region_fragments
                certifier=containment_certifiers.get(id(family))
                certificate=None if certifier is None else certifier.callback(xyz,matrix,origin,face_id)
                source_construction=None
                construction_policy=family.get('sourceCoordinateConstruction')
                if construction_policy is not None:
                    assert construction_policy=='original-native-triangle-v1', 'Unknown source coordinate construction'
                    assert family.get('sourcePartitionMethod')=='finite-convex-cells-v1', 'Exact native construction requires finite cells'
                    from native_region_source import native_source_rows
                    source_construction=native_source_rows(xyz,matrix,origin)
                arguments=dict(containment_certificate=certificate)
                if source_construction is not None:arguments['source_construction']=source_construction
                fragments=region_fragments(np.array(poly),family,unwarp,**arguments)
            else:
                fragments=[(data,cell,-1) for data,cell in ([(np.array(poly),-1)] if family is None else normalized_fragments(np.array(poly),family,unwarp,discarded=collapsed))]
            for data in collapsed:
                for j in range(1,len(data)-1):
                    discarded_parents.append(int(face_id));discarded_bary.append(data[[0,j,j+1],3:]);discarded_edges.append(family['edge']);discarded_region_cells.append(-1);discarded+=1
            for data,cell,region_cell in fragments:
                weights=data[:,3:];newxyz=weights@xyz
                if family is not None:
                    newxyz[:,:2]=(inverse_in_cell(data[:,:2],unwarp,cell)-origin)@inverse.T
                for j in range(1,len(data)-1):
                    tri=newxyz[[0,j,j+1]];bary=weights[[0,j,j+1]]
                    if np.linalg.norm(np.cross(tri[1]-tri[0],tri[2]-tri[0]))<1e-12:
                        discarded+=1;discarded_parents.append(int(face_id));discarded_bary.append(bary);discarded_edges.append(-1 if family is None else family['edge']);discarded_region_cells.append(region_cell);continue
                    additions.append(tri);parents.append(int(face_id));bindings.append(-1 if family is None else family['edge']);bary_proof.append(bary);warp_cells.append(cell);region_cells.append(region_cell)
                    mask=int(arrays['faceMasks'][face_id])
                    if mask>=0:
                        newmasks.append(len(uvs));uvs.append(bary@arrays['maskedUvs'][mask]);materials.append(arrays['maskedMaterials'][mask])
                    else:newmasks.append(-1)
    from normalization_checkpoint import save_checkpoint
    generated=dict(additions=np.asarray(additions,dtype=float).reshape(-1,3,3),parents=np.asarray(parents,dtype=np.int64),newmasks=np.asarray(newmasks,dtype=np.int64),uvs=np.asarray(uvs),materials=np.asarray(materials),removed=np.asarray(removed,dtype=np.int64),bindings=np.asarray(bindings,dtype=np.int64),bary_proof=np.asarray(bary_proof,dtype=float).reshape(-1,3,3),warp_cells=np.asarray(warp_cells,dtype=np.int64),discarded_parents=np.asarray(discarded_parents,dtype=np.int64),discarded_bary=np.asarray(discarded_bary,dtype=float).reshape(-1,3,3),discarded_edges=np.asarray(discarded_edges,dtype=np.int64),region_cells=np.asarray(region_cells,dtype=np.int64),discarded_region_cells=np.asarray(discarded_region_cells,dtype=np.int64))
    counts=dict(discarded=discarded,outside_count=outside_count)
    certificates=[dict(**c.proof,records=c.records) for c in containment_certifiers.values()]
    checkpoint_binding=save_checkpoint(out,source_path,wp,families,generated,counts,certificates)
    print('saved complete geometry checkpoint',checkpoint_binding['metadataFile'],flush=True)
    finish_candidate(source,source_path,wp,out,families,generated,counts,certificates,checkpoint_binding)


def finish_candidate(source,source_path,wp,out,families,generated,counts,certificates,checkpoint_binding):
    arrays=source.arrays;header=source.header;verts=arrays['vertices'];faces=arrays['faces']
    additions=generated['additions'];parents=generated['parents'].tolist();newmasks=generated['newmasks'];uvs=generated['uvs'];materials=generated['materials'];removed=generated['removed'].tolist()
    bindings=generated['bindings'];bary_proof=list(generated['bary_proof']);warp_cells=generated['warp_cells'];discarded_parents=generated['discarded_parents'].tolist();discarded_bary=list(generated['discarded_bary']);discarded_edges=generated['discarded_edges'];region_cells=generated['region_cells'];discarded_region_cells=generated['discarded_region_cells']
    discarded=counts['discarded'];outside_count=counts['outside_count']
    # A collapsed XY polygon can still cover positive source area. Verify its
    # discarded pieces together with visible pieces before packing either.
    from verify_normalized_wall_profiles import verify_source_partition
    preflight_path=out.with_name(out.name+'-partition-preflight.npz')
    preflight_parents=np.asarray(parents+discarded_parents,dtype=np.int64)
    preflight_bary=np.asarray(bary_proof+discarded_bary,dtype=float).reshape(-1,3,3)
    if preflight_path.exists():
        previous=np.load(preflight_path,allow_pickle=False)
        assert np.array_equal(previous['parents'],preflight_parents) and np.array_equal(previous['barycentrics'],preflight_bary) and np.array_equal(previous['removed'],np.asarray(removed,dtype=np.int64)), 'Existing preflight differs from immutable geometry checkpoint'
    else:
        np.savez_compressed(preflight_path,parents=preflight_parents,barycentrics=preflight_bary,
                            removed=np.asarray(removed,dtype=np.int64))
    print('saved source partition replay',preflight_path,flush=True)
    partition_before_write=verify_source_partition(
        preflight_parents,preflight_bary,removed)
    keep=np.ones(len(faces),bool);keep[removed]=False;old_ids=np.flatnonzero(keep)
    added=np.array(additions);newpoints=np.vstack((verts,added.reshape(-1,3)));newfaces=np.vstack((faces[keep],np.arange(len(verts),len(newpoints)).reshape(-1,3)));masks=np.r_[arrays['faceMasks'][keep],newmasks];correspondence=np.r_[old_ids,parents]
    for r in families:
        r['controlFaces']=sorted(set(r['controlFaces']));r['originalSourceFaces']=sorted(set(r['originalSourceFaces']))
    proof=dict(format='icarus-authored-wall-family-normalization-v1',physicalRayEquivalence=False,productionMutation=False,sourceBackup=str(source_path),sourcePackSha256=hashlib.sha256(source_path.read_bytes()).hexdigest(),displayWarpSha256=hashlib.sha256(wp.read_bytes()).hexdigest(),sourceGeometrySha256=header['sourceGeometrySha256'],families=families,removedControlFaces=removed,addedTriangles=len(added),unchangedOriginalFaces=len(old_ids),preservedOutsideFragments=outside_count,collapsedWallDepthTriangles=discarded,displayWarpInteriorProof='Every normalized profile is split at sourceAlong clamp endpoints and all intersecting target W cell boundaries. Sparse generatedWarpCells records the affine target cell of each output triangle. Original source barycentrics carry Z and alpha through both partitions.',cornerOwnership='Shared primary wall shells choose authored-axis ownership from control-pack sheet orientation before spatial clipping, with exact reviewed raw-source depth-face overrides. Raw horizontal wall caps remain included under that control-sheet assignment; this is not a game walkability classification. Along values clamp to the canonical endpoints.',heightPolicy='Retain each original control face Z and barycentric alpha profile; normalize only reviewed wall-family XY. No maximum-height extrusion and no generic dilation.',unresolved=['Finite reviewed spatial bound only. Unbound standalone objects and genuine openings stay unchanged.','Control relative-floor semantics remain provisional.','Source/art topology differs at corners; candidate requires full contact/opening ray and rendered review.'])
    proof['sourceContainmentArithmeticCertificates']=certificates
    proof['sourceContainmentCertificateModuleSha256']=hashlib.sha256(Path(__file__).with_name('region_partition_certificate.py').read_bytes()).hexdigest()
    proof['nativeSourceConstructionModuleSha256']=hashlib.sha256(Path(__file__).with_name('native_region_source.py').read_bytes()).hexdigest()
    proof['prepackGeometryCheckpoint']=checkpoint_binding
    proof['sourcePartitionBeforeWrite']=partition_before_write
    proof['sourcePartitionPreflightSha256']=hashlib.sha256(preflight_path.read_bytes()).hexdigest()
    proof['sourcePartitionVerifierSha256']=hashlib.sha256(Path(__file__).with_name('verify_normalized_wall_profiles.py').read_bytes()).hexdigest()
    proof['exactPartitionVerifierSha256']=hashlib.sha256(Path(__file__).with_name('exact_source_partition.py').read_bytes()).hexdigest()
    print('writing',len(removed),'replaced faces;',len(additions),'fragments',flush=True)
    result=write_pack(source,source_path,out,newpoints,newfaces,masks,np.array(uvs),np.array(materials),correspondence,header['tacticalGroundFieldSha256'],header['heightDomainMeters'],proof,header_overrides={'status':'experimental-authored-wall-normalization','referenceEquivalence':'Reviewed source wall families retain height/alpha profiles while XY is intentionally normalized to authored SVG spans. Physical original-ray equivalence is not claimed.','authoredWallNormalization':proof},fragment_proof={'inputFaceIds':np.arange(len(old_ids),len(newfaces)),'barycentrics':np.array(bary_proof),'edges':np.array(bindings),'warpCells':np.array(warp_cells),'regionCells':np.array(region_cells),'discardedRegionCells':np.array(discarded_region_cells),'discardedSourceFaces':np.array(discarded_parents),'discardedBarycentrics':np.array(discarded_bary).reshape(-1,3,3),'discardedEdges':np.array(discarded_edges)})
    (out/'bindings.json').write_text(json.dumps(proof,indent=2));(out/'summary.json').write_text(json.dumps(result,indent=2));print(result)


def resume_checkpoint(metadata_path):
    from normalization_checkpoint import load_checkpoint
    metadata,generated,binding=load_checkpoint(metadata_path)
    source_path=Path(metadata['sourcePack']);wp=Path(metadata['displayWarp']);out=Path(metadata['candidateOutput'])
    if out.exists():raise FileExistsError(out)
    header,arrays=pack(source_path);source=SimpleNamespace(header=header,raw=gzip.decompress(source_path.read_bytes()),arrays=arrays)
    finish_candidate(source,source_path,wp,out,metadata['families'],generated,metadata['counts'],metadata['sourceContainmentArithmeticCertificates'],binding)


if __name__=='__main__':main()
