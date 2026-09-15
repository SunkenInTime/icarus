"""Diagnostic map-independent finite wall writer with source partition proof."""
import argparse,gzip,json,shutil
from pathlib import Path
from types import SimpleNamespace
import numpy as np
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from tactical_pack_writer import write_pack
from authored_wall_profile_cells import frame_wall_breakpoints,normalized_fragments,inverse_in_cell
from authored_region_cells import region_fragments
from build_split_normalized_wall_families import cut
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,REV


def cut_along(poly,frame,lo,hi):
    remaining=list(poly);outside=[];o=np.array(frame['origin']);t=np.array(frame['tangent'])
    for threshold,sign in [(lo,1),(hi,-1)]:
        inside=[];other=[]
        for a,b in zip(remaining,remaining[1:]+remaining[:1]):
            av=float(((a[:2]-o)@t-threshold)*sign);bv=float(((b[:2]-o)@t-threshold)*sign)
            (inside if av>=0 else other).append(a)
            if (av>=0)!=(bv>=0):
                p=a+(b-a)*av/(av-bv);inside.append(p);other.append(p)
        if len(other)>=3:outside.append(other)
        remaining=inside
        if not remaining:break
    return remaining,outside


def build(declaration_path,out):
    region_helper=Path(__file__).with_name('authored_region_cells.py')
    region_helper_hash=sha(region_helper)
    declaration_path,out=Path(declaration_path),Path(out)
    if out.exists():raise FileExistsError(out)
    declarations=json.loads(declaration_path.read_text());name=declarations['map']
    raw_path=ROOT/f'supplemented-v2/world/{name}/geometry.npz';assert sha(raw_path)==declarations['sourceFileSha256']
    source_path=REV/f'global-ground-complete-v2/{name}/{name}.height.bin.gz';header,arrays=pack(source_path);source=SimpleNamespace(header=header,raw=gzip.decompress(source_path.read_bytes()),arrays=arrays)
    c2f=np.load(source_path.parent/'correspondence.npz')['sourceFaces'];f2o=np.load(REV/f'full-height-input-v1/{name}/source-correspondence.npz')['sourceFaces'];c2o=f2o[c2f]
    warp_path=REV/f'display-warps-v1/{name}.display-warp.json.gz';w=json.loads(gzip.decompress(warp_path.read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix);sxy=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;txy=np.array(w['targetAttackSvg']).reshape(-1,2);unwarp=explicit_warp(txy,sxy-txy,np.array(w['triangles']).reshape(-1,3))
    families=declarations['families'];face_families={}
    for family in families:
        if family.get('mappingType')!='piecewise-affine-region-v1':family['displayWarpBreakpoints']=frame_wall_breakpoints(unwarp,family['targetFrame'],*family['targetAlong'])
        family['controlFaces']=[];family['originalSourceFaces']=[]
        control_ids=np.flatnonzero(np.isin(c2o,family['reviewedSourceFaceIds']));family['eligibleControlFaceIds']=control_ids.tolist()
        for fid in control_ids:face_families.setdefault(int(fid),[]).append(family)
    vertices,faces=arrays['vertices'],arrays['faces'];additions=[];parents=[];newmasks=[];uvs=list(arrays['maskedUvs']);materials=list(arrays['maskedMaterials']);removed=[];edges=[];barys=[];cells=[];region_cells=[];discarded_parents=[];discarded_bary=[];discarded_edges=[];discarded_region=[];outside_count=0
    def discard(data,parent,edge):
        for j in range(1,len(data)-1):discarded_parents.append(parent);discarded_bary.append(data[[0,j,j+1],3:]);discarded_edges.append(edge);discarded_region.append(-1)
    for fid,allowed in sorted(face_families.items()):
        xyz=vertices[faces[fid]];svg=xyz.copy();svg[:,:2]=svg[:,:2]@matrix.T+origin;pieces=[list(np.column_stack((svg,np.eye(3))))];transformed=[]
        for family in allowed:
            rest=[]
            for poly in pieces:
                if family.get('mappingType')=='piecewise-affine-region-v1':inside,other=cut(poly,family['box'])
                else:inside,other=(poly,[]) if family['clipPolicy']=='whole-reviewed-square-column' else cut_along(poly,family['sourceFrame'],*family['sourceAlong'])
                rest.extend(other)
                if len(inside)>=3:
                    transformed.append((inside,family));family['controlFaces'].append(fid);family['originalSourceFaces'].append(int(c2o[fid]))
            pieces=rest
        if not transformed:continue
        removed.append(fid);outside_count+=len(pieces)
        for poly,family in [(p,None) for p in pieces]+transformed:
            collapsed=[]
            if family is not None and family.get('mappingType')=='piecewise-affine-region-v1':
                try:fragments=region_fragments(np.array(poly),family,unwarp)
                except ValueError:
                    diagnostic=out.with_name(out.name+'-failed-partition.json')
                    diagnostic.write_text(json.dumps(dict(controlFace=fid,originalSourceFace=int(c2o[fid]),polygon=np.asarray(poly).tolist(),familyEdge=family['edge'],declaration=str(declaration_path)),indent=2)+'\n')
                    raise
            else:fragments=[(data,cell,-1) for data,cell in ([(np.array(poly),-1)] if family is None else normalized_fragments(np.array(poly),family,unwarp,discarded=collapsed))]
            for data in collapsed:discard(data,fid,family['edge'])
            for data,cell,region_cell in fragments:
                weights=data[:,3:];newxyz=xyz[0]+weights[:,1:]@(xyz[1:]-xyz[0])
                if family is not None:newxyz[:,:2]=(inverse_in_cell(data[:,:2],unwarp,cell)-origin)@inverse.T
                for j in range(1,len(data)-1):
                    idx=[0,j,j+1];tri=newxyz[idx];bary=weights[idx];edge=-1 if family is None else family['edge']
                    if np.linalg.norm(np.cross(tri[1]-tri[0],tri[2]-tri[0]))<1e-12:
                        discarded_parents.append(fid);discarded_bary.append(bary);discarded_edges.append(edge);discarded_region.append(region_cell);continue
                    additions.append(tri);parents.append(fid);edges.append(edge);barys.append(bary);cells.append(cell);region_cells.append(region_cell);mask=int(arrays['faceMasks'][fid])
                    if mask>=0:newmasks.append(len(uvs));uvs.append(bary@arrays['maskedUvs'][mask]);materials.append(arrays['maskedMaterials'][mask])
                    else:newmasks.append(-1)
    keep=np.ones(len(faces),bool);keep[removed]=False;old=np.flatnonzero(keep);added=np.array(additions);newpoints=np.vstack((vertices,added.reshape(-1,3)));newfaces=np.vstack((faces[keep],np.arange(len(vertices),len(newpoints)).reshape(-1,3)));masks=np.r_[arrays['faceMasks'][keep],newmasks];correspondence=np.r_[old,parents]
    for family in families:
        family['controlFaces']=sorted(set(family['controlFaces']));family['originalSourceFaces']=sorted(set(family['originalSourceFaces']))
    out.mkdir(parents=True);backup=out/f'{name}.source-backup.height.bin.gz';shutil.copyfile(source_path,backup);assert sha(backup)==sha(source_path)
    proof=dict(format='icarus-authored-wall-family-normalization-v1',map=name,physicalRayEquivalence=False,productionMutation=False,sourceBackup=str(backup),originalSourcePack=str(source_path),sourcePackSha256=sha(backup),displayWarpSha256=sha(warp_path),sourceGeometrySha256=header['sourceGeometrySha256'],sourceDeclaration=str(declaration_path),sourceDeclarationSha256=sha(declaration_path),builderSha256=sha(Path(__file__)),sharedProfileHelperSha256=sha(Path('scripts/authored_wall_profile_cells.py')),writerSha256=sha(Path('scripts/tactical_pack_writer.py')),families=families,removedControlFaces=removed,addedTriangles=len(added),unchangedOriginalFaces=len(old),preservedOutsideFragments=outside_count,collapsedWallDepthTriangles=len(discarded_parents),unresolved=['Diagnostic closed-component candidate; exact source attachments and all rendered corners require independent audit.','Original source standing floor policy is not changed; control-relative Z remains provisional.'],cornerOwnership=declarations.get('scope'),pendingExactAttachments=declarations.get('pendingExactAttachments',[]))
    assert sha(region_helper)==region_helper_hash,'Shared region helper changed during the bake'
    proof['sharedRegionHelperSha256']=region_helper_hash
    print(name,'writing',len(removed),'replaced;',len(added),'generated;',len(discarded_parents),'discarded',flush=True)
    result=write_pack(source,backup,out,newpoints,newfaces,masks,np.array(uvs),np.array(materials),correspondence,header['tacticalGroundFieldSha256'],header['heightDomainMeters'],proof,header_overrides={'status':'experimental-connected-authored-wall-normalization','referenceEquivalence':'Exact source Z and alpha profiles retained; reviewed finite XY intentionally registered to authored connected walls.','authoredWallNormalization':proof},fragment_proof={'inputFaceIds':np.arange(len(old),len(newfaces)),'barycentrics':np.array(barys),'edges':np.array(edges),'warpCells':np.array(cells),'regionCells':np.array(region_cells),'discardedSourceFaces':np.array(discarded_parents,dtype=np.int64),'discardedBarycentrics':np.array(discarded_bary).reshape(-1,3,3),'discardedEdges':np.array(discarded_edges,dtype=np.int64),'discardedRegionCells':np.array(discarded_region,dtype=np.int64)})
    (out/'bindings.json').write_text(json.dumps(proof,indent=2)+'\n');(out/'summary.json').write_text(json.dumps(result,indent=2)+'\n');print(name,result,flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('declarations');p.add_argument('output');a=p.parse_args();build(a.declarations,a.output)
