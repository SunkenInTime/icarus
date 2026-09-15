"""Compile source-world-Z reviewed wall profiles and a matching 3D subset oracle.

All positive-area discarded profiles are restored, including numerical-scale
slivers. Authored normalized XY remains intentional; this is not the unmodified
whole game scene and does not change floor selection.
"""
import argparse,gzip,json
from pathlib import Path
from types import SimpleNamespace
import numpy as np
import shapely
from native_compact_wall_profiles import sha
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from authored_wall_profile_cells import frame_wall_breakpoints,partition_linear
from verify_normalized_wall_profiles import profile_frame
from lift_reviewed_wall_source_heights import area
from tactical_pack_writer import write_pack

def compile_world(lifted,candidate,warp_path,output):
    if output.exists():raise FileExistsError(output)
    lift_report=json.loads((lifted/'report.json').read_text());lift_path=lifted/'source-world-fragments.npz';assert sha(lift_path)==lift_report['dataSha256'];a=np.load(lift_path)
    bindings=json.loads((candidate/'bindings.json').read_text());warp=json.loads(gzip.decompress(warp_path.read_bytes()));assert sha(warp_path)==lift_report['displayWarpSha256'];pack_path=candidate/f'{warp["map"]}.height.bin.gz';assert sha(pack_path)==lift_report['candidatePackSha256'];header,scene=pack(pack_path)
    matrix=np.column_stack((warp['projection']['axisU'],warp['projection']['axisV']));origin=np.array(warp['projection']['origin']);inverse=np.linalg.inv(matrix)
    source_svg=np.array(warp['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;target_svg=np.array(warp['targetAttackSvg']).reshape(-1,2);wt=np.array(warp['triangles']).reshape(-1,3)
    backward=explicit_warp(target_svg,source_svg-target_svg,wt);forward=explicit_warp(source_svg,target_svg-source_svg,wt)
    if any(f.get('mappingType')=='piecewise-affine-region-v1' for f in bindings['families']):
        raise ValueError('Connected regions require a 3D fragment compiler; this compiler only accepts individual wall lines')
    records=[];family_data=[];restoration=[]
    for family in bindings['families']:
        edge=family['edge'];o,t,n=profile_frame(family,'target');frame=dict(origin=o.tolist(),tangent=t.tolist(),normal=n.tolist());breaks=frame_wall_breakpoints(backward,frame,*family['targetAlong'])
        for i in np.flatnonzero(a['edges']==edge):
            triangle=a['triangles'][i];displayed=forward.apply(triangle[:,:2]@matrix.T+origin);profile=np.column_stack(((displayed-o)@t,triangle[:,2]));mask=int(a['faceMasks'][i])
            records.append(dict(edge=edge,triangle=triangle,profile=profile,uv=None if mask<0 else a['maskedUvs'][mask],material=-1 if mask<0 else int(a['maskedMaterials'][mask]),fullParent=int(a['fullSourceParents'][i]),bary=a['sourceBarycentrics'][i],restored=-1))
        restored_count=0;restored_area=0.;positive=0
        for i in np.flatnonzero(a['discardedEdges']==edge):
            profile=a['discardedAbsoluteProfiles'][i];value=area(profile[None])[0]
            if value==0:continue
            assert np.isfinite(profile).all() and value>0
            assert shapely.Polygon(profile).is_valid,'Unrepresentable restored profile: keep explicit before compilation'
            positive+=1;restored_area+=value
            # Split source-height profile at exact inverse-W cells before making 3D triangles.
            for part in partition_linear(np.column_stack((profile,np.eye(3))),np.zeros(2),np.array([1.,0.]),breaks):
                for j in range(1,len(part)-1):
                    row=part[[0,j,j+1]];weights=row[:,2:];p=row[:,:2];xy=(backward.apply(o+p[:,:1]*t)-origin)@inverse.T;triangle=np.column_stack((xy,p[:,1]));mask=int(a['discardedFaceMasks'][i])
                    records.append(dict(edge=edge,triangle=triangle,profile=p,uv=None if mask<0 else weights@a['discardedMaskedUvs'][i],material=-1 if mask<0 else int(a['discardedMaskedMaterials'][i]),fullParent=int(a['discardedFullSourceParents'][i]),bary=weights@a['discardedSourceBarycentrics'][i],restored=int(i)));restored_count+=1
        restoration.append(dict(edge=edge,positiveDiscardedProfiles=positive,restoredTriangles=restored_count,totalRestoredAreaSvgMeters=restored_area))
        family_data.append(dict(edge=edge,targetFrame=frame,targetAlong=family['targetAlong']))
    triangles=np.array([r['triangle'] for r in records]);uvs=[];materials=[];masks=[]
    for r in records:
        if r['uv'] is None:masks.append(-1)
        else:masks.append(len(uvs));uvs.append(r['uv']);materials.append(r['material'])
    output.mkdir(parents=True);oracle=output/'oracle';source=SimpleNamespace(header=header,raw=gzip.decompress(pack_path.read_bytes()));proof=dict(scope=__doc__,liftDataSha256=sha(lift_path),fullSourcePackSha256=lift_report['fullSourcePackSha256'],productionMutation=False)
    write_pack(source,pack_path,oracle,triangles.reshape(-1,3),np.arange(len(triangles)*3).reshape(-1,3),np.array(masks),np.array(uvs).reshape(-1,3,2),np.array(materials),np.arange(len(records)),header['tacticalGroundFieldSha256'],[float(triangles[:,:,2].min()),float(triangles[:,:,2].max())],proof,
        header_overrides={'status':'experimental-source-world-reviewed-wall-subset','coordinatePolicy':'authored-normalized-XY-original-source-Z','referenceEquivalence':'Original source Z reconstructed through sealed barycentric provenance; normalized authored wall XY intentionally retained. Only reviewed wall families are included.'},
        fragment_proof={'inputFaceIds':np.arange(len(records)),'barycentrics':np.array([r['bary'] for r in records]),'edges':np.array([r['edge'] for r in records]),'warpCells':np.full(len(records),-1),'discardedSourceFaces':np.empty(0,np.int64),'discardedBarycentrics':np.empty((0,3,3)),'discardedEdges':np.empty(0,np.int64)})
    oracle_pack=oracle/f'{warp["map"]}.height.bin.gz';order=np.load(oracle/'correspondence.npz')['sourceFaces'];inverse_order=np.empty(len(order),int);inverse_order[order]=np.arange(len(order));compiled=[];counts=[]
    for f in family_data:
        selected=[(i,r) for i,r in enumerate(records) if r['edge']==f['edge']];opaque=[r['profile'] for _,r in selected if r['material']<0 and area(r['profile'][None])[0]>0]
        geometries=shapely.polygons(np.array(opaque));assert shapely.is_valid(geometries).all();region=shapely.union_all(geometries);assert region.is_valid
        masked=[dict(profile=r['profile'].tolist(),uv=r['uv'].tolist(),material=r['material'],candidateFace=int(inverse_order[i]),fullSourceParent=r['fullParent']) for i,r in selected if r['material']>=0]
        compiled.append(dict(**f,opaqueRegion=json.loads(shapely.to_geojson(region)),maskedProfiles=masked));counts.append(dict(edge=f['edge'],oracleTriangles=len(selected),opaqueRegionCoordinates=int(shapely.get_num_coordinates(region)),maskedProfiles=len(masked),zeroAreaOpaqueTriangles=int(sum(r['material']<0 and area(r['profile'][None])[0]==0 for _,r in selected))))
    data=dict(format='icarus-reviewed-wall-profiles-v1',version=1,map=warp['map'],candidatePackSha256=sha(oracle_pack),bindingsSha256=sha(candidate/'bindings.json'),displayWarpSha256=sha(warp_path),coordinatePolicy='Authored SVG along distance; original source absolute world Z meters',heightPolicy='Original world Z only; observer floor selection not applied or changed',alphaPolicy='Exact UV/material references retained; oracle contains original source textures',liftDataSha256=sha(lift_path),families=compiled)
    raw=json.dumps(data,separators=(',',':')).encode();(output/'wall-profiles.json.gz').write_bytes(gzip.compress(raw,mtime=0));np.savez_compressed(output/'source-correspondence.npz',oracleFaceIds=inverse_order,fullSourceParents=np.array([r['fullParent'] for r in records]),sourceBarycentrics=np.array([r['bary'] for r in records]),restoredDiscardIds=np.array([r['restored'] for r in records]))
    report=dict(scope=__doc__,compilerSha256=sha(Path(__file__)),liftDataSha256=sha(lift_path),profileSha256=sha(output/'wall-profiles.json.gz'),oraclePackSha256=sha(oracle_pack),profileCompressedBytes=(output/'wall-profiles.json.gz').stat().st_size,oracleTriangles=len(records),families=counts,restoration=restoration,productionMutation=False,floorPolicyChanged=False,limitations=['Reviewed normalized wall XY only; other source scene geometry is absent from the subset oracle.','Exact zero-area absolute profiles remain in the 3D oracle/provenance but have no polygon area.','Numerical-edge behavior and masked coverage require separate query verification.'])
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser();[p.add_argument(k,type=Path) for k in ['lifted','candidate','warp','output']];a=p.parse_args();compile_world(a.lifted,a.candidate,a.warp,a.output)
