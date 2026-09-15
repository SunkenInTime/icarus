"""Bake two reviewed diagonal planes without changing neighboring wall returns."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import numpy as np
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from tactical_pack_writer import write_pack
from authored_wall_profile_cells import frame_wall_breakpoints, normalized_fragments, inverse_in_cell

ROOT=Path('E:/IcarusWorldAudit/2026-09-06')
REV=ROOT/'tactical-visibility-revision'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(name,edge,version):
    review_path=REV/f'diagonal-wall-source-review-v1/{name}-{edge}.json'
    review=json.loads(review_path.read_text())
    out=REV/f'diagonal-wall-candidates-{version}/{name}'
    if out.exists():raise FileExistsError(out)
    source_path=REV/f'global-ground-complete-v2/{name}/{name}.height.bin.gz'
    header,arrays=pack(source_path)
    source=SimpleNamespace(header=header,raw=gzip.decompress(source_path.read_bytes()),arrays=arrays)
    full=np.load(source_path.parent/'correspondence.npz')['sourceFaces']
    original=np.load(REV/f'full-height-input-v1/{name}/source-correspondence.npz')['sourceFaces'][full]
    admitted=np.array(review['primaryPlaneSourceFaces'])
    selected=np.flatnonzero(np.isin(original,admitted))
    if not len(selected):raise ValueError('Reviewed plane has no retained control geometry')

    warp_path=REV/f'display-warps-v1/{name}.display-warp.json.gz'
    w=json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']))
    origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix)
    source_svg=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    target_svg=np.array(w['targetAttackSvg']).reshape(-1,2)
    unwarp=explicit_warp(target_svg,source_svg-target_svg,np.array(w['triangles']).reshape(-1,3))
    family={k:review[k] for k in ['sourceFrame','targetFrame','sourceAlong','targetAlong']}
    family.update(edge=edge,objects=[review['sourceObjectIndex']],sourceObjects=[dict(sourceObjectIndex=review['sourceObjectIndex'],**review['sourceObject'])],originalSourceFaces=sorted(set(original[selected].tolist())),controlFaces=selected.tolist(),reviewedPlaneSourceFaces=admitted.tolist(),adjacentAuthoredSpans=review['adjacentAuthoredSpans'])
    family['displayWarpBreakpoints']=frame_wall_breakpoints(unwarp,family['targetFrame'],*family['targetAlong'])

    additions=[];parents=[];bindings=[];weights=[];cells=[];masks=[]
    uvs=list(arrays['maskedUvs']);materials=list(arrays['maskedMaterials'])
    discarded_parents=[];discarded_bary=[];discarded_edges=[]
    for fid in selected:
        xyz=arrays['vertices'][arrays['faces'][fid]]
        projected=xyz.copy();projected[:,:2]=xyz[:,:2]@matrix.T+origin
        data=np.column_stack((projected,np.eye(3)))
        discarded=[]
        fragments=normalized_fragments(data,family,unwarp,discarded=discarded)
        for polygon in discarded:
            for j in range(1,len(polygon)-1):
                discarded_parents.append(int(fid));discarded_bary.append(polygon[[0,j,j+1],3:]);discarded_edges.append(edge)
        for polygon,cell in fragments:
            bary=polygon[:,3:];newxyz=bary@xyz
            newxyz[:,:2]=(inverse_in_cell(polygon[:,:2],unwarp,cell)-origin)@inverse.T
            for j in range(1,len(polygon)-1):
                tri=newxyz[[0,j,j+1]];bw=bary[[0,j,j+1]]
                if np.linalg.norm(np.cross(tri[1]-tri[0],tri[2]-tri[0]))<1e-12:
                    discarded_parents.append(int(fid));discarded_bary.append(bw);discarded_edges.append(edge);continue
                additions.append(tri);parents.append(int(fid));bindings.append(edge);weights.append(bw);cells.append(cell)
                mask=int(arrays['faceMasks'][fid])
                if mask>=0:
                    masks.append(len(uvs));uvs.append(bw@arrays['maskedUvs'][mask]);materials.append(arrays['maskedMaterials'][mask])
                else:masks.append(-1)

    keep=np.ones(len(arrays['faces']),dtype=bool);keep[selected]=False
    kept=np.flatnonzero(keep);added=np.array(additions)
    vertices=np.vstack((arrays['vertices'],added.reshape(-1,3)))
    faces=np.vstack((arrays['faces'][keep],np.arange(len(arrays['vertices']),len(vertices)).reshape(-1,3)))
    proof=dict(format='icarus-authored-wall-family-normalization-v1',physicalRayEquivalence=False,productionMutation=False,sourceBackup=str(source_path),sourcePackSha256=sha(source_path),sourceGeometrySha256=header['sourceGeometrySha256'],displayWarpSha256=sha(warp_path),sourceReviewFile=str(review_path),sourceReviewSha256=sha(review_path),families=[family],removedControlFaces=selected.tolist(),unchangedOriginalFaces=len(kept),addedTriangles=len(added),collapsedWallDepthTriangles=len(discarded_bary),preservedOutsideFragments=0,cornerOwnership='Only exact reviewed diagonal-plane source faces are transformed. Adjacent authored returns and recessed sheets are unchanged. Endpoint overhangs clamp with explicit discarded provenance.',heightPolicy='Every source face retains its Z and alpha profile, including separate lower and upper sheets. No extrusion or inferred solidity.',unresolved=['Provisional control relative-floor semantics remain unchanged.','Neighboring return alignment and recessed source sheets are separate scopes.','This is an isolated diagonal compiler pilot, not a cumulative Split candidate or final gameplay acceptance.'])
    fragment_proof=dict(inputFaceIds=np.arange(len(kept),len(faces)),barycentrics=np.array(weights),edges=np.array(bindings),warpCells=np.array(cells),discardedSourceFaces=np.array(discarded_parents,dtype=np.int64),discardedBarycentrics=np.array(discarded_bary).reshape(-1,3,3),discardedEdges=np.array(discarded_edges,dtype=np.int64))
    print(name,'writing',len(selected),'control faces into',len(added),'fragments',flush=True)
    result=write_pack(source,source_path,out,vertices,faces,np.r_[arrays['faceMasks'][keep],masks],np.array(uvs),np.array(materials),np.r_[kept,parents],header['tacticalGroundFieldSha256'],header['heightDomainMeters'],proof,header_overrides={'status':'experimental-authored-diagonal-wall-normalization','referenceEquivalence':'Exact reviewed plane profiles are normalized to authored SVG with preserved Z/alpha; original physical-ray equivalence is not claimed.','authoredWallNormalization':proof},fragment_proof=fragment_proof)
    (out/'bindings.json').write_text(json.dumps(proof,indent=2))
    (out/'summary.json').write_text(json.dumps(result,indent=2))
    print(name,out,flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--map',choices=['split','ascent','both'],default='both');p.add_argument('--version',default='v1');args=p.parse_args()
    for name,edge in [('split',84),('ascent',159)]:
        if args.map in (name,'both'):build(name,edge,args.version)
